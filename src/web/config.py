"""Centralised configuration for the linux-dual-wan-failover Web-UI.

All paths and tunables are environment-driven — see
``systemd/failover-web.service`` for the production values, or
``docs/how-to/configure-web-ui.md`` for the operator-facing reference.

Defaults are chosen so the service runs out of the box on a system that
followed ``install.sh`` and the standard XDG-flavoured directory layout
(``/etc/linux-dual-wan-failover``, ``/run/linux-dual-wan-failover``,
``/var/lib/linux-dual-wan-failover``, ``/var/log/linux-dual-wan-failover``).
"""

from __future__ import annotations

import os
from pathlib import Path

# ---------------------------------------------------------------------------
# Repo + service identity
# ---------------------------------------------------------------------------
#
# Used to derive the default systemd unit names and the on-disk layout. Override
# only when you renamed the package — the service-name override is the most
# common reason (e.g. when you want to run two instances side by side).

PROJECT_NAME: str = os.environ.get("FAILOVER_WEB_PROJECT_NAME", "linux-dual-wan-failover")
TARGET_SERVICE: str = os.environ.get("FAILOVER_WEB_TARGET_SERVICE", "failover-monitor.service")

# ---------------------------------------------------------------------------
# File-system paths
# ---------------------------------------------------------------------------

# Runtime IPC directory — shared with failover-monitor for the manual_action
# file-trigger. Must be group-writable by the wan-state group (or whichever
# group failover-web's SupplementaryGroups grants).
RUNTIME_DIR: Path = Path(
    os.environ.get("FAILOVER_WEB_RUNTIME_DIR", f"/run/{PROJECT_NAME}")
)
STATE_DIR: Path = Path(
    os.environ.get("FAILOVER_WEB_STATE_DIR", str(RUNTIME_DIR / "wan-state"))
)

# connection_metrics is written by failover-monitor's metrics-collector
# (performance.sh::export_connection_metrics). Path layout matches
# src/services/failover-metrics-collector.py and lib/performance.sh.
CONNECTION_METRICS_FILE: Path = Path(
    os.environ.get(
        "FAILOVER_WEB_CONNECTION_METRICS_FILE",
        str(STATE_DIR / "connection_metrics"),
    )
)
WAN_QUALITY_PROM_FILE: Path = Path(
    os.environ.get(
        "FAILOVER_WEB_WAN_QUALITY_PROM",
        "/var/lib/node_exporter/textfile_collector/wan_quality.prom",
    )
)
EVENTS_DB: Path = Path(
    os.environ.get(
        "FAILOVER_WEB_EVENTS_DB",
        f"/var/lib/{PROJECT_NAME}/failover-metrics-collector/failover-events.db",
    )
)
CONFIG_PATH: Path = Path(
    os.environ.get("FAILOVER_WEB_CONFIG_PATH", f"/etc/{PROJECT_NAME}/failover.conf")
)
STAGING_CONFIG_PATH: Path = Path(
    os.environ.get(
        "FAILOVER_WEB_STAGING_CONFIG_PATH",
        "/var/lib/failover-web/staging/failover.conf",
    )
)
MANUAL_ACTION_FILE: Path = Path(
    os.environ.get(
        "FAILOVER_WEB_MANUAL_ACTION_FILE",
        str(STATE_DIR / "manual_action.json"),
    )
)
MANUAL_ACTION_LOCK: Path = Path(
    os.environ.get(
        "FAILOVER_WEB_MANUAL_ACTION_LOCK",
        "/var/lib/failover-web/manual_action.lock",
    )
)
CONFIG_LOCK: Path = Path(
    os.environ.get("FAILOVER_WEB_CONFIG_LOCK", "/var/lib/failover-web/config.lock")
)

# Path of the root-owned config installer. The installer re-validates every
# line against the same schema this app uses, then atomically renames the
# staged file into ``CONFIG_PATH``. failover-web's sudoers grants exactly
# this command (no arguments — both source and destination are baked in).
INSTALL_HELPER: str = os.environ.get(
    "FAILOVER_WEB_INSTALL_HELPER", "/usr/local/sbin/install-failover-conf"
)

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

