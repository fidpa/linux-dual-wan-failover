"""Unit tests for service_controller.

Cover the TimeoutExpired and OSError branches: if `is_failover_monitor_active`
silently returns False, that propagates as `installed_but_restart_failed`
into the config-update pipeline.
"""

from __future__ import annotations

import subprocess

from web.writers import service_controller


class _CompletedSuccess:
    returncode = 0
    stdout = ""
    stderr = ""


def _make_run(*, returncode: int = 0, stdout: str = "", stderr: str = "", raise_exc=None):
    def fake_run(cmd, **kwargs):
        if raise_exc is not None:
            raise raise_exc
        return subprocess.CompletedProcess(cmd, returncode=returncode, stdout=stdout, stderr=stderr)
    return fake_run


# ---------------------------------------------------------------------------
# restart_failover_monitor
# ---------------------------------------------------------------------------


def test_restart_returns_ok_on_zero_exit(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _make_run(returncode=0))
    out = service_controller.restart_failover_monitor()
    assert out["ok"] is True
    assert out["returncode"] == 0


def test_restart_returns_not_ok_on_nonzero_exit(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _make_run(returncode=1, stderr="auth fail"))
    out = service_controller.restart_failover_monitor()
    assert out["ok"] is False
    assert out["returncode"] == 1
    assert "auth fail" in out["stderr"]


def test_restart_handles_timeout(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        _make_run(raise_exc=subprocess.TimeoutExpired("/usr/bin/sudo", 15.0)),
    )
    out = service_controller.restart_failover_monitor(timeout=15.0)
    assert out["ok"] is False
    assert out["returncode"] == -1
    assert out["stderr"] == "timeout"


def test_restart_handles_oserror(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        _make_run(raise_exc=OSError("denied")),
    )
    out = service_controller.restart_failover_monitor()
    assert out["ok"] is False
    assert out["returncode"] == -1
    assert "denied" in out["stderr"]


def test_restart_handles_value_error(monkeypatch):
    """argv-malformation guard."""
    monkeypatch.setattr(
        subprocess, "run",
        _make_run(raise_exc=ValueError("bad argv")),
    )
    out = service_controller.restart_failover_monitor()
    assert out["ok"] is False
    assert "bad argv" in out["stderr"]


def test_restart_truncates_long_output(monkeypatch):
    big = "x" * 1000
    monkeypatch.setattr(
        subprocess, "run",
        _make_run(returncode=0, stdout=big, stderr=big),
    )
    out = service_controller.restart_failover_monitor()
    # Both fields capped at 500 chars
    assert len(out["stdout"]) == 500
    assert len(out["stderr"]) == 500


# ---------------------------------------------------------------------------
# is_failover_monitor_active
# ---------------------------------------------------------------------------


def test_is_active_true_when_returncode_zero_and_stdout_active(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _make_run(returncode=0, stdout="active\n"))
    assert service_controller.is_failover_monitor_active() is True


def test_is_active_false_when_returncode_nonzero(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _make_run(returncode=3, stdout="inactive\n"))
    assert service_controller.is_failover_monitor_active() is False


def test_is_active_false_on_timeout(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        _make_run(raise_exc=subprocess.TimeoutExpired("/usr/bin/sudo", 5.0)),
    )
    assert service_controller.is_failover_monitor_active() is False


def test_is_active_false_on_oserror(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        _make_run(raise_exc=OSError("fork failed")),
    )
    assert service_controller.is_failover_monitor_active() is False


def test_is_active_false_when_stdout_says_inactive_but_returncode_is_zero(monkeypatch):
    """Linguistic safeguard against `systemctl` exit-code drift."""
    monkeypatch.setattr(subprocess, "run", _make_run(returncode=0, stdout="failed\n"))
    assert service_controller.is_failover_monitor_active() is False
