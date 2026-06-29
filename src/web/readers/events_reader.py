"""Read-only consumer for ``failover-events.db`` (failover-metrics-collector).

Schema (the columns we read; collector may have more):

    failover_events(id, timestamp, event_type, from_interface, to_interface,
                    primary_score_before, backup_score_before, reason,
                    actual_failover_duration_ms, inter_event_duration_seconds,
                    event_id)

``event_id`` is the failover Correlation-ID (PID_TIMESTAMP), shared with the
service logs of the same failover. The collector adds the column from its
Correlation-ID release; this reader degrades gracefully (``event_id=None``)
against an older, not-yet-migrated database, because reader and collector deploy
independently.
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


def _has_event_id_column(conn: sqlite3.Connection) -> bool:
    """Return True if failover_events has the event_id column."""
    try:
        cur = conn.execute("PRAGMA table_info(failover_events)")
        return any(row[1] == "event_id" for row in cur.fetchall())
    except sqlite3.OperationalError:
        return False


# Two fully-static query variants (no f-string SQL). The only difference is the
# event_id column vs. a synthesized NULL for pre-Correlation-ID databases.
_QUERY_WITH_EVENT_ID = """
    SELECT id, timestamp, event_type, from_interface, to_interface,
           primary_score_before, backup_score_before, reason,
           actual_failover_duration_ms, inter_event_duration_seconds,
           event_id
    FROM failover_events
    WHERE timestamp >= datetime('now', ?)
    ORDER BY timestamp DESC
    LIMIT ?
"""

_QUERY_NULL_EVENT_ID = """
    SELECT id, timestamp, event_type, from_interface, to_interface,
           primary_score_before, backup_score_before, reason,
           actual_failover_duration_ms, inter_event_duration_seconds,
           NULL AS event_id
    FROM failover_events
    WHERE timestamp >= datetime('now', ?)
    ORDER BY timestamp DESC
    LIMIT ?
"""


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
        # event_id only on Correlation-ID DBs; pick a fully-static query so the
        # result shape is stable either way (NULL on older DBs).
        query = _QUERY_WITH_EVENT_ID if _has_event_id_column(conn) else _QUERY_NULL_EVENT_ID
        cur = conn.execute(query, (f"-{days} days", limit))
        return [dict(row) for row in cur.fetchall()]
    except sqlite3.OperationalError as exc:
        _logger.warning(
            "events query failed against %s: %s — returning empty event list",
            config.EVENTS_DB, exc,
        )
        return []
    finally:
        conn.close()
