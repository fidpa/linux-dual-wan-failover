"""Unit tests for config_writer._patch_text + apply_updates (with mocks)."""

from __future__ import annotations

import subprocess

from web.writers import config_writer


def test_patch_text_replaces_existing_assignment_in_place():
    text = """# header
FAILOVER_THRESHOLD_DOWN=60
FAILOVER_THRESHOLD_UP=80   # inline comment
ANTI_FLAPPING_DELAY=600
"""
    patched, applied = config_writer._patch_text(
        text, {"FAILOVER_THRESHOLD_DOWN": 50}
    )
    assert applied == ["FAILOVER_THRESHOLD_DOWN"]
    assert "FAILOVER_THRESHOLD_DOWN=50" in patched
    assert "FAILOVER_THRESHOLD_UP=80" in patched
    assert "ANTI_FLAPPING_DELAY=600" in patched
    # Original line was replaced, not duplicated
    assert patched.count("FAILOVER_THRESHOLD_DOWN=") == 1


def test_patch_text_preserves_inline_comment():
    text = "FAILOVER_THRESHOLD_UP=80   # tweak me\n"
    patched, _ = config_writer._patch_text(text, {"FAILOVER_THRESHOLD_UP": 90})
    assert "FAILOVER_THRESHOLD_UP" in patched
    assert "# tweak me" in patched
    assert "=90" in patched


def test_patch_text_appends_missing_keys_at_end():
    text = "EXISTING=1\n"
    patched, applied = config_writer._patch_text(text, {"FAILURE_THRESHOLD": 7})
    assert "FAILURE_THRESHOLD=7" in patched
    assert "EXISTING=1" in patched
    assert applied == ["FAILURE_THRESHOLD"]


def test_patch_text_no_diff_when_value_already_present():
    text = "FAILOVER_THRESHOLD_DOWN=60\n"
    patched, applied = config_writer._patch_text(text, {"FAILOVER_THRESHOLD_DOWN": 60})
    # The patcher always rewrites the line — but the surrounding apply_updates
    # detects that the result equals the input and reports noop.
    assert "FAILOVER_THRESHOLD_DOWN=60" in patched
    assert applied == ["FAILOVER_THRESHOLD_DOWN"]


def test_apply_updates_noop_for_empty_input(tmp_path, monkeypatch):
    from web import config as cfg
    monkeypatch.setattr(cfg, "CONFIG_LOCK", tmp_path / "lock")
    result = config_writer.apply_updates({})
    assert result["status"] == "noop"


def test_apply_updates_full_pipeline_with_mocks(tmp_path, monkeypatch):
    from web import config as cfg

    conf_src = tmp_path / "failover.conf"
    conf_src.write_text("FAILOVER_THRESHOLD_DOWN=60\nMIN_FAILBACK_SCORE=60\n", encoding="utf-8")
    monkeypatch.setattr(cfg, "CONFIG_PATH", conf_src)
    monkeypatch.setattr(cfg, "CONFIG_LOCK", tmp_path / "config.lock")
    monkeypatch.setattr(cfg, "STAGING_CONFIG_PATH", tmp_path / "staging.conf")

    install_calls = []
    restart_calls = []

    def fake_run(cmd, **kwargs):
        install_calls.append(cmd)
        # Pretend install succeeded
        return subprocess.CompletedProcess(cmd, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr(
        config_writer,
        "restart_failover_monitor",
        lambda: (restart_calls.append(1) or {"ok": True, "returncode": 0, "stdout": "", "stderr": ""}),
    )
    monkeypatch.setattr(config_writer, "is_failover_monitor_active", lambda: True)

    result = config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": 55})
    assert result["status"] == "applied"
    assert "FAILOVER_THRESHOLD_DOWN" in result["applied"]
    # Install must go through the root-validating helper, not /usr/bin/install.
    assert install_calls
    assert install_calls[0][0] == "/usr/bin/sudo"
    assert install_calls[0][-1].endswith("install-failover-conf")
    assert restart_calls == [1]
    # Staging file content verified
    staged = (tmp_path / "staging.conf").read_text()
    assert "FAILOVER_THRESHOLD_DOWN=55" in staged


def test_apply_updates_install_failure_returns_error(tmp_path, monkeypatch):
    from web import config as cfg
    conf_src = tmp_path / "failover.conf"
    conf_src.write_text("FAILOVER_THRESHOLD_DOWN=60\n", encoding="utf-8")
    monkeypatch.setattr(cfg, "CONFIG_PATH", conf_src)
    monkeypatch.setattr(cfg, "CONFIG_LOCK", tmp_path / "config.lock")
    monkeypatch.setattr(cfg, "STAGING_CONFIG_PATH", tmp_path / "staging.conf")

    monkeypatch.setattr(
        subprocess,
        "run",
        lambda cmd, **kw: subprocess.CompletedProcess(cmd, returncode=1, stdout="", stderr="denied"),
    )
    monkeypatch.setattr(config_writer, "restart_failover_monitor", lambda: {"ok": True})

    result = config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": 55})
    assert result["status"] == "error"
    assert "denied" in result["detail"]
