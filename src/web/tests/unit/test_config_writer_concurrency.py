"""Concurrent-write race test for config_writer (TEST-HIGH-03).

Verifies that the `_lock` flock context manager actually serialises two
writers attempting to apply different updates to the same file. A bug here
would corrupt staging_failover.conf under multi-worker load.
"""

from __future__ import annotations

import subprocess
import threading
import time
from pathlib import Path

from web.writers import config_writer


def _patch_paths(tmp_path: Path, monkeypatch):
    # Override design: the writer reads/patches the OVERRIDE file; the base
    # config is never written by the web app.
    from web import config as cfg
    conf_src = tmp_path / "failover-overrides.conf"
    conf_src.write_text(
        "FAILOVER_THRESHOLD_DOWN=60\nMIN_FAILBACK_SCORE=60\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(cfg, "CONFIG_PATH", tmp_path / "failover.conf")
    monkeypatch.setattr(cfg, "OVERRIDE_CONFIG_PATH", conf_src)
    monkeypatch.setattr(cfg, "CONFIG_LOCK", tmp_path / "config.lock")
    monkeypatch.setattr(cfg, "STAGING_CONFIG_PATH", tmp_path / "staging.conf")
    monkeypatch.setattr(
        config_writer, "restart_failover_monitor",
        lambda: {"ok": True, "returncode": 0, "stdout": "", "stderr": ""},
    )
    monkeypatch.setattr(config_writer, "is_failover_monitor_active", lambda: True)
    monkeypatch.setattr(
        subprocess, "run",
        lambda cmd, **kw: subprocess.CompletedProcess(cmd, returncode=0, stdout="", stderr=""),
    )
    return conf_src


def test_apply_updates_serialises_concurrent_writers(tmp_path, monkeypatch):
    """Two threads racing to apply different updates must serialise via flock."""
    _patch_paths(tmp_path, monkeypatch)

    enter_marks: list[float] = []
    exit_marks: list[float] = []
    enter_lock = threading.Lock()

    real_lock_cm = config_writer._lock

    @config_writer.contextmanager
    def instrumented_lock(path):
        with real_lock_cm(path):
            with enter_lock:
                enter_marks.append(time.monotonic())
            try:
                # Emulate a non-trivial critical section so overlap would be visible.
                time.sleep(0.05)
                yield
            finally:
                with enter_lock:
                    exit_marks.append(time.monotonic())

    monkeypatch.setattr(config_writer, "_lock", instrumented_lock)

    results: list[dict] = []

    def worker(value: int):
        results.append(config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": value}))

    t1 = threading.Thread(target=worker, args=(50,))
    t2 = threading.Thread(target=worker, args=(70,))
    t1.start()
    t2.start()
    t1.join()
    t2.join()

    # Both calls succeeded.
    assert len(results) == 2
    assert all(r["status"] == "applied" for r in results)

    # Critical sections did NOT overlap: every enter is followed by an exit
    # before the next enter.
    pairs = list(zip(enter_marks, exit_marks, strict=True))
    assert len(pairs) == 2
    # Sort by enter time then verify the second thread's enter is >= first exit.
    pairs.sort()
    assert pairs[1][0] >= pairs[0][1] - 0.001  # tiny slack for monotonic precision


def test_apply_updates_bootstraps_missing_override_file(tmp_path, monkeypatch):
    """Missing override file is NOT an error — the first edit bootstraps it
    with a self-describing comment header."""
    _patch_paths(tmp_path, monkeypatch)
    from web import config as cfg
    cfg.OVERRIDE_CONFIG_PATH.unlink()  # simulate first-ever override
    out = config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": 50})
    assert out["status"] == "applied"
    assert out["applied"] == ["FAILOVER_THRESHOLD_DOWN"]
    staged = (tmp_path / "staging.conf").read_text()
    assert "FAILOVER_THRESHOLD_DOWN=50" in staged
    assert staged.startswith("# failover-overrides.conf")


def test_apply_updates_noop_when_value_unchanged(tmp_path, monkeypatch):
    _patch_paths(tmp_path, monkeypatch)
    out = config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": 60})
    # Same value as in the source → patcher emits identical text → noop branch.
    assert out["status"] == "noop"


def test_apply_updates_rejects_duplicate_keys(tmp_path, monkeypatch):
    """Duplicate KEY= lines must be refused rather than silently rewritten."""
    _patch_paths(tmp_path, monkeypatch)
    from web import config as cfg
    cfg.OVERRIDE_CONFIG_PATH.write_text(
        "FAILOVER_THRESHOLD_DOWN=60\nFAILOVER_THRESHOLD_DOWN=70\n",
        encoding="utf-8",
    )

    out = config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": 99})
    assert out["status"] == "error"
    assert "duplicate" in out["detail"].lower()


def test_apply_updates_preserves_quotes_in_value(tmp_path, monkeypatch):
    """A quoted value (KEY="60") must stay quoted after patching."""
    _patch_paths(tmp_path, monkeypatch)
    from web import config as cfg
    cfg.OVERRIDE_CONFIG_PATH.write_text(
        'FAILOVER_THRESHOLD_DOWN="60"\nMIN_FAILBACK_SCORE=60\n',
        encoding="utf-8",
    )
    out = config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": 55})
    assert out["status"] == "applied"
    staged = (tmp_path / "staging.conf").read_text()
    assert 'FAILOVER_THRESHOLD_DOWN="55"' in staged


def test_apply_updates_returns_207_via_installed_but_restart_failed(tmp_path, monkeypatch):
    _patch_paths(tmp_path, monkeypatch)
    monkeypatch.setattr(
        config_writer, "restart_failover_monitor",
        lambda: {"ok": False, "returncode": 1, "stdout": "", "stderr": "auth fail"},
    )
    out = config_writer.apply_updates({"FAILOVER_THRESHOLD_DOWN": 55})
    assert out["status"] == "installed_but_restart_failed"
    assert out["applied"] == ["FAILOVER_THRESHOLD_DOWN"]
