"""Read-only consumer for the failover-monitor shared-state files.

Two sources:

  * ``RUNTIME_DIR/wan-state/connection_metrics``                  JSON, ~5 s
  * ``/var/lib/node_exporter/textfile_collector/wan_quality.prom`` Prom-text, ~5 s

The reader returns a single normalised snapshot for the API/templates.
Missing or unreadable files never raise — the snapshot's ``freshness``
field carries the diagnosis instead.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .. import config


@dataclass(frozen=True)
class InterfaceMetrics:
    interface: str
    score: int | None = None
    failures: int | None = None
    recoveries: int | None = None
    latency_ms: float | None = None
    packet_loss_pct: float | None = None
    jitter_ms: float | None = None
    dns_time_ms: float | None = None
    http_time_ms: float | None = None
    quality_score: int | None = None
    role: str | None = None  # "primary" | "backup" — derived from prom labels


@dataclass(frozen=True)
class FailoverSnapshot:
    timestamp: int  # unix seconds (from connection_metrics)
    current_wan: str  # "primary" | "backup" | "N/A"
    primary_interface: str
    backup_interface: str
    interfaces: dict[str, InterfaceMetrics]
    freshness: str  # "fresh" | "stale" | "missing"
    state_age_seconds: int
    prom_age_seconds: int
    thresholds: dict[str, int] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


_AGE_INFINITY_SECONDS = 10**12  # sentinel for missing/unreadable files


def _file_age_seconds(path: Path) -> int:
    """Return age of the file in whole seconds; sentinel on error."""
    try:
        mtime = path.stat().st_mtime
    except (FileNotFoundError, PermissionError, OSError):
        return _AGE_INFINITY_SECONDS
    now = time.time()
    return max(0, int(now - mtime))


def _as_int(value: Any, default: int | None = None) -> int | None:
    """Coerce numeric values to int, returning ``default`` for everything else.

    ``bool`` is a Python ``int`` subtype; we exclude it explicitly because the
    upstream JSON schema treats true/false as flags, not as 1/0 metrics.
    """
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return int(value)
    return default


_PROM_LINE_RE = re.compile(
    r"""
    ^                                          # start
    (?P<name>wan_[a-z_]+)                      # metric name (wan_*)
    \{(?P<labels>[^}]*)\}                      # label set { ... }
    \s+
    (?P<value>-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)  # numeric value
    \s*$
    """,
    re.VERBOSE,
)


def _parse_prom_labels(labels: str) -> dict[str, str]:
    """Parse `key="value",key2="value2"` style label list (whitespace tolerant)."""
    out: dict[str, str] = {}
    for part in labels.split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        key, _, value = part.partition("=")
        key = key.strip()
        value = value.strip().strip('"')
        if key:
            out[key] = value
    return out


def parse_wan_quality_prom(text: str) -> dict[str, dict[str, float]]:
    """Parse the wan_quality.prom textfile into ``{interface: {metric: value}}``.

    Unknown labels are kept (e.g. ``type``); numeric parse errors are skipped
    silently — the source is trusted (written by failover-metrics-collector).
    """
    out: dict[str, dict[str, Any]] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        m = _PROM_LINE_RE.match(line)
        if not m:
            continue
        name = m.group("name")
        labels = _parse_prom_labels(m.group("labels"))
        try:
            value = float(m.group("value"))
        except ValueError:
            continue
        iface = labels.get("interface")
        if not iface:
            continue
        bucket = out.setdefault(iface, {})
        bucket[name[len("wan_"):]] = value  # strip wan_ prefix
        if "type" in labels:
            bucket["_type"] = labels["type"]
    return out


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def _empty_snapshot(state_age: int, prom_age: int) -> FailoverSnapshot:
    primary = config.PRIMARY_IFACE
    backup = config.BACKUP_IFACE
    interfaces = {
        primary: InterfaceMetrics(interface=primary),
        backup: InterfaceMetrics(interface=backup),
    }
    return FailoverSnapshot(
        timestamp=0,
        current_wan="N/A",
        primary_interface=primary,
        backup_interface=backup,
        interfaces=interfaces,
        freshness="missing",
        state_age_seconds=state_age,
        prom_age_seconds=prom_age,
        thresholds={},
    )


def read_snapshot() -> FailoverSnapshot:
    """Return the current failover snapshot. Never raises on missing files."""

    state_age = _file_age_seconds(config.CONNECTION_METRICS_FILE)
    prom_age = _file_age_seconds(config.WAN_QUALITY_PROM_FILE)

    try:
        raw = config.CONNECTION_METRICS_FILE.read_text(encoding="utf-8")
        data = json.loads(raw)
    except (FileNotFoundError, PermissionError, OSError, json.JSONDecodeError):
        data = None

    if data is None:
        return _empty_snapshot(state_age, prom_age)

    primary = str(data.get("primary_interface", config.PRIMARY_IFACE))
    backup = str(data.get("backup_interface", config.BACKUP_IFACE))
    scores = data.get("scores", {}) if isinstance(data.get("scores"), dict) else {}
    counters = data.get("counters", {}) if isinstance(data.get("counters"), dict) else {}
    thresholds = data.get("thresholds", {}) if isinstance(data.get("thresholds"), dict) else {}

    prom: dict[str, dict[str, float]] = {}
    try:
        prom_text = config.WAN_QUALITY_PROM_FILE.read_text(encoding="utf-8")
        prom = parse_wan_quality_prom(prom_text)
    except (FileNotFoundError, PermissionError, OSError):
        prom = {}

    def build(iface: str, role: str) -> InterfaceMetrics:
        cnt = counters.get(iface, {}) if isinstance(counters.get(iface), dict) else {}
        p = prom.get(iface, {})
        return InterfaceMetrics(
            interface=iface,
            score=_as_int(scores.get(iface)),
            failures=_as_int(cnt.get("failures")),
            recoveries=_as_int(cnt.get("recoveries")),
            latency_ms=p.get("latency_milliseconds"),
            packet_loss_pct=p.get("packet_loss_percent"),
            jitter_ms=p.get("jitter_milliseconds"),
            dns_time_ms=p.get("dns_time_milliseconds"),
            http_time_ms=p.get("http_time_milliseconds"),
            quality_score=_as_int(p.get("quality_score")),
            role=role,
        )

    interfaces = {
        primary: build(primary, "primary"),
        backup: build(backup, "backup"),
    }

    worst_age = max(state_age, prom_age)
    if worst_age <= config.STATE_STALE_SECONDS:
        freshness = "fresh"
    elif worst_age <= config.STATE_MISSING_SECONDS:
        freshness = "stale"
    else:
        freshness = "missing"

    return FailoverSnapshot(
        timestamp=_as_int(data.get("timestamp"), default=0) or 0,
        current_wan=str(data.get("current_wan", "N/A")),
        primary_interface=primary,
        backup_interface=backup,
        interfaces=interfaces,
        freshness=freshness,
        state_age_seconds=state_age,
        prom_age_seconds=prom_age,
        thresholds={
            k: i for k, v in thresholds.items() if (i := _as_int(v)) is not None
        },
    )


def snapshot_to_dict(snap: FailoverSnapshot) -> dict[str, Any]:
    """Stable JSON-serialisable representation for /api/state and SSE."""
    return {
        "timestamp": snap.timestamp,
        "current_wan": snap.current_wan,
        "primary_interface": snap.primary_interface,
        "backup_interface": snap.backup_interface,
        "freshness": snap.freshness,
        "state_age_seconds": snap.state_age_seconds,
        "prom_age_seconds": snap.prom_age_seconds,
        "thresholds": snap.thresholds,
        "interfaces": {
            iface: {
                "interface": m.interface,
                "score": m.score,
                "failures": m.failures,
                "recoveries": m.recoveries,
                "latency_ms": m.latency_ms,
                "packet_loss_pct": m.packet_loss_pct,
                "jitter_ms": m.jitter_ms,
                "dns_time_ms": m.dns_time_ms,
                "http_time_ms": m.http_time_ms,
                "quality_score": m.quality_score,
                "role": m.role,
            }
            for iface, m in snap.interfaces.items()
        },
    }
