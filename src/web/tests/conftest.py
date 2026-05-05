"""Shared pytest fixtures: redirect config paths to a temp directory.

The Web-UI lives at ``src/web/`` under the repo root. Tests import the
package as ``web.<module>`` — we extend ``sys.path`` to include
``<repo>/src`` so the import resolves cleanly without an editable install.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

# tests/ → web/ → src/  (the parent of `src` becomes the repo root)
SRC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SRC))


@pytest.fixture()
def fixtures_dir(tmp_path: Path, monkeypatch) -> Path:
    """Create a writable wan-state directory and re-point config paths."""
    state_dir = tmp_path / "wan-state"
    state_dir.mkdir()
    prom_file = tmp_path / "wan_quality.prom"
    events_db = tmp_path / "events.db"
    log_path = tmp_path / "app.log"
    audit_path = tmp_path / "audit.log"

    from web import config as cfg
    from web.middleware import audit_log as _audit_log
    monkeypatch.setattr(_audit_log, "_logger", None)
    monkeypatch.setattr(cfg, "STATE_DIR", state_dir)
    monkeypatch.setattr(cfg, "CONNECTION_METRICS_FILE", state_dir / "connection_metrics")
    monkeypatch.setattr(cfg, "WAN_QUALITY_PROM_FILE", prom_file)
    monkeypatch.setattr(cfg, "EVENTS_DB", events_db)
    monkeypatch.setattr(cfg, "MANUAL_ACTION_FILE", state_dir / "manual_action.json")
    monkeypatch.setattr(cfg, "MANUAL_ACTION_LOCK", tmp_path / "manual_action.lock")
    monkeypatch.setattr(cfg, "CONFIG_LOCK", tmp_path / "config.lock")
    monkeypatch.setattr(cfg, "STAGING_CONFIG_PATH", tmp_path / "staging_failover.conf")
    monkeypatch.setattr(cfg, "APP_LOG", log_path)
    monkeypatch.setattr(cfg, "AUDIT_LOG", audit_path)

    return tmp_path


@pytest.fixture()
def fresh_state(fixtures_dir: Path) -> Path:
    """Write a known-good connection_metrics + wan_quality.prom snapshot."""
    state_dir = fixtures_dir / "wan-state"
    payload = {
        "timestamp": int(time.time()),
        "current_wan": "primary",
        "primary_interface": "eth0",
        "backup_interface": "lte0",
        "scores": {"eth0": 95, "lte0": 88},
        "counters": {
            "eth0": {"failures": 0, "recoveries": 200},
            "lte0": {"failures": 1, "recoveries": 198},
        },
        "thresholds": {"failure": 5, "recovery": 20},
    }
    (state_dir / "connection_metrics").write_text(json.dumps(payload), encoding="utf-8")

    prom = """# HELP wan_latency_milliseconds WAN interface latency in milliseconds
# TYPE wan_latency_milliseconds gauge
wan_latency_milliseconds{interface="eth0",type="primary"} 0.42
wan_latency_milliseconds{interface="lte0",type="backup"} 1.81
wan_packet_loss_percent{interface="eth0"} 0
wan_packet_loss_percent{interface="lte0"} 0.5
wan_jitter_milliseconds{interface="eth0"} 0
wan_jitter_milliseconds{interface="lte0"} 0.3
wan_dns_time_milliseconds{interface="eth0"} 80
wan_dns_time_milliseconds{interface="lte0"} 150
wan_http_time_milliseconds{interface="eth0"} 45
wan_http_time_milliseconds{interface="lte0"} 130
wan_quality_score{interface="eth0"} 78
wan_quality_score{interface="lte0"} 60
"""
    (fixtures_dir / "wan_quality.prom").write_text(prom, encoding="utf-8")
    return fixtures_dir


@pytest.fixture()
def stale_state(fresh_state: Path) -> Path:
    """Backdate the state files by 90 s → 'missing'."""
    old = time.time() - 90
    import os
    os.utime(fresh_state / "wan-state" / "connection_metrics", (old, old))
    os.utime(fresh_state / "wan_quality.prom", (old, old))
    return fresh_state


@pytest.fixture()
def events_db(fixtures_dir: Path) -> Path:
    """Seed a tiny failover_events table for history tests."""
    db = fixtures_dir / "events.db"
    conn = sqlite3.connect(db)
    conn.execute(
        """
        CREATE TABLE failover_events (
            id INTEGER PRIMARY KEY,
            timestamp DATETIME NOT NULL,
            event_type TEXT,
            from_interface TEXT,
            to_interface TEXT,
            primary_score_before INTEGER,
            backup_score_before INTEGER,
            reason TEXT,
            duration_seconds INTEGER,
            actual_failover_duration_ms INTEGER,
            inter_event_duration_seconds INTEGER
        )
        """
    )
    conn.executemany(
        """
        INSERT INTO failover_events
        (timestamp, event_type, from_interface, to_interface,
         primary_score_before, backup_score_before, reason,
         duration_seconds, actual_failover_duration_ms, inter_event_duration_seconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            ("2026-04-29 10:15:00", "failover", "eth0", "lte0", 25, 80, "score_based", 7, 4500, 0),
            ("2026-04-29 12:30:00", "failback", "lte0", "eth0", 95, 70, "score_based", 5, 3200, 8100),
            ("2026-05-01 22:21:00", "failover", "eth0", "lte0", 5, 90, "primary_no_carrier", 6, 5200, 200_000),
        ],
    )
    conn.commit()
    conn.close()
    return db


@pytest.fixture()
def client(fresh_state: Path):
    """Flask test-client bound to fresh_state fixtures."""
    from web.app import create_app
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


@pytest.fixture()
def client_no_state(fixtures_dir: Path):
    """Flask test-client where the state files do not exist (freshness=missing)."""
    from web.app import create_app
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c
