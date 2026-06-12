"""Unit tests for the config_reader (parser + validator)."""

from __future__ import annotations

from web.readers import config_reader


def test_parse_conf_handles_assignments_comments_and_quotes():
    text = """# header
FAILOVER_THRESHOLD_DOWN=60
RECOVERY_THRESHOLD=80   # inline comment
ANTI_FLAPPING_DELAY = 600
QUOTED="hello"
SINGLE='world'
# line comment
NOT_AN_ASSIGNMENT
"""
    parsed = config_reader.parse_conf(text)
    assert parsed["FAILOVER_THRESHOLD_DOWN"] == "60"
    assert parsed["RECOVERY_THRESHOLD"] == "80"
    assert parsed["ANTI_FLAPPING_DELAY"] == "600"
    assert parsed["QUOTED"] == "hello"
    assert parsed["SINGLE"] == "world"
    assert "NOT_AN_ASSIGNMENT" not in parsed


def test_validate_updates_accepts_in_range_integers():
    accepted, errors = config_reader.validate_updates(
        {"FAILOVER_THRESHOLD_DOWN": "50", "MIN_FAILBACK_SCORE": 70}
    )
    assert errors == {}
    assert accepted == {"FAILOVER_THRESHOLD_DOWN": 50, "MIN_FAILBACK_SCORE": 70}


def test_validate_updates_rejects_out_of_range():
    accepted, errors = config_reader.validate_updates({"LATENCY_CRITICAL": 9_999_999})
    assert accepted == {}
    assert "LATENCY_CRITICAL" in errors
    assert "out of range" in errors["LATENCY_CRITICAL"]


def test_validate_updates_rejects_unknown_field():
    accepted, errors = config_reader.validate_updates({"DELETE_ALL_DATA": 1})
    assert accepted == {}
    assert errors["DELETE_ALL_DATA"] == "unknown field"


def test_validate_updates_rejects_non_integer():
    accepted, errors = config_reader.validate_updates({"FAILURE_THRESHOLD": "five"})
    assert accepted == {}
    assert "not an integer" in errors["FAILURE_THRESHOLD"]


def test_validate_updates_rejects_boolean():
    accepted, errors = config_reader.validate_updates({"RECOVERY_THRESHOLD": True})
    assert accepted == {}
    assert "boolean rejected" in errors["RECOVERY_THRESHOLD"]


def test_read_whitelisted_config_returns_descriptors_with_current(monkeypatch, tmp_path):
    conf_path = tmp_path / "failover.conf"
    conf_path.write_text(
        "FAILOVER_THRESHOLD_DOWN=55\nMIN_FAILBACK_SCORE=70\n", encoding="utf-8"
    )
    from web import config as cfg
    monkeypatch.setattr(cfg, "CONFIG_PATH", conf_path)
    monkeypatch.setattr(cfg, "OVERRIDE_CONFIG_PATH", tmp_path / "absent-overrides.conf")

    descs = config_reader.read_whitelisted_config()
    by_name = {d.name: d for d in descs}
    assert by_name["FAILOVER_THRESHOLD_DOWN"].current_value == 55
    assert by_name["MIN_FAILBACK_SCORE"].current_value == 70
    assert by_name["ANTI_FLAPPING_DELAY"].current_value is None
    # FAILOVER_THRESHOLD_UP was removed from the schema (the daemon never
    # evaluates it) — it must not resurface as a UI field.
    assert "FAILOVER_THRESHOLD_UP" not in by_name
    # Schema bounds preserved
    assert by_name["FAILOVER_THRESHOLD_DOWN"].min_value == 0
    assert by_name["FAILOVER_THRESHOLD_DOWN"].max_value == 100


def test_read_whitelisted_config_merges_override_last_wins(monkeypatch, tmp_path):
    """The override file wins over the base config (daemon source order)."""
    base = tmp_path / "failover.conf"
    base.write_text("FAILOVER_THRESHOLD_DOWN=60\nMIN_FAILBACK_SCORE=60\n", encoding="utf-8")
    override = tmp_path / "failover-overrides.conf"
    override.write_text("FAILOVER_THRESHOLD_DOWN=45\n", encoding="utf-8")
    from web import config as cfg
    monkeypatch.setattr(cfg, "CONFIG_PATH", base)
    monkeypatch.setattr(cfg, "OVERRIDE_CONFIG_PATH", override)

    by_name = {d.name: d for d in config_reader.read_whitelisted_config()}
    assert by_name["FAILOVER_THRESHOLD_DOWN"].current_value == 45  # override wins
    assert by_name["MIN_FAILBACK_SCORE"].current_value == 60  # base shines through
