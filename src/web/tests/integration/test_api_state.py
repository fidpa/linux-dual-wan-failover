"""Integration tests for the read-only HTTP endpoints."""

from __future__ import annotations

import json


def test_api_state_returns_snapshot(client):
    resp = client.get("/api/state")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["current_wan"] == "primary"
    assert data["freshness"] == "fresh"
    assert data["interfaces"]["eth0"]["score"] == 95
    assert data["interfaces"]["eth0"]["latency_ms"] == 0.42


def test_health_reports_ok_when_state_fresh(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_history_returns_seeded_events(client, events_db):
    resp = client.get("/api/history?days=30")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["count"] == 3
    assert {e["event_type"] for e in data["events"]} == {"failover", "failback"}
    # Newest first.
    # Newest first — the fixture seeds relative to "now" (2d/13d back), so
    # assert dynamically instead of a hardcoded date (time-bomb fix).
    from datetime import datetime, timedelta

    newest_day = (datetime.now() - timedelta(days=2)).strftime("%Y-%m-%d")
    assert data["events"][0]["timestamp"].startswith(newest_day)


def test_history_exposes_event_id(client, events_db):
    """The failover Event-ID (Correlation-ID) reaches the /api/history response.

    Fixture: two migrated events (event_id set) + one legacy event (NULL),
    covering the mix in a real, partially-migrated database.
    """
    resp = client.get("/api/history?days=30")
    data = resp.get_json()
    assert {e["event_id"] for e in data["events"]} == {
        None,
        "111_1700000001",
        "222_1700000002",
    }
    # Newest event (2d back) predates the Correlation-ID feature → event_id None
    assert data["events"][0]["event_id"] is None


def test_history_degrades_without_event_id_column(client, fixtures_dir):
    """The reader stays functional against a DB WITHOUT the event_id column
    (collector not yet upgraded) — event_id is synthesized as None instead of
    raising OperationalError (which would empty the whole history)."""
    import sqlite3

    from web import config as cfg

    conn = sqlite3.connect(cfg.EVENTS_DB)
    conn.execute(
        """
        CREATE TABLE failover_events (
            id INTEGER PRIMARY KEY, timestamp DATETIME NOT NULL, event_type TEXT,
            from_interface TEXT, to_interface TEXT, primary_score_before INTEGER,
            backup_score_before INTEGER, reason TEXT, duration_seconds INTEGER,
            actual_failover_duration_ms INTEGER, inter_event_duration_seconds INTEGER
        )
        """
    )
    conn.execute(
        "INSERT INTO failover_events (timestamp, event_type, from_interface, to_interface) "
        "VALUES (datetime('now'), 'failover', 'eth0', 'lte0')"
    )
    conn.commit()
    conn.close()

    resp = client.get("/api/history?days=30")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["count"] == 1
    assert data["events"][0]["event_id"] is None


def test_history_invalid_days_falls_back_to_default(client, events_db):
    resp = client.get("/api/history?days=NaN")
    assert resp.status_code == 200
    assert resp.get_json()["days"] == 30


def test_index_renders_placeholder(client):
    resp = client.get("/")
    assert resp.status_code == 200
    # The dashboard's <title> reflects the project name + a CSRF meta tag.
    assert b"<title>linux-dual-wan-failover</title>" in resp.data
    assert b'<meta name="csrf-token"' in resp.data


def test_sse_stream_emits_state_event(client, monkeypatch):
    # Use a tiny tick so the test runs quickly.
    from web import config as cfg

    monkeypatch.setattr(cfg, "SSE_TICK_SECONDS", 0.5)
    monkeypatch.setattr(cfg, "SSE_HEARTBEAT_SECONDS", 5.0)
    with client.get("/api/events/stream", buffered=False) as resp:
        assert resp.status_code == 200
        assert resp.mimetype == "text/event-stream"
        # Read just the first event.
        chunks = []
        for raw in resp.response:
            chunks.append(raw.decode("utf-8"))
            if "event: state" in "".join(chunks) and "\n\n" in "".join(chunks):
                break
        joined = "".join(chunks)
        assert "event: state" in joined
        # Extract data line and verify it parses.
        for line in joined.splitlines():
            if line.startswith("data: "):
                payload = json.loads(line[len("data: "):])
                assert payload["current_wan"] == "primary"
                break
        else:
            raise AssertionError("No data: line in SSE stream")
