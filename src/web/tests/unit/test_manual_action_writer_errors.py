"""Unit tests for manual_action_writer error paths.

Cover the PermissionError, ENOSPC and OSError branches so a regression in
the error-message construction is caught here, not by a full /var partition
or a permissions drift in production.
"""

from __future__ import annotations

import errno
import os

import pytest

from web.writers import manual_action_writer


def _patch_paths(tmp_path, monkeypatch):
    from web import config as cfg
    monkeypatch.setattr(cfg, "MANUAL_ACTION_FILE", tmp_path / "manual_action.json")
    monkeypatch.setattr(cfg, "MANUAL_ACTION_LOCK", tmp_path / "manual_action.lock")


def test_submit_action_happy_path_writes_file(tmp_path, monkeypatch):
    _patch_paths(tmp_path, monkeypatch)
    out = manual_action_writer.submit_action("failback")
    assert out["submitted"] is True
    target = tmp_path / "manual_action.json"
    assert target.exists()


def test_submit_action_unknown_action_raises(tmp_path, monkeypatch):
    _patch_paths(tmp_path, monkeypatch)
    with pytest.raises(ValueError, match="Unknown action"):
        manual_action_writer.submit_action("teleport")


def test_submit_action_permission_error_returned_as_detail(tmp_path, monkeypatch):
    _patch_paths(tmp_path, monkeypatch)

    def boom(*a, **k):
        raise PermissionError("denied")

    monkeypatch.setattr(manual_action_writer, "_write_atomic", boom)
    out = manual_action_writer.submit_action("failback", request_id="r-pe-1")
    assert out["submitted"] is False
    assert "permission denied" in out["detail"]
    assert out["request_id"] == "r-pe-1"


def test_submit_action_enospc_returns_specific_detail(tmp_path, monkeypatch):
    _patch_paths(tmp_path, monkeypatch)

    def boom(*a, **k):
        raise OSError(errno.ENOSPC, "no space")

    monkeypatch.setattr(manual_action_writer, "_write_atomic", boom)
    out = manual_action_writer.submit_action("force_failover", request_id="r-fs-1")
    assert out["submitted"] is False
    assert out["detail"] == "no space left on device"


def test_submit_action_other_oserror_returns_generic_detail(tmp_path, monkeypatch):
    _patch_paths(tmp_path, monkeypatch)

    def boom(*a, **k):
        raise OSError(errno.EROFS, "read-only fs")

    monkeypatch.setattr(manual_action_writer, "_write_atomic", boom)
    out = manual_action_writer.submit_action("failback", request_id="r-ro-1")
    assert out["submitted"] is False
    assert out["detail"].startswith("OSError")
    assert "read-only" in out["detail"]


def test_write_atomic_cleans_up_tmp_on_failure(tmp_path):
    """Verify the OSError path removes the tempfile."""
    target = tmp_path / "x.json"

    # Pre-create the target dir so .parent exists.
    class _FailingFsync:
        def __init__(self, fileno):
            self._fileno = fileno

        def write(self, data):
            return len(data)

        def flush(self):
            pass

        def fileno(self):
            return self._fileno

    # The cleanest exercise of the cleanup path is to monkeypatch os.rename
    # to fail after the tempfile is created.
    import os as _os
    real_rename = _os.rename
    rename_calls: list[tuple[str, str]] = []

    def failing_rename(src, dst):
        rename_calls.append((str(src), str(dst)))
        raise OSError(errno.EXDEV, "cross-device link not permitted")

    _os.rename = failing_rename
    try:
        with pytest.raises(OSError):
            manual_action_writer._write_atomic(target, b"{}")
    finally:
        _os.rename = real_rename

    # Tempfile must NOT linger in the target dir.
    leftover = list(tmp_path.glob("x.json.*.tmp"))
    assert leftover == [], f"tempfile lingered: {leftover}"


def test_lock_releases_fd_on_exception(tmp_path):
    """Even if the wrapped block raises, _lock must release the fd."""
    lock_path = tmp_path / "test.lock"
    initially_open = len(os.listdir("/proc/self/fd"))
    with pytest.raises(RuntimeError, match="boom"):
        with manual_action_writer.flock_path(lock_path):
            raise RuntimeError("boom")
    after_close = len(os.listdir("/proc/self/fd"))
    # The lock fd must be released — fd count back to baseline (allowing
    # for one or two unrelated test-helper fds, accept ±2).
    assert abs(after_close - initially_open) <= 2