WEB_PORT: int = int(os.environ.get("FAILOVER_WEB_PORT", "8091"))
WEB_BIND: str = os.environ.get("FAILOVER_WEB_BIND", "127.0.0.1")

# Optional: a Prometheus instance for the (out-of-scope) charting feature.
# Empty default means "no charts". The dashboard handles this gracefully.
PROM_URL: str = os.environ.get("FAILOVER_WEB_PROM_URL", "")
PROM_TIMEOUT_SECONDS: int = int(os.environ.get("FAILOVER_WEB_PROM_TIMEOUT", "5"))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_DIR: Path = Path(
    os.environ.get("FAILOVER_WEB_LOG_DIR", f"/var/log/{PROJECT_NAME}")
)
APP_LOG: Path = Path(
    os.environ.get("FAILOVER_WEB_APP_LOG", str(LOG_DIR / "failover-web.log"))
)
AUDIT_LOG: Path = Path(
    os.environ.get(
        "FAILOVER_WEB_AUDIT_LOG", str(LOG_DIR / "failover-web-audit.log")
    )
)
# Production mode: refuse to start when the audit log is not writable. Tests
# and local dev set this to 0 to allow a stderr fallback.
AUDIT_LOG_REQUIRE_FILE: bool = os.environ.get("FAILOVER_WEB_AUDIT_LOG_REQUIRE_FILE", "1") == "1"
LOG_MAX_BYTES: int = 10 * 1024 * 1024  # 10 MB
LOG_BACKUP_COUNT: int = 5
AUDIT_LOG_BACKUP_COUNT: int = 10

# ---------------------------------------------------------------------------
# SSE / freshness
# ---------------------------------------------------------------------------

SSE_TICK_SECONDS: float = float(os.environ.get("FAILOVER_WEB_SSE_TICK_SECONDS", "5"))
SSE_HEARTBEAT_SECONDS: float = float(os.environ.get("FAILOVER_WEB_SSE_HEARTBEAT_SECONDS", "15"))
SSE_MAX_CONNECTIONS_PER_IP: int = int(os.environ.get("FAILOVER_WEB_SSE_MAX_PER_IP", "3"))
STATE_STALE_SECONDS: int = int(os.environ.get("FAILOVER_WEB_STATE_STALE_SECONDS", "30"))
STATE_MISSING_SECONDS: int = int(os.environ.get("FAILOVER_WEB_STATE_MISSING_SECONDS", "60"))

# ---------------------------------------------------------------------------
# Rate limits (per source IP)
# ---------------------------------------------------------------------------

RATE_LIMITS: dict[str, str] = {
    "failback": "1 per 60 seconds",
    "force_failover": "1 per 120 seconds",
    "restart_monitor": "1 per 300 seconds",
    "config_put": "1 per 30 seconds",
    "diag": "1 per 10 seconds",
    "charts": "60 per minute",
}

# ---------------------------------------------------------------------------
# CSRF / Origin policy
# ---------------------------------------------------------------------------
#
# Comma-separated list of hostnames allowed in the Origin/Referer header for
# mutating endpoints. Set this to your reverse-proxy hostname plus any trusted
# bastion hosts. ``localhost`` and ``127.0.0.1`` are included by default so
# dev / test setups work without further configuration.

_csrf_hosts_env = os.environ.get("FAILOVER_WEB_CSRF_HOSTS", "")
if _csrf_hosts_env:
    CSRF_ALLOWED_HOSTS: tuple[str, ...] = tuple(
        h.strip() for h in _csrf_hosts_env.split(",") if h.strip()
    )
else:
    CSRF_ALLOWED_HOSTS = ("localhost", "127.0.0.1")

