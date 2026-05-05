"""Read-only consumer for ``failover-events.db`` (failover-metrics-collector).

Schema (the columns we read; collector may have more):

    failover_events(id, timestamp, event_type, from_interface, to_interface,
                    primary_score_before, backup_score_before, reason,
                    actual_failover_duration_ms, inter_event_duration_seconds)
"""

from __future__ import annotations

import logging
import sqlite3
from typing import Any

from .. import config

_logger = logging.getLogger("failover_web.events_reader")


def _open_ro() -> sqlite3.Connection:
    """Open the events database read-only via SQLite URI."""
    uri = f"file:{config.EVENTS_DB}?mode=ro&immutable=0"
    return sqlite3.connect(uri, uri=True, timeout=2.0)


def list_events(days: int = 30, limit: int = 1000) -> list[dict[str, Any]]:
    """Return recent failover events ordered newest-first."""
    days = max(1, min(days, 365))
    limit = max(1, min(limit, 5000))

    try:
        conn = _open_ro()
    except sqlite3.OperationalError as exc:
        _logger.warning(
            "events DB unreadable at %s: %s — returning empty event list",
            config.EVENTS_DB, exc,
        )
        return []

    try:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            """
            SELECT id, timestamp, event_type, from_interface, to_interface,
                   primary_score_before, backup_score_before, reason,
                   actual_failover_duration_ms, inter_event_duration_seconds
            FROM failover_events
            WHERE timestamp >= datetime('now', ?)
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            (f"-{days} days", limit),
        )
        return [dict(row) for row in cur.fetchall()]
    except sqlite3.OperationalError as exc:
        _logger.warning(
            "events query failed against %s: %s — returning empty event list",
            config.EVENTS_DB, exc,
        )
        return []
    finally:
        conn.close()
