#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
linux-dual-wan-failover — metrics collector.

Reads the orchestrator's runtime state every few seconds and exports:

- Prometheus textfile output for scrape integration with node_exporter
- SQLite event log for after-the-fact incident analysis
- Optional RRD updates for long-term graphing

The service is **read-only** with respect to the failover decision path.
It does not write `active_wan`, scoring state, or routes — only failover-monitor
does. The contract with the orchestrator is the JSON snapshot file at
``/run/linux-dual-wan-failover/wan-state/connection_metrics`` and the active-WAN
state file at ``/run/linux-dual-wan-failover/wan-state/active_wan``.

Schema of the snapshot file (written by failover-monitor / performance.sh):

    {
      "timestamp": <unix-seconds>,
      "current_wan": "primary" | "backup",
      "primary_interface": "<iface>",
      "backup_interface":  "<iface>",
      "primary_score": 0..100,
      "backup_score":  0..100,
      "counters": {
        "primary": {"failures": N, "recoveries": N},
        "backup":  {"failures": N, "recoveries": N}
      },
      "thresholds": {"failure": N, "recovery": N}
    }
"""

import json
import logging
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any

# Configuration - Path Objects (pathlib Best Practice 2025)
METRICS_FILE = Path("/run/linux-dual-wan-failover/wan-state/connection_metrics")
STATE_FILE = Path("/run/linux-dual-wan-failover/wan-state/active_wan")
STATE_PERSISTENCE_FILE = Path(
    "/run/linux-dual-wan-failover/wan-state/metrics_collector_state"
)
# Failover Event-ID (Correlation-ID): published by routing.sh / nmcli-failover-
# monitor at the moment of the route change. Stored on the failover_events row,
# it links the DB/metric (symptom) to the service logs (cause) of the same
# failover: grep FAILOVER_EVENT_ID=<id> /var/log/linux-dual-wan-failover/*.log.
# See src/lib/event-id.sh.
LAST_FAILOVER_ID_FILE = Path("/run/linux-dual-wan-failover/wan-state/last_failover_id")
FAILOVER_LOG = Path("/var/log/linux-dual-wan-failover/failover-enhanced.log")

# RRD Configuration
RRD_DIR = Path("/var/lib/linux-dual-wan-failover/rrd")
RRD_FILE = RRD_DIR / "failover-metrics.rrd"

# SQLite Configuration
# Note: Uses StateDirectory path (admin-owned) so SQLite WAL mode can create .wal/.shm files
SQLITE_DIR = Path("/var/lib/linux-dual-wan-failover/failover-metrics-collector")
SQLITE_FILE = SQLITE_DIR / "failover-events.db"

# Logging
LOG_DIR = Path(os.getenv("LOG_DIR", "/var/log/linux-dual-wan-failover"))
LOG_FILE = LOG_DIR / "failover-metrics-collector.log"

# Operator config (read once at startup; not hot-reloaded).
CONFIG_FILE = Path(
    os.getenv("FAILOVER_CONFIG", "/etc/linux-dual-wan-failover/failover.conf")
)


def _read_config_value(key: str, default: str) -> str:
    """
    Read a single shell-style ``KEY=VALUE`` from CONFIG_FILE without sourcing it.

    Supports unquoted values and single/double-quoted values. Returns ``default``
    when the file is missing, unreadable, or the key is absent.
    """
    if not CONFIG_FILE.exists():
        return default
    try:
        pat = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*)\s*$")
        with open(CONFIG_FILE, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#"):
                    continue
                m = pat.match(line)
                if m:
                    val = m.group(1).strip()
                    if (val.startswith('"') and val.endswith('"')) or (
                        val.startswith("'") and val.endswith("'")
                    ):
                        val = val[1:-1]
                    return val
    except OSError:
        pass
    return default


PRIMARY_IFACE = os.getenv("PRIMARY_IFACE") or _read_config_value(
    "PRIMARY_IFACE", "eth0"
)
BACKUP_IFACE = os.getenv("BACKUP_IFACE") or _read_config_value("BACKUP_IFACE", "lte0")

# Collection interval (seconds)
COLLECTION_INTERVAL = 5

# Logging Configuration Constants
LOG_MAX_BYTES = 10 * 1024 * 1024  # 10MB
LOG_BACKUP_COUNT = 5
LOG_FORMAT = "%(asctime)s [%(levelname)s] %(message)s%(extra_fields)s"

# Metrics Collection Intervals (iterations, 5s each)
METRICS_SUMMARY_INTERVAL = 12  # 60 seconds
WAN_QUALITY_INTERVAL = 6  # 30 seconds
DNS_DETAILED_INTERVAL = 12  # 60 seconds


# Custom formatter for structured logging
class StructuredFormatter(logging.Formatter):
    """
    Custom formatter that handles extra fields from structured logging.

    Extracts context fields (interface, duration, error_type, etc.) from LogRecord
    and appends them to log messages in [key=value] format. Enables better log
    filtering and analysis in production.

    Examples:
        >>> logger.info("Failover detected", extra={'from': 'eth0', 'to': 'lte0'})
        2025-11-27 12:00:00 [INFO] Failover detected [from=eth0, to=lte0]
    """

    # Standard LogRecord attributes to exclude from extra fields
    _STANDARD_ATTRS = {
        "name",
        "msg",
        "args",
        "created",
        "filename",
        "funcName",
        "levelname",
        "levelno",
        "lineno",
        "module",
        "msecs",
        "message",
        "pathname",
        "process",
        "processName",
        "relativeCreated",
        "thread",
        "threadName",
        "exc_info",
        "exc_text",
        "stack_info",
    }

    def format(self, record: logging.LogRecord) -> str:
        """
        Format log record with extra fields appended.

        Args:
            record: LogRecord instance with optional extra fields

        Returns:
            Formatted log message with [key=value] extra fields
        """
        extra_fields = []
        for key, value in record.__dict__.items():
            if key not in self._STANDARD_ATTRS:
                extra_fields.append(f"{key}={value}")

        record.extra_fields = f" [{', '.join(extra_fields)}]" if extra_fields else ""
        return super().format(record)


# Setup logging with structured format (v2.2)
# Structured logging pattern: Include context fields for better filtering
# Uses StructuredFormatter directly (no intermediate formatter)

# File handler with rotation (10MB, 5 backups for moderate volume)
file_handler = RotatingFileHandler(
    str(LOG_FILE),  # pathlib → str for RotatingFileHandler
    maxBytes=LOG_MAX_BYTES,
    backupCount=LOG_BACKUP_COUNT,
    mode="a",
)

# Console handler
console_handler = logging.StreamHandler(sys.stdout)

# Apply structured formatter to both handlers
structured_formatter = StructuredFormatter(LOG_FORMAT)
file_handler.setFormatter(structured_formatter)
console_handler.setFormatter(structured_formatter)

logging.basicConfig(level=logging.INFO, handlers=[file_handler, console_handler])

logger = logging.getLogger()  # Get root logger


class FailoverMetricsCollector:
    """
    Production metrics collector for network failover monitoring.

    Collects and stores network interface metrics (eth0 DSL, lte0 LTE) every 5
    seconds, tracking failover events, WAN quality, and DNS performance. Exports
    metrics to RRDtool (continuous) and SQLite (events), plus Prometheus textfile
    collector for real-time monitoring.

    Attributes:
        last_active_interface: Currently active WAN interface (eth0 or lte0)
        failover_start_time: Timestamp of last failover event (legacy)
        last_metrics: Previous metrics for change detection
        rrd_available: Whether RRDtool is available and configured
        event_start_timestamp: Start time of current uptime period

    Examples:
        >>> collector = FailoverMetricsCollector()
        >>> collector.run()  # Start continuous collection loop
    """

    def __init__(self) -> None:
        """Initialize metrics collector with RRD and SQLite config."""
        # Ensure necessary directories exist
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        RRD_DIR.mkdir(parents=True, exist_ok=True)

        # Load persisted state first, before any other initialization
        self.last_active_interface: str | None = self._load_persisted_state()
        self.failover_start_time: datetime | None = None
        self.last_metrics: dict[str, Any] = {}
        self.rrd_available: bool = self._check_rrd_available()
        self.event_start_timestamp: datetime | None = None

        # Initialize SQLite database
        self._init_sqlite()

    def _load_persisted_state(self) -> str | None:
        """
        Load last known active-interface name from the persistence file.

        Returns the interface name (a string like ``eth0`` or ``lte0``) or
        ``None`` if no persisted state exists yet. Maintaining state across
        process restarts prevents phantom failover events when the collector
        is reloaded mid-failover.
        """
        try:
            if STATE_PERSISTENCE_FILE.exists():
                with open(STATE_PERSISTENCE_FILE) as f:
                    interface = f.read().strip()
                    if interface in (PRIMARY_IFACE, BACKUP_IFACE):
                        logger.info("Loaded persisted interface state: %s", interface)
                        return interface
                    if interface:
                        logger.warning(
                            "Invalid persisted state '%s', ignoring", interface
                        )
        except OSError as e:
            logger.warning(
                "Could not load persisted state: %s",
                e,
                extra={
                    "file": str(STATE_PERSISTENCE_FILE),
                    "error_type": type(e).__name__,
                },
            )
        return None

    def _persist_state(self, interface: str) -> None:
        """
        Persist the current active-interface name to disk.

        Args:
            interface: Current active interface name (matches PRIMARY_IFACE
                or BACKUP_IFACE).
        """
        try:
            # Ensure parent directory exists
            STATE_PERSISTENCE_FILE.parent.mkdir(parents=True, exist_ok=True)

            # Write state
            with open(STATE_PERSISTENCE_FILE, "w") as f:
                f.write(interface)

            logger.debug("Persisted interface state: %s", interface)
        except OSError as e:
            logger.error(
                "Could not persist state: %s",
                e,
                extra={
                    "file": str(STATE_PERSISTENCE_FILE),
                    "interface": interface,
                    "error_type": type(e).__name__,
                },
                exc_info=True,
            )

    def _read_bash_failover_duration(self) -> int | None:
        """
        Read actual failover duration (milliseconds) measured by Bash script.

        The WAN Monitor Bash script writes millisecond-precision failover duration
        to /run/linux-dual-wan-failover/wan-state/last_failover_duration_ms after each route change.
        This provides accurate execution time vs. Python-measured inter-event time.

        Returns:
            Failover duration in milliseconds, or None if not available

        Raises:
            ValueError: If duration file contains non-numeric value (logged, not raised)
            Exception: If file unreadable (logged, not raised)
        """
        try:
            duration_file = Path(
                "/run/linux-dual-wan-failover/wan-state/last_failover_duration_ms"
            )
            if duration_file.exists():
                with open(duration_file) as f:
                    duration_ms = int(f.read().strip())
                    logger.debug(
                        "Read Bash-measured failover duration: %dms", duration_ms
                    )
                    return duration_ms
            else:
                logger.debug(
                    "No Bash failover duration file found (expected for first run)"
                )
                return None
        except ValueError as e:
            logger.warning("Invalid duration value in %s: %s", duration_file, e)
            return None
        except OSError as e:
            logger.warning("Could not read Bash failover duration: %s", e)
            return None

    def _check_rrd_available(self) -> bool:
        """
        Check if RRDtool is available and database exists.

        Returns:
            True if RRDtool command exists and RRD database file is present,
            False otherwise (metrics will skip RRD updates)

        Raises:
            Exception: Logged (not raised) if availability check fails
        """
        try:
            # Check if rrdtool command exists
            result = subprocess.run(
                ["which", "rrdtool"], capture_output=True, text=True, timeout=5
            )
            if result.returncode != 0:
                logger.warning("RRDtool not installed - will skip RRD updates")
                return False

            # Check if RRD file exists
            if not RRD_FILE.exists():
                logger.warning(
                    "RRD file not found at %s - run setup-rrd.sh first", RRD_FILE
                )
                return False

            logger.info("RRDtool available and database found")
            return True
        except (subprocess.SubprocessError, OSError) as e:
            logger.error("Error checking RRD availability: %s", e, exc_info=True)
            return False

    def _init_sqlite(self) -> None:
        """
        Initialize SQLite database for failover events with schema migration.

        Creates three tables if they don't exist:
        - failover_events: Failover/failback event history with dual-duration tracking
        - metrics_summary: Periodic metrics snapshots (7-day retention)
        - wan_quality_metrics: WAN quality test results (7-day retention)

        Schema migration: Uses ALTER TABLE IF NOT EXISTS for new columns to handle
        upgrades from v2.1.0 → v2.2.0 without breaking existing databases.

        Performance: Enables WAL mode for better concurrency and crash recovery.

        Raises:
            sqlite3.Error: If database initialization fails (logged, not raised)
        """
        SQLITE_DIR.mkdir(parents=True, exist_ok=True)

        conn = sqlite3.connect(str(SQLITE_FILE))
        cursor = conn.cursor()

        # Enable WAL mode for better performance and crash recovery
        # WAL = Write-Ahead Logging (SQLite Best Practice 2025)
        cursor.execute("PRAGMA journal_mode=WAL;")
        wal_mode = cursor.fetchone()[0]
        if wal_mode == "wal":
            logger.info("SQLite WAL mode enabled")

        # Create failover events table (with v2.2.0 schema migration)
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS failover_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp DATETIME NOT NULL,
                event_type TEXT NOT NULL,
                from_interface TEXT,
                to_interface TEXT,
                primary_score_before INTEGER,
                backup_score_before INTEGER,
                primary_latency_before REAL,
                backup_latency_before REAL,
                reason TEXT,
                duration_seconds INTEGER,
                actual_failover_duration_ms INTEGER,
                inter_event_duration_seconds INTEGER,
                event_id TEXT
            )
        """)

        # Schema migration for existing databases (v2.1.0 → v2.2.0)
        # SQLite doesn't support IF NOT EXISTS in ALTER TABLE, so we check manually
        cursor.execute("PRAGMA table_info(failover_events)")
        columns = {row[1] for row in cursor.fetchall()}

        if "actual_failover_duration_ms" not in columns:
            cursor.execute("""
                ALTER TABLE failover_events
                ADD COLUMN actual_failover_duration_ms INTEGER
            """)
            logger.info("Added column: actual_failover_duration_ms (schema migration)")

        if "inter_event_duration_seconds" not in columns:
            cursor.execute("""
                ALTER TABLE failover_events
                ADD COLUMN inter_event_duration_seconds INTEGER
            """)
            logger.info("Added column: inter_event_duration_seconds (schema migration)")

        if "event_id" not in columns:
            cursor.execute("""
                ALTER TABLE failover_events
                ADD COLUMN event_id TEXT
            """)
            logger.info(
                "Added column: event_id (schema migration, Failover Correlation-ID)"
            )

        # Create index for faster queries
        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_timestamp
            ON failover_events(timestamp)
        """)

        # Create metrics summary table for pattern analysis
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS metrics_summary (
                timestamp DATETIME PRIMARY KEY,
                primary_score INTEGER,
                backup_score INTEGER,
                primary_latency REAL,
                backup_latency REAL,
                active_interface TEXT
            )
        """)

        # WAN Quality Metrics table (Task 2.2)
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS wan_quality_metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp DATETIME NOT NULL,
                interface TEXT NOT NULL,
                latency_ms REAL,
                packet_loss_pct REAL,
                jitter_ms REAL,
                dns_time_ms INTEGER,
                http_time_ms INTEGER,
                overall_score INTEGER,
                gateway_latency_ms REAL,
                gateway_reachable INTEGER
            )
        """)

        # Schema migration for existing databases: latency_ms/packet_loss_pct/
        # jitter_ms now describe the internet path; the former gateway
        # measurement moved into these two columns.
        cursor.execute("PRAGMA table_info(wan_quality_metrics)")
        quality_columns = {row[1] for row in cursor.fetchall()}

        if "gateway_latency_ms" not in quality_columns:
            cursor.execute("""
                ALTER TABLE wan_quality_metrics
                ADD COLUMN gateway_latency_ms REAL
            """)
            logger.info("Added column: gateway_latency_ms (schema migration)")

        if "gateway_reachable" not in quality_columns:
            cursor.execute("""
                ALTER TABLE wan_quality_metrics
                ADD COLUMN gateway_reachable INTEGER
            """)
            logger.info("Added column: gateway_reachable (schema migration)")

        # DNS Performance Metrics table (Task 2.3)
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS dns_performance_metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp DATETIME NOT NULL,
                interface TEXT NOT NULL,
                success_rate_pct REAL,
                total_queries INTEGER,
                successful_queries INTEGER,
                timeouts INTEGER,
                servfails INTEGER,
                dns_quality_score INTEGER,
                google_dns_time_ms INTEGER,
                cloudflare_dns_time_ms INTEGER,
                isp_dns_time_ms INTEGER
            )
        """)

        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_quality_timestamp
            ON wan_quality_metrics(timestamp)
        """)

        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_quality_interface
            ON wan_quality_metrics(interface, timestamp)
        """)

        conn.commit()
        conn.close()
        logger.info("SQLite database initialized with schema migration support")

    def read_metrics(self) -> dict[str, Any] | None:
        """
        Read current metrics from the failover system.

        Returns a normalised dict with these keys (interface-name agnostic):

            primary_iface:    str — operator-configured primary interface name
            backup_iface:     str — operator-configured backup interface name
            primary_score:    int — primary score 0..100
            backup_score:     int — backup score 0..100
            current_wan:      "primary" | "backup"
            active_interface: str — actual interface name (primary or backup)
            timestamp:        ISO-8601 string

        Returns None if the metrics file is missing or unreadable.
        """
        try:
            if not METRICS_FILE.exists():
                logger.warning("Metrics file not found: %s", METRICS_FILE)
                return None

            with open(METRICS_FILE) as f:
                content = f.read()

            try:
                raw = json.loads(content)
            except json.JSONDecodeError as e:
                logger.error(
                    "Invalid JSON in metrics file: %s",
                    e,
                    extra={
                        "file": str(METRICS_FILE),
                        "first_200_chars": content[:200] if content else "empty",
                        "error_type": "JSONDecodeError",
                    },
                    exc_info=True,
                )
                return None

            primary_iface = raw.get("primary_interface", PRIMARY_IFACE)
            backup_iface = raw.get("backup_interface", BACKUP_IFACE)

            metrics: dict[str, Any] = {
                "timestamp": datetime.now().isoformat(),
                "primary_iface": primary_iface,
                "backup_iface": backup_iface,
                "primary_score": int(raw.get("primary_score", 0)),
                "backup_score": int(raw.get("backup_score", 0)),
                "current_wan": raw.get("current_wan", "primary"),
            }

            # Resolve current_wan -> actual interface name. Also tolerate the
            # state file directly containing an interface name (older schemas).
            try:
                if STATE_FILE.exists():
                    with open(STATE_FILE) as f:
                        active = f.read().strip()
                        if active == "primary":
                            metrics["active_interface"] = primary_iface
                        elif active == "backup":
                            metrics["active_interface"] = backup_iface
                        elif active == primary_iface or active == backup_iface:
                            metrics["active_interface"] = active
                            metrics["current_wan"] = (
                                "backup" if active == backup_iface else "primary"
                            )
                        else:
                            logger.warning(
                                "Unknown active_wan value '%s' — defaulting to primary",
                                active,
                            )
                            metrics["active_interface"] = primary_iface
                else:
                    metrics["active_interface"] = primary_iface
            except OSError as e:
                logger.warning(
                    "Could not read state file: %s", e, extra={"file": str(STATE_FILE)}
                )
                metrics["active_interface"] = primary_iface

            return metrics

        except FileNotFoundError as e:
            logger.error(
                "Metrics file not accessible: %s",
                e,
                extra={"file": str(METRICS_FILE)},
                exc_info=True,
            )
            return None
        except PermissionError as e:
            logger.error(
                "Permission denied reading metrics: %s",
                e,
                extra={"file": str(METRICS_FILE)},
                exc_info=True,
            )
            return None
        except (OSError, json.JSONDecodeError) as e:
            logger.error(
                "Unexpected error reading metrics: %s",
                e,
                extra={"error_type": type(e).__name__},
                exc_info=True,
            )
            return None

    def parse_detailed_metrics(self) -> tuple[float, float]:
        """
        Parse latency from recent failover-log entries.

        Returns ``(primary_latency_ms, backup_latency_ms)`` for the configured
        PRIMARY_IFACE / BACKUP_IFACE. Returns ``(0.0, 0.0)`` when the log file
        is missing or no matching entries are present.
        """
        try:
            if not FAILOVER_LOG.exists():
                logger.debug("Failover log not found: %s", FAILOVER_LOG)
                return 0.0, 0.0

            result = subprocess.run(
                ["tail", "-20", str(FAILOVER_LOG)],
                capture_output=True,
                text=True,
                timeout=5,
            )

            if result.returncode != 0:
                logger.debug(
                    "tail command failed with code %d: %s",
                    result.returncode,
                    result.stderr,
                )
                return 0.0, 0.0

            def _extract(line: str) -> float | None:
                parts = line.split("Latency=")
                if len(parts) <= 1:
                    return None
                latency_str = parts[1].split("ms")[0]
                try:
                    return float(latency_str)
                except ValueError:
                    return None

            primary_latency = 0.0
            backup_latency = 0.0
            primary_tag = f"{PRIMARY_IFACE}:"
            backup_tag = f"{BACKUP_IFACE}:"

            for line in result.stdout.split("\n"):
                if "Latency=" not in line:
                    continue
                if primary_tag in line:
                    val = _extract(line)
                    if val is not None:
                        primary_latency = val
                elif backup_tag in line:
                    val = _extract(line)
                    if val is not None:
                        backup_latency = val

            return primary_latency, backup_latency

        except subprocess.TimeoutExpired:
            logger.warning("Timeout reading failover log (5s exceeded)")
            return 0.0, 0.0
        except FileNotFoundError:
            logger.debug("tail command not found")
            return 0.0, 0.0
        except (subprocess.SubprocessError, OSError) as e:
            logger.error(
                "Error parsing detailed metrics: %s",
                e,
                extra={"error_type": type(e).__name__},
                exc_info=True,
            )
            return 0.0, 0.0

    def update_rrd(self, metrics: dict[str, Any]) -> None:
        """
        Update RRD database with current metrics.

        Writes metrics to RRDtool database for continuous time-series storage.
        Skipped if RRDtool unavailable (self.rrd_available == False).

        Args:
            metrics: Metrics dictionary from read_metrics()

        Raises:
            subprocess.CalledProcessError: If rrdtool update fails (logged)
            Exception: If RRD update fails (logged, not raised)
        """
        if not self.rrd_available:
            return

        try:
            primary_latency, backup_latency = self.parse_detailed_metrics()

            # RRD DS order: timestamp, primary_score, backup_score,
            # primary_latency, backup_latency, primary_loss, backup_loss,
            # active_iface (1=primary, 0=backup), failover_count.
            # The *_loss and failover_count fields are reserved (always 0)
            # until per-interface packet-loss tracking lands.
            active_is_primary = metrics["current_wan"] == "primary"
            values = [
                "N",
                str(metrics["primary_score"]),
                str(metrics["backup_score"]),
                str(primary_latency),
                str(backup_latency),
                "0",  # primary_loss reserved
                "0",  # backup_loss reserved
                "1" if active_is_primary else "0",
                "0",  # failover_count reserved
            ]

            update_string = ":".join(values)

            # Update RRD
            result = subprocess.run(
                ["rrdtool", "update", str(RRD_FILE), update_string],
                capture_output=True,
                text=True,
            )

            if result.returncode != 0:
                logger.error("RRD update failed: %s", result.stderr)
            else:
                logger.debug("RRD updated: %s", update_string)

        except (subprocess.SubprocessError, OSError) as e:
            logger.error("Error updating RRD: %s", e, exc_info=True)

    def _send_alert(self, message: str) -> None:
        """
        Send an alert via the bundled alerting plugin.

        Delegates to common.sh::send_notification, which selects the
        configured plugin (mattermost / webhook / custom). Best-effort —
        an alerting failure must never abort the metrics collector.

        Args:
            message: Alert message text
        """
        try:
            common_sh = Path(
                os.getenv(
                    "FAILOVER_COMMON_SH",
                    "/usr/local/lib/linux-dual-wan-failover/lib/common.sh",
                )
            )
            if not common_sh.exists():
                logger.debug("common.sh not found at %s — skipping alert", common_sh)
                return

            bash_cmd = (
                f'source "{common_sh}" 2>/dev/null && send_notification "$1" warning'
            )
            proc = subprocess.run(
                ["bash", "-c", bash_cmd, "_", message],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if proc.returncode == 0:
                logger.info(
                    "Alert dispatched via common.sh::send_notification",
                    extra={"message_length": len(message)},
                )
            else:
                logger.warning(
                    "send_notification returned non-zero (rc=%d)",
                    proc.returncode,
                    extra={"stderr": proc.stderr[:200]},
                )
        except subprocess.TimeoutExpired:
            logger.error("send_notification timed out after 30s")
        except OSError as e:
            logger.error(
                "Error dispatching alert: %s",
                e,
                extra={
                    "error_type": type(e).__name__,
                    "message_preview": message[:50],
                },
                exc_info=True,
            )

    def detect_failover_event(self, metrics: dict[str, Any]) -> str | None:
        """
        Detect if a failover event occurred.

        Compares current active interface with previous state to detect failover
        (eth0 → lte0) or failback (lte0 → eth0) events.

        Args:
            metrics: Current metrics from read_metrics()

        Returns:
            Event type ('failover' or 'failback'), or None if no change

        Side Effects:
            - Records event to SQLite via record_failover_event()
            - Updates self.last_active_interface
            - Resets self.event_start_timestamp
        """
        current_interface = metrics["active_interface"]

        if self.last_active_interface is None:
            self.last_active_interface = current_interface
            self.event_start_timestamp = datetime.now()
            self._persist_state(current_interface)
            return None

        if current_interface != self.last_active_interface:
            # Active interface changed: that's either a failover (now on backup)
            # or a failback (now on primary). Anchored to the configured
            # PRIMARY_IFACE / BACKUP_IFACE so the event direction is correct
            # regardless of how the interfaces are named.
            event_type = "failover" if current_interface == BACKUP_IFACE else "failback"
            logger.info(
                "Detected %s: %s -> %s",
                event_type,
                self.last_active_interface,
                current_interface,
            )

            # Record the event (with duration calculation)
            self.record_failover_event(
                event_type,
                self.last_active_interface,
                current_interface,
                self.last_metrics,
                metrics,
            )

            self.last_active_interface = current_interface
            # Persist new state immediately after change
            self._persist_state(current_interface)
            # NEW: Reset start time for next event
            self.event_start_timestamp = datetime.now()
            return event_type

        return None

    def _read_event_id(self) -> str | None:
        """Read the failover Event-ID (Correlation-ID) of the current event.

        routing.sh / nmcli-failover-monitor publish the active failover's ID to
        LAST_FAILOVER_ID_FILE at the moment of the route change. Storing it on the
        failover_events row lets the DB event (symptom) pivot to the service logs
        (cause): grep FAILOVER_EVENT_ID=<id> /var/log/linux-dual-wan-failover/*.log.

        Known limitation: with the 5s poll, two failovers inside one window can
        share the most recent ID (accepted sampling trade-off — see event-id.sh).

        Returns:
            The event ID string, or None if the file is missing/unreadable/empty.
        """
        try:
            event_id = LAST_FAILOVER_ID_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            return None
        return event_id or None

    def record_failover_event(
        self,
        event_type: str,
        from_iface: str,
        to_iface: str,
        last_metrics: dict[str, Any],
        current_metrics: dict[str, Any],
    ) -> None:
        """
        Record a failover event in SQLite with dual-duration tracking.

        Tracks TWO separate durations:
        1. actual_failover_duration_ms: Bash-measured execution time (route change)
        2. inter_event_duration_seconds: Time since last event (for pattern analysis)

        Args:
            event_type: Event type ('failover' or 'failback')
            from_iface: Source interface (eth0 or lte0)
            to_iface: Destination interface (eth0 or lte0)
            last_metrics: Metrics before event
            current_metrics: Metrics after event

        Side Effects:
            - Inserts event into SQLite failover_events table
            - Sends Mattermost alert if duration > 5s (SLA violation)
            - Exports Prometheus metrics via _export_prometheus_failover_duration()

        Raises:
            sqlite3.Error: If database insert fails (logged, not raised)
        """
        try:
            conn = sqlite3.connect(str(SQLITE_FILE))
            cursor = conn.cursor()

            primary_latency, backup_latency = self.parse_detailed_metrics()

            # NEW: Read actual failover duration from Bash script (millisecond-precision)
            actual_duration_ms = self._read_bash_failover_duration()
            actual_duration_seconds = (
                (actual_duration_ms // 1000) if actual_duration_ms else None
            )

            # Failover Event-ID (Correlation-ID) for the DB-row → service-logs pivot
            event_id = self._read_event_id()

            # Calculate inter-event duration (time between consecutive failover events)
            inter_event_seconds = None
            inter_event_ms = None
            if self.event_start_timestamp:
                duration_delta = datetime.now() - self.event_start_timestamp
                inter_event_seconds = int(duration_delta.total_seconds())
                inter_event_ms = int(duration_delta.total_seconds() * 1000)
                logger.debug(
                    "Inter-event duration: %dms (%ds)",
                    inter_event_ms,
                    inter_event_seconds,
                )

            # Log both durations for clarity
            if actual_duration_ms:
                logger.info(
                    "%s - Actual: %dms, Inter-event: %sms",
                    event_type.upper(),
                    actual_duration_ms,
                    inter_event_ms,
                )
            else:
                logger.info(
                    "%s - Inter-event: %sms (no Bash duration available)",
                    event_type.upper(),
                    inter_event_ms,
                )

            # NEW: SLA check uses ACTUAL failover duration (not inter-event!)
            if actual_duration_seconds and actual_duration_seconds > 5:
                alert_message = "*\\[Failover Metrics Collector\\]*\n\n"
                alert_message += f"*SLA Violation:* Slow {event_type}\n"
                alert_message += f"*Actual Duration:* {actual_duration_ms}ms ({actual_duration_seconds}s)\n"
                alert_message += f"*From:* {from_iface}\n"
                alert_message += f"*To:* {to_iface}\n"
                alert_message += "*Expected:* <5s\n\n"
                alert_message += (
                    f"_Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}_"
                )
                self._send_alert(alert_message)
                logger.warning(
                    "Slow %s detected: %ss (>5s SLA)",
                    event_type,
                    actual_duration_seconds,
                )

            # Legacy compatibility: Keep failover_start_time for old code
            if event_type == "failback" and self.failover_start_time:
                self.failover_start_time = None
            elif event_type == "failover":
                self.failover_start_time = datetime.now()

            # NEW: Insert with dual-duration columns
            cursor.execute(
                """
                INSERT INTO failover_events
                (timestamp, event_type, from_interface, to_interface,
                 primary_score_before, backup_score_before,
                 primary_latency_before, backup_latency_before,
                 reason, duration_seconds, actual_failover_duration_ms,
                 inter_event_duration_seconds, event_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
                (
                    datetime.now(),
                    event_type,
                    from_iface,
                    to_iface,
                    last_metrics.get("primary_score", 0),
                    last_metrics.get("backup_score", 0),
                    primary_latency,
                    backup_latency,
                    (
                        f"Score change: primary={current_metrics.get('primary_score', 0)}, "
                        f"backup={current_metrics.get('backup_score', 0)}"
                    ),
                    actual_duration_seconds,
                    actual_duration_ms,
                    inter_event_seconds,
                    event_id,
                ),
            )

            conn.commit()
            conn.close()

            logger.info(
                "Recorded %s event in database (actual: %sms, inter-event: %sms)",
                event_type,
                actual_duration_ms,
                inter_event_ms,
            )

            # NEW: Export Prometheus metrics with both durations
            self._export_prometheus_failover_duration(
                event_type,
                from_iface,
                to_iface,
                actual_duration_seconds,
                actual_duration_ms,
                inter_event_seconds,
            )

        except sqlite3.Error as e:
            logger.error("Error recording failover event: %s", e, exc_info=True)

    def _export_prometheus_failover_duration(
        self,
        event_type: str,
        from_iface: str,
        to_iface: str,
        actual_duration_seconds: int | None,
        actual_duration_ms: int | None,
        inter_event_seconds: int | None = None,
    ) -> None:
        """
        Export failover durations to Prometheus textfile collector.

        Exports TWO separate metrics:
        1. failover_actual_duration_*: Bash-measured execution time
        2. failover_inter_event_*: Time between consecutive events

        Uses atomic file replacement to prevent race conditions with Node Exporter.

        Args:
            event_type: Event type ('failover' or 'failback')
            from_iface: Source interface
            to_iface: Destination interface
            actual_duration_seconds: Bash-measured duration in seconds
            actual_duration_ms: Bash-measured duration in milliseconds
            inter_event_seconds: Time since last event in seconds

        Raises:
            OSError: If Prometheus textfile directory unwritable (logged)
        """
        try:
            # Prometheus textfile collector directory
            prom_dir = Path("/var/lib/node_exporter/textfile_collector")
            prom_dir.mkdir(parents=True, exist_ok=True)

            prom_file = prom_dir / "failover_duration.prom"
            tmp_file = prom_file.with_suffix(".tmp")

            # Write to temporary file first (atomic replace pattern)
            with open(tmp_file, "w") as f:
                # Actual failover duration (Bash-measured)
                if actual_duration_ms is not None:
                    f.write(
                        "# HELP failover_actual_duration_milliseconds Actual failover execution time (Bash-measured)\n"
                    )
                    f.write("# TYPE failover_actual_duration_milliseconds gauge\n")
                    f.write(
                        f'failover_actual_duration_milliseconds{{event_type="{event_type}",from="{from_iface}",to="{to_iface}"}} {actual_duration_ms}\n'
                    )
                    f.write("\n")

                if actual_duration_seconds is not None:
                    f.write(
                        "# HELP failover_actual_duration_seconds Actual failover execution time in seconds\n"
                    )
                    f.write("# TYPE failover_actual_duration_seconds gauge\n")
                    f.write(
                        f'failover_actual_duration_seconds{{event_type="{event_type}",from="{from_iface}",to="{to_iface}"}} {actual_duration_seconds}\n'
                    )
                    f.write("\n")

                # Inter-event duration (for pattern analysis)
                if inter_event_seconds is not None:
                    f.write(
                        "# HELP failover_inter_event_seconds Time between consecutive failover events\n"
                    )
                    f.write("# TYPE failover_inter_event_seconds gauge\n")
                    f.write(
                        f'failover_inter_event_seconds{{event_type="{event_type}"}} {inter_event_seconds}\n'
                    )
                    f.write("\n")

                # Legacy compatibility metric
                if actual_duration_seconds is not None:
                    f.write(
                        "# HELP failover_last_duration_seconds Last failover duration (any type) - LEGACY\n"
                    )
                    f.write("# TYPE failover_last_duration_seconds gauge\n")
                    f.write(
                        f"failover_last_duration_seconds {actual_duration_seconds}\n"
                    )

            # Atomic replace (prevents Node Exporter reading partial file)
            tmp_file.replace(prom_file)

            logger.info(
                "Exported Prometheus metrics: actual=%sms, inter-event=%ss to %s",
                actual_duration_ms,
                inter_event_seconds,
                prom_file,
            )

        except OSError as e:
            logger.error("Error exporting Prometheus metric: %s", e, exc_info=True)

    def save_metrics_summary(self, metrics: dict[str, Any]) -> None:
        """
        Save metrics summary to SQLite for pattern analysis.

        Stores periodic snapshots (every 60s) of interface scores and latencies.
        Automatically purges data older than 7 days to prevent unbounded growth.

        Args:
            metrics: Current metrics from read_metrics()

        Raises:
            sqlite3.Error: If database insert fails (logged, not raised)
        """
        try:
            conn = sqlite3.connect(str(SQLITE_FILE))
            cursor = conn.cursor()

            primary_latency, backup_latency = self.parse_detailed_metrics()

            # Insert or replace metrics summary (keep only last 7 days)
            cursor.execute(
                """
                INSERT OR REPLACE INTO metrics_summary
                (timestamp, primary_score, backup_score, primary_latency, backup_latency, active_interface)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
                (
                    datetime.now(),
                    metrics.get("primary_score", 0),
                    metrics.get("backup_score", 0),
                    primary_latency,
                    backup_latency,
                    metrics.get("active_interface", PRIMARY_IFACE),
                ),
            )

            # Clean up old data (keep only 7 days)
            cursor.execute("""
                DELETE FROM metrics_summary
                WHERE timestamp < datetime('now', '-7 days')
            """)

            conn.commit()
            conn.close()

        except sqlite3.Error as e:
            logger.error("Error saving metrics summary: %s", e, exc_info=True)

    def collect_wan_quality(self) -> dict[str, dict[str, Any]]:
        """
        Collect WAN-quality metrics by invoking ``network.sh::test_wan_quality``
        for the configured PRIMARY_IFACE and BACKUP_IFACE.

        Each invocation measures latency, packet loss, jitter, DNS resolution
        time, HTTP check time, and an overall quality score for one interface.

        Returns a dict keyed by the actual interface name. Empty if collection
        fails for both interfaces.
        """
        lib_dir = Path(
            os.getenv(
                "FAILOVER_LIB_DIR",
                "/usr/local/lib/linux-dual-wan-failover/lib",
            )
        )
        common_sh = lib_dir / "common.sh"
        network_sh = lib_dir / "network.sh"

        quality_data: dict[str, dict[str, Any]] = {}

        for interface in (PRIMARY_IFACE, BACKUP_IFACE):
            try:
                # The operator config must be sourced here too: test_wan_quality()
                # reads WAN_QUALITY_TARGET_MODE and CHECK_IPS from it. Without
                # this the rollback switch would silently not reach the subprocess.
                bash_cmd = (
                    f'source "{common_sh}" && '
                    f'if [ -f "{CONFIG_FILE}" ]; then source "{CONFIG_FILE}"; fi && '
                    f'source "{network_sh}" && '
                    f'test_wan_quality "{interface}"'
                )
                result = subprocess.run(
                    ["bash", "-c", bash_cmd],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )

                if result.returncode == 0 and result.stdout.strip():
                    try:
                        quality_json = json.loads(result.stdout.strip())
                        quality_data[interface] = quality_json
                        logger.debug("WAN quality for %s: %s", interface, quality_json)
                    except json.JSONDecodeError as e:
                        logger.error(
                            "Failed to parse JSON from test_wan_quality for %s: %s",
                            interface,
                            e,
                            exc_info=True,
                        )
                        logger.error(
                            "Invalid JSON output (first 200 chars): %s",
                            result.stdout[:200],
                        )
                else:
                    logger.warning(
                        "test_wan_quality failed for %s: %s",
                        interface,
                        result.stderr,
                    )

            except subprocess.TimeoutExpired:
                logger.error("test_wan_quality timed out for %s", interface)
            except (subprocess.SubprocessError, OSError, json.JSONDecodeError) as e:
                logger.error(
                    "Error collecting WAN quality for %s: %s",
                    interface,
                    e,
                    exc_info=True,
                )

        return quality_data

    @staticmethod
    def _interface_role(interface: str) -> str:
        """Return ``primary`` or ``backup`` for an interface name; else ``unknown``."""
        if interface == PRIMARY_IFACE:
            return "primary"
        if interface == BACKUP_IFACE:
            return "backup"
        return "unknown"

    def save_wan_quality_metrics(self, quality_data: dict[str, dict[str, Any]]) -> None:
        """
        Save WAN quality metrics to SQLite database.

        Args:
            quality_data: Quality metrics from collect_wan_quality()

        Raises:
            sqlite3.Error: If database insert fails (logged, not raised)
        """
        if not quality_data:
            return

        try:
            conn = sqlite3.connect(str(SQLITE_FILE))
            cursor = conn.cursor()

            for interface, data in quality_data.items():
                cursor.execute(
                    """
                    INSERT INTO wan_quality_metrics
                    (timestamp, interface, latency_ms, packet_loss_pct, jitter_ms,
                     dns_time_ms, http_time_ms, overall_score,
                     gateway_latency_ms, gateway_reachable)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                    (
                        datetime.now(),
                        interface,
                        data.get("latency_ms"),
                        data.get("packet_loss_pct"),
                        data.get("jitter_ms"),
                        data.get("dns_time_ms"),
                        data.get("http_time_ms"),
                        data.get("overall_score"),
                        data.get("gateway_latency_ms"),
                        data.get("gateway_reachable"),
                    ),
                )

            # Clean up old data (keep only 7 days)
            cursor.execute("""
                DELETE FROM wan_quality_metrics
                WHERE timestamp < datetime('now', '-7 days')
            """)

            conn.commit()
            conn.close()

            logger.info(
                "Saved WAN quality metrics for %d interfaces", len(quality_data)
            )

        except sqlite3.Error as e:
            logger.error("Error saving WAN quality metrics: %s", e, exc_info=True)

    def export_wan_quality_prometheus(
        self, quality_data: dict[str, dict[str, Any]]
    ) -> None:
        """
        Export WAN quality metrics to Prometheus textfile collector.

        Uses atomic file replacement to prevent race conditions with Node Exporter.

        Args:
            quality_data: Quality metrics from collect_wan_quality()

        Raises:
            OSError: If Prometheus textfile directory unwritable (logged)
        """
        if not quality_data:
            return

        try:
            prom_dir = Path("/var/lib/node_exporter/textfile_collector")
            prom_dir.mkdir(parents=True, exist_ok=True)

            prom_file = prom_dir / "wan_quality.prom"
            tmp_file = prom_file.with_suffix(".tmp")

            with open(tmp_file, "w") as f:
                # Latency
                f.write(
                    "# HELP wan_latency_milliseconds WAN interface latency in milliseconds\n"
                )
                f.write("# TYPE wan_latency_milliseconds gauge\n")
                for interface, data in quality_data.items():
                    iface_type = self._interface_role(interface)
                    latency = data.get("latency_ms", 999.99)
                    f.write(
                        f'wan_latency_milliseconds{{interface="{interface}",type="{iface_type}"}} {latency}\n'
                    )
                f.write("\n")

                # Packet Loss
                f.write(
                    "# HELP wan_packet_loss_percent WAN interface packet loss percentage\n"
                )
                f.write("# TYPE wan_packet_loss_percent gauge\n")
                for interface, data in quality_data.items():
                    loss = data.get("packet_loss_pct", 100)
                    f.write(
                        f'wan_packet_loss_percent{{interface="{interface}"}} {loss}\n'
                    )
                f.write("\n")

                # Jitter
                f.write(
                    "# HELP wan_jitter_milliseconds WAN interface jitter in milliseconds\n"
                )
                f.write("# TYPE wan_jitter_milliseconds gauge\n")
                for interface, data in quality_data.items():
                    jitter = data.get("jitter_ms", 999.99)
                    f.write(
                        f'wan_jitter_milliseconds{{interface="{interface}"}} {jitter}\n'
                    )
                f.write("\n")

                # Gateway (next LAN hop) — reported separately so "modem/router
                # dead" stays distinguishable from "uplink degraded".
                f.write(
                    "# HELP wan_gateway_latency_milliseconds Latency to the next LAN hop (gateway)\n"
                )
                f.write("# TYPE wan_gateway_latency_milliseconds gauge\n")
                for interface, data in quality_data.items():
                    gw_latency = data.get("gateway_latency_ms", 999.99)
                    f.write(
                        f'wan_gateway_latency_milliseconds{{interface="{interface}"}} {gw_latency}\n'
                    )
                f.write("\n")

                f.write(
                    "# HELP wan_gateway_reachable Gateway reachable via ICMP (1=yes, 0=no)\n"
                )
                f.write("# TYPE wan_gateway_reachable gauge\n")
                for interface, data in quality_data.items():
                    gw_reachable = data.get("gateway_reachable", 0)
                    f.write(
                        f'wan_gateway_reachable{{interface="{interface}"}} {gw_reachable}\n'
                    )
                f.write("\n")

                # DNS Performance
                f.write(
                    "# HELP wan_dns_time_milliseconds DNS resolution time in milliseconds\n"
                )
                f.write("# TYPE wan_dns_time_milliseconds gauge\n")
                for interface, data in quality_data.items():
                    dns_time = data.get("dns_time_ms", 999)
                    f.write(
                        f'wan_dns_time_milliseconds{{interface="{interface}"}} {dns_time}\n'
                    )
                f.write("\n")

                # HTTP Performance
                f.write(
                    "# HELP wan_http_time_milliseconds HTTP check time in milliseconds\n"
                )
                f.write("# TYPE wan_http_time_milliseconds gauge\n")
                for interface, data in quality_data.items():
                    http_time = data.get("http_time_ms", 999)
                    f.write(
                        f'wan_http_time_milliseconds{{interface="{interface}"}} {http_time}\n'
                    )
                f.write("\n")

                # Overall Quality Score
                f.write("# HELP wan_quality_score Overall WAN quality score (0-100)\n")
                f.write("# TYPE wan_quality_score gauge\n")
                for interface, data in quality_data.items():
                    score = data.get("overall_score", 0)
                    f.write(f'wan_quality_score{{interface="{interface}"}} {score}\n')

            # Atomic replace (prevents Node Exporter reading partial file)
            tmp_file.replace(prom_file)

            logger.info("Exported WAN quality metrics to %s", prom_file)

        except OSError as e:
            logger.error(
                "Error exporting WAN quality Prometheus metrics: %s", e, exc_info=True
            )

    def collect_dns_detailed(self) -> dict[str, dict[str, Any]]:
        """
        Collect detailed DNS-performance metrics by invoking
        ``network.sh::measure_dns_detailed`` for the configured PRIMARY_IFACE
        and BACKUP_IFACE.

        Each invocation queries multiple resolvers from the configured
        ``DNS_SERVERS`` list and records success rate, timeouts, SERVFAIL,
        and quality score. Returns an empty dict if collection fails for
        both interfaces.
        """
        lib_dir = Path(
            os.getenv(
                "FAILOVER_LIB_DIR",
                "/usr/local/lib/linux-dual-wan-failover/lib",
            )
        )
        common_sh = lib_dir / "common.sh"
        network_sh = lib_dir / "network.sh"

        dns_data: dict[str, dict[str, Any]] = {}

        for interface in (PRIMARY_IFACE, BACKUP_IFACE):
            try:
                bash_cmd = (
                    f'source "{common_sh}" && '
                    f'source "{network_sh}" && '
                    f'measure_dns_detailed "{interface}"'
                )
                result = subprocess.run(
                    ["bash", "-c", bash_cmd],
                    capture_output=True,
                    text=True,
                    timeout=20,
                )

                if result.returncode == 0 and result.stdout.strip():
                    dns_json = json.loads(result.stdout.strip())
                    dns_data[interface] = dns_json
                    logger.debug("Detailed DNS metrics for %s: %s", interface, dns_json)
            except subprocess.TimeoutExpired:
                logger.error("measure_dns_detailed timed out for %s", interface)
            except json.JSONDecodeError as e:
                logger.error(
                    "Failed to parse JSON from measure_dns_detailed for %s: %s",
                    interface,
                    e,
                    exc_info=True,
                )
                logger.error(
                    "Invalid JSON output (first 200 chars): %s",
                    result.stdout[:200],
                )
            except (subprocess.SubprocessError, OSError) as e:
                logger.error(
                    "Error collecting detailed DNS metrics for %s: %s",
                    interface,
                    e,
                    exc_info=True,
                )

        return dns_data

    def save_dns_detailed_metrics(self, dns_data: dict[str, dict[str, Any]]) -> None:
        """
        Save detailed DNS metrics to SQLite database.

        Args:
            dns_data: DNS metrics from collect_dns_detailed()

        Raises:
            sqlite3.Error: If database insert fails (logged, not raised)
        """
        if not dns_data:
            return

        try:
            conn = sqlite3.connect(str(SQLITE_FILE))
            cursor = conn.cursor()

            for interface, data in dns_data.items():
                # Extract resolver-specific times
                resolvers = {
                    r["resolver"]: r["avg_time_ms"] for r in data.get("resolvers", [])
                }

                cursor.execute(
                    """
                    INSERT INTO dns_performance_metrics
                    (timestamp, interface, success_rate_pct, total_queries, successful_queries,
                     timeouts, servfails, dns_quality_score, google_dns_time_ms,
                     cloudflare_dns_time_ms, isp_dns_time_ms)
                    VALUES (datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                    (
                        interface,
                        data.get("success_rate_pct", 0),
                        data.get("total_queries", 0),
                        data.get("successful_queries", 0),
                        data.get("timeouts", 0),
                        data.get("servfails", 0),
                        data.get("dns_quality_score", 0),
                        resolvers.get("8.8.8.8", 999),
                        resolvers.get("1.1.1.1", 999),
                        resolvers.get("192.0.2.1", 999),
                    ),
                )

            # Clean up old data (keep only 7 days)
            cursor.execute("""
                DELETE FROM dns_performance_metrics
                WHERE timestamp < datetime('now', '-7 days')
            """)

            conn.commit()
            conn.close()
            logger.debug("Saved detailed DNS metrics for %d interfaces", len(dns_data))
        except sqlite3.Error as e:
            logger.error(
                "Error saving detailed DNS metrics to database: %s", e, exc_info=True
            )

    def export_dns_detailed_prometheus(
        self, dns_data: dict[str, dict[str, Any]]
    ) -> None:
        """
        Export detailed DNS metrics to Prometheus textfile collector.

        Uses atomic file replacement to prevent race conditions with Node Exporter.

        Args:
            dns_data: DNS metrics from collect_dns_detailed()

        Raises:
            OSError: If Prometheus textfile directory unwritable (logged)
        """
        if not dns_data:
            return

        try:
            prom_dir = Path("/var/lib/node_exporter/textfile_collector")
            prom_file = prom_dir / "dns_performance.prom"
            tmp_file = prom_file.with_suffix(".tmp")

            with open(tmp_file, "w") as f:
                # DNS Success Rate
                f.write(
                    "# HELP dns_success_rate_percent DNS query success rate percentage\n"
                )
                f.write("# TYPE dns_success_rate_percent gauge\n")
                for interface, data in dns_data.items():
                    iface_type = self._interface_role(interface)
                    success_rate = data.get("success_rate_pct", 0)
                    f.write(
                        f'dns_success_rate_percent{{interface="{interface}",type="{iface_type}"}} {success_rate}\n'
                    )

                f.write("\n")

                # DNS Failures
                f.write("# HELP dns_failures_total Total DNS query failures by type\n")
                f.write("# TYPE dns_failures_total counter\n")
                for interface, data in dns_data.items():
                    timeouts = data.get("timeouts", 0)
                    servfails = data.get("servfails", 0)
                    f.write(
                        f'dns_failures_total{{interface="{interface}",type="timeout"}} {timeouts}\n'
                    )
                    f.write(
                        f'dns_failures_total{{interface="{interface}",type="servfail"}} {servfails}\n'
                    )

                f.write("\n")

                # DNS Quality Score
                f.write("# HELP dns_quality_score DNS-specific quality score (0-100)\n")
                f.write("# TYPE dns_quality_score gauge\n")
                for interface, data in dns_data.items():
                    score = data.get("dns_quality_score", 0)
                    f.write(f'dns_quality_score{{interface="{interface}"}} {score}\n')

                f.write("\n")

                # Resolver Comparison
                f.write(
                    "# HELP dns_resolver_time_milliseconds DNS resolution time by resolver\n"
                )
                f.write("# TYPE dns_resolver_time_milliseconds gauge\n")
                for interface, data in dns_data.items():
                    for resolver_data in data.get("resolvers", []):
                        resolver = resolver_data["resolver"]
                        time_ms = resolver_data["avg_time_ms"]
                        # Resolver labels: google, cloudflare, isp
                        resolver_label = (
                            "google"
                            if resolver == "8.8.8.8"
                            else "cloudflare"
                            if resolver == "1.1.1.1"
                            else "isp"
                        )
                        f.write(
                            f'dns_resolver_time_milliseconds{{interface="{interface}",resolver="{resolver_label}",resolver_ip="{resolver}"}} {time_ms}\n'
                        )

            # Atomic replace (prevents Node Exporter reading partial file)
            tmp_file.replace(prom_file)

            logger.debug("Exported detailed DNS Prometheus metrics to %s", prom_file)
        except OSError as e:
            logger.error(
                "Error exporting detailed DNS Prometheus metrics: %s", e, exc_info=True
            )

    def _graceful_shutdown(self, signum: int, frame) -> None:
        """
        Handle SIGTERM signal for graceful shutdown.

        Called by systemd when service is stopped. Ensures clean exit without
        data loss or orphaned resources.

        Args:
            signum: Signal number (15 for SIGTERM)
            frame: Current stack frame (unused)
        """
        logger.info("Received signal %s (SIGTERM), shutting down gracefully", signum)
        sys.exit(0)

    def run(self) -> None:
        """
        Main collection loop - runs continuously until interrupted.

        Collects metrics every 5 seconds, detects failover events, and periodically
        saves summaries and quality metrics. Handles KeyboardInterrupt and SIGTERM
        gracefully for clean systemd integration.

        Collection schedule (5-second intervals):
        - Every iteration: Basic metrics, failover detection
        - Every 60s (12 iterations): Metrics summary, detailed DNS
        - Every 30s (6 iterations): WAN quality

        Raises:
            KeyboardInterrupt: Exits gracefully on Ctrl+C
            SystemExit: Exits gracefully on SIGTERM (systemd stop)
        """
        # Register SIGTERM handler for systemd integration
        signal.signal(signal.SIGTERM, self._graceful_shutdown)

        logger.info("Starting Failover Metrics Collector v2.2.0")
        logger.info("Collection interval: %s seconds", COLLECTION_INTERVAL)
        logger.info("RRD available: %s", self.rrd_available)
        logger.info("WAN Quality Monitoring enabled (Task 2.2)")
        logger.info("DNS Performance Metrics enabled (Task 2.3)")
        logger.info("SIGTERM handler registered (systemd integration)")

        iteration = 0

        while True:
            try:
                # Read current metrics
                metrics = self.read_metrics()

                if metrics:
                    # Update RRD if available
                    if self.rrd_available:
                        self.update_rrd(metrics)

                    # Detect failover events
                    self.detect_failover_event(metrics)

                    # Save summary every minute
                    if iteration % METRICS_SUMMARY_INTERVAL == 0:
                        self.save_metrics_summary(metrics)

                    # Collect WAN quality metrics every 30 seconds
                    # WAN quality tests take ~15-20s, so 30s interval prevents overlap
                    if iteration % WAN_QUALITY_INTERVAL == 0:
                        logger.debug("Collecting WAN quality metrics...")
                        quality_data = self.collect_wan_quality()
                        if quality_data:
                            self.save_wan_quality_metrics(quality_data)
                            self.export_wan_quality_prometheus(quality_data)

                    # Collect detailed DNS metrics every 60 seconds
                    # DNS tests with 3 resolvers * 2 samples = 12 queries, takes ~12-18s
                    if iteration % DNS_DETAILED_INTERVAL == 0:
                        logger.debug("Collecting detailed DNS metrics...")
                        dns_data = self.collect_dns_detailed()
                        if dns_data:
                            self.save_dns_detailed_metrics(dns_data)
                            self.export_dns_detailed_prometheus(dns_data)

                    # Store for next iteration
                    self.last_metrics = metrics

                    # Log status every minute
                    if iteration % METRICS_SUMMARY_INTERVAL == 0:
                        logger.info(
                            "Status: %s=%s%% %s=%s%% active=%s",
                            metrics["primary_iface"],
                            metrics["primary_score"],
                            metrics["backup_iface"],
                            metrics["backup_score"],
                            metrics["active_interface"],
                        )

                iteration += 1
                time.sleep(COLLECTION_INTERVAL)

            except KeyboardInterrupt:
                logger.info("Received interrupt signal, shutting down...")
                break
            except (RuntimeError, OSError) as e:
                logger.error("Error in main loop: %s", e, exc_info=True)
                time.sleep(COLLECTION_INTERVAL)


def main() -> int:
    """Start the failover metrics collector."""
    collector = FailoverMetricsCollector()
    collector.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
