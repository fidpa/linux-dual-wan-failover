"""Reader for ``failover.conf`` — only a whitelist of variables is exposed.

Anything outside the whitelist is preserved verbatim by the writer; the
operator can still edit the config by hand for less common tuning.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .. import config

# (key, type, min, max, help)
ConfigField = tuple[str, type, int, int, str]

# FAILOVER_THRESHOLD_UP removed: the daemon never evaluates that variable
# (failback is governed by MIN_FAILBACK_SCORE + MIN_BACKUP_TIME +
# MIN_STABLE_DURATION). A UI field with no code effect fakes control.
CONFIG_SCHEMA: tuple[ConfigField, ...] = (
    ("FAILOVER_THRESHOLD_DOWN", int, 0, 100, "Failover when primary score falls below this value"),
    ("FAILURE_THRESHOLD", int, 1, 60, "Consecutive failures required to trigger a failover"),
    ("RECOVERY_THRESHOLD", int, 1, 120, "Consecutive successes required to trigger a failback"),
    ("EMERGENCY_THRESHOLD", int, 0, 100, "Score below which emergency failover bypasses consecutive checks"),
    ("ANTI_FLAPPING_DELAY", int, 60, 3600, "Minimum seconds between failovers (anti-oscillation)"),
    ("MIN_FAILBACK_SCORE", int, 30, 100, "Minimum primary score required for failback after stability"),
    ("MIN_BACKUP_TIME", int, 60, 86_400, "Minimum seconds on backup before failback is considered"),
    ("MIN_STABLE_DURATION", int, 60, 7200, "Continuous primary stability required before failback"),
    ("STABILITY_RESET_THRESHOLD", int, 0, 100, "Score below which the stability-window reset is logged (does not change failback timing)"),
    ("LATENCY_CRITICAL", int, 10, 5000, "Critical latency threshold (ms)"),
    ("LATENCY_WARNING", int, 5, 5000, "Warning latency threshold (ms)"),
    ("PACKET_LOSS_CRITICAL", int, 1, 100, "Critical packet loss threshold (%)"),
    ("PACKET_LOSS_WARNING", int, 1, 100, "Warning packet loss threshold (%)"),
    ("EMERGENCY_FAILBACK_DNS_THRESHOLD_MS", int, 50, 10_000, "Backup DNS time threshold for emergency failback (ms)"),
    ("EMERGENCY_FAILBACK_MIN_BACKUP_TIME", int, 60, 7200, "Minimum backup-time for emergency failback (s)"),
)

CONFIG_FIELDS: dict[str, ConfigField] = {f[0]: f for f in CONFIG_SCHEMA}

_LINE_RE = re.compile(
    r"""^
        \s*
        (?P<key>[A-Z_][A-Z0-9_]*)
        \s*=\s*
        (?P<value>(?:[^#\s"']+|"[^"]*"|'[^']*'))
        \s*(?:\#.*)?$
    """,
    re.VERBOSE,
)


@dataclass(frozen=True)
class FieldDescriptor:
    name: str
    type_name: str
    min_value: int
    max_value: int
    help: str
    current_value: int | None


def _read_file(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError, OSError):
        return ""


def parse_conf(text: str) -> dict[str, str]:
    """Return all KEY=value pairs found in ``text`` (raw string values)."""
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _LINE_RE.match(line)
        if not m:
            continue
        key = m.group("key")
        value = m.group("value")
        if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        out[key] = value
    return out


def effective_int(name: str, default: int) -> int:
    """Return one config value with the daemon's source order applied.

    Same overlay as :func:`read_whitelisted_config` (base, then override —
    bash last-wins), but for a single key and without the whitelist. Callers
    that reason about daemon behaviour (e.g. the anti-flapping pre-check in
    app.py) must see the same number the daemon sees.

    Returns ``default`` for a missing key or a non-integer value.
    """
    raw = parse_conf(_read_file(config.CONFIG_PATH))
    raw.update(parse_conf(_read_file(config.OVERRIDE_CONFIG_PATH)))
    try:
        return int(raw[name])
    except (KeyError, ValueError):
        return default


def read_whitelisted_config() -> list[FieldDescriptor]:
    """Return the whitelisted fields with their current EFFECTIVE values.

    Effective = base config overlaid with the operator override file —
    mirrors the daemon's source order (base, then override, bash last-wins).
    """
    raw = parse_conf(_read_file(config.CONFIG_PATH))
    raw.update(parse_conf(_read_file(config.OVERRIDE_CONFIG_PATH)))
    descriptors: list[FieldDescriptor] = []
    for name, _type, lo, hi, help_text in CONFIG_SCHEMA:
        cur_raw = raw.get(name)
        cur: int | None
        try:
            cur = int(cur_raw) if cur_raw is not None else None
        except ValueError:
            cur = None
        descriptors.append(
            FieldDescriptor(
                name=name,
                type_name="int",
                min_value=lo,
                max_value=hi,
                help=help_text,
                current_value=cur,
            )
        )
    return descriptors


def descriptors_to_dict(
    descs: list[FieldDescriptor],
) -> dict[str, dict[str, str | int | None]]:
    return {
        d.name: {
            "type": d.type_name,
            "min": d.min_value,
            "max": d.max_value,
            "help": d.help,
            "current": d.current_value,
        }
        for d in descs
    }


def validate_updates(submitted: dict[str, Any]) -> tuple[dict[str, int], dict[str, str]]:
    """Validate operator-submitted updates against the schema.

    Returns ``(accepted, errors)``. Only keys passing both type and range
    checks land in ``accepted``; everything else is reflected in ``errors``.
    """
    accepted: dict[str, int] = {}
    errors: dict[str, str] = {}
    for raw_key, raw_value in submitted.items():
        if raw_key not in CONFIG_FIELDS:
            errors[raw_key] = "unknown field"
            continue
        _, _, lo, hi, _ = CONFIG_FIELDS[raw_key]
        if isinstance(raw_value, bool):
            errors[raw_key] = "boolean rejected; expected integer"
            continue
        try:
            value = int(raw_value)
        except (TypeError, ValueError):
            errors[raw_key] = f"not an integer: {raw_value!r}"
            continue
        if value < lo or value > hi:
            errors[raw_key] = f"out of range [{lo}, {hi}]: {value}"
            continue
        accepted[raw_key] = value
    return accepted, errors
