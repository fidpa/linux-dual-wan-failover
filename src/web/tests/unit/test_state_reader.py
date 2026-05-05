"""Unit tests for the state_reader module."""

from __future__ import annotations

import time

from web.readers import state_reader

# --- parse_wan_quality_prom -------------------------------------------------


def test_parse_prom_extracts_metrics_per_interface():
    text = """# HELP wan_latency_milliseconds latency
# TYPE wan_latency_milliseconds gauge
wan_latency_milliseconds{interface="eth0",type="primary"} 0.42
wan_latency_milliseconds{interface="lte0",type="backup"} 1.81
wan_quality_score{interface="eth0"} 78
wan_quality_score{interface="lte0"} 60
"""
    parsed = state_reader.parse_wan_quality_prom(text)
    assert set(parsed.keys()) == {"eth0", "lte0"}
    assert parsed["eth0"]["latency_milliseconds"] == 0.42
    assert parsed["lte0"]["latency_milliseconds"] == 1.81
    assert parsed["eth0"]["quality_score"] == 78
    assert parsed["eth0"]["_type"] == "primary"
    assert parsed["lte0"]["_type"] == "backup"


def test_parse_prom_ignores_comments_and_blank_lines():
    text = "\n# comment\n\nwan_jitter_milliseconds{interface=\"eth0\"} 0.5\n"
    parsed = state_reader.parse_wan_quality_prom(text)
    assert parsed == {"eth0": {"jitter_milliseconds": 0.5}}


def test_parse_prom_skips_lines_without_interface_label():
    text = "wan_latency_milliseconds{type=\"primary\"} 1.0\n"
    assert state_reader.parse_wan_quality_prom(text) == {}


def test_parse_prom_handles_scientific_notation():
    text = "wan_latency_milliseconds{interface=\"eth0\"} 1.2e-3\n"
    parsed = state_reader.parse_wan_quality_prom(text)
    assert parsed["eth0"]["latency_milliseconds"] == 0.0012


def test_parse_prom_skips_malformed_value():
    text = "wan_latency_milliseconds{interface=\"eth0\"} not-a-number\n"
    assert state_reader.parse_wan_quality_prom(text) == {}


# --- read_snapshot ----------------------------------------------------------


def test_read_snapshot_fresh(fresh_state):
    snap = state_reader.read_snapshot()
    assert snap.freshness == "fresh"
    assert snap.current_wan == "primary"
    assert snap.primary_interface == "eth0"
    assert snap.backup_interface == "lte0"
    eth0 = snap.interfaces["eth0"]
    assert eth0.score == 95
    assert eth0.latency_ms == 0.42
    assert eth0.quality_score == 78
    assert eth0.role == "primary"
    lte0 = snap.interfaces["lte0"]
    assert lte0.failures == 1
    assert lte0.role == "backup"


def test_read_snapshot_missing_files_returns_safe_defaults(fixtures_dir):
    snap = state_reader.read_snapshot()
    assert snap.freshness == "missing"
    assert snap.current_wan == "N/A"
    assert snap.interfaces["eth0"].score is None
    assert snap.interfaces["lte0"].score is None


def test_read_snapshot_stale_age_window(stale_state):
    snap = state_reader.read_snapshot()
    # Backdated 90s → above STATE_MISSING_SECONDS=60 → "missing"
    assert snap.freshness == "missing"
    assert snap.state_age_seconds >= 60


def test_snapshot_to_dict_is_json_serialisable(fresh_state):
    import json

    snap = state_reader.read_snapshot()
    blob = json.dumps(state_reader.snapshot_to_dict(snap))
    parsed = json.loads(blob)
    assert parsed["current_wan"] == "primary"
    assert parsed["interfaces"]["eth0"]["score"] == 95


def test_read_snapshot_corrupt_json_yields_missing(fixtures_dir):
    (fixtures_dir / "wan-state" / "connection_metrics").write_text("{not json", encoding="utf-8")
    snap = state_reader.read_snapshot()
    assert snap.freshness == "missing"
    assert snap.current_wan == "N/A"


def test_read_snapshot_marks_stale_between_thresholds(fresh_state):
    """Set ages just inside the stale window (>30s, <60s)."""
    import os

    target = time.time() - 45
    os.utime(fresh_state / "wan-state" / "connection_metrics", (target, target))
    os.utime(fresh_state / "wan_quality.prom", (target, target))
    snap = state_reader.read_snapshot()
    assert snap.freshness == "stale"