# Production runs behind HTTPS (nginx upstream), so Secure=True is correct.
# Tests and HTTP-only local dev set this to 0.
CSRF_COOKIE_SECURE: bool = os.environ.get("FAILOVER_WEB_CSRF_COOKIE_SECURE", "1") == "1"

# ---------------------------------------------------------------------------
# Manual-action handshake
# ---------------------------------------------------------------------------

MANUAL_ACTION_MAX_AGE_SECONDS: int = 30  # daemon ignores older requests
ALLOWED_MANUAL_ACTIONS: tuple[str, ...] = ("failback", "force_failover")

# ---------------------------------------------------------------------------
# Diag tools whitelist
# ---------------------------------------------------------------------------

DIAG_TOOLS: dict[str, str] = {
    "ping": "/bin/ping",
    "dig": "/usr/bin/dig",
    "traceroute": "/usr/bin/traceroute",
    "mtr": "/usr/bin/mtr",
}


def _diag_interfaces() -> tuple[str, ...]:
    """Resolve the diag interface whitelist from env.

    Order of precedence:
      1. ``FAILOVER_WEB_DIAG_INTERFACES`` (comma-separated, explicit override)
      2. ``PRIMARY_IFACE`` + ``BACKUP_IFACE`` (mirror the daemon's setup)
      3. The kernel-name fallback ``("eth0", "lte0")``.
    """
    explicit = os.environ.get("FAILOVER_WEB_DIAG_INTERFACES", "")
    if explicit:
        return tuple(s.strip() for s in explicit.split(",") if s.strip())
    primary = os.environ.get("PRIMARY_IFACE", "").strip()
    backup = os.environ.get("BACKUP_IFACE", "").strip()
    if primary or backup:
        return tuple(i for i in (primary, backup) if i)
    return ("eth0", "lte0")


DIAG_INTERFACES: tuple[str, ...] = _diag_interfaces()
DIAG_TIMEOUT_SECONDS: int = 30
DIAG_MAX_OUTPUT_BYTES: int = 64 * 1024

# ---------------------------------------------------------------------------
# UI labels
# ---------------------------------------------------------------------------
#
# Operators usually think in transport names ("DSL", "LTE") rather than in
# kernel interface names. Override via env when the underlying transport
# changes (e.g. fiber, 5G). Defaults are derived from the failover roles
# ("Primary", "Backup") so the UI is always coherent even before the
# operator personalises the labels.

PRIMARY_IFACE: str = os.environ.get("PRIMARY_IFACE", "eth0")
BACKUP_IFACE: str = os.environ.get("BACKUP_IFACE", "lte0")

PRIMARY_LABEL: str = os.environ.get("FAILOVER_WEB_LABEL_PRIMARY", "Primary")
BACKUP_LABEL: str = os.environ.get("FAILOVER_WEB_LABEL_BACKUP", "Backup")

INTERFACE_LABELS: dict[str, str] = {
    PRIMARY_IFACE: PRIMARY_LABEL,
    BACKUP_IFACE: BACKUP_LABEL,
}

# ---------------------------------------------------------------------------
# Alerting (plugin contract — see plugins/alerting/README.md)
# ---------------------------------------------------------------------------

ALERTING_BACKEND: str = os.environ.get("ALERTING_BACKEND", "none")
# Plugin lookup mirrors the order documented in plugins/alerting/README.md:
#   1. ALERTING_PLUGIN_PATH (full path override for custom plugins)
#   2. ALERTING_PLUGIN_DIR/<backend>.sh
ALERTING_PLUGIN_DIR: Path = Path(
    os.environ.get(
        "ALERTING_PLUGIN_DIR",
        f"/usr/local/lib/{PROJECT_NAME}/plugins/alerting",
    )
)
ALERTING_PLUGIN_PATH: str = os.environ.get("ALERTING_PLUGIN_PATH", "")
ALERT_TIMEOUT_SECONDS: float = float(os.environ.get("FAILOVER_WEB_ALERT_TIMEOUT", "10"))
