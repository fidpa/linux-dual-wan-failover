"""Unit tests for diag.runner.stream_command.

Cover the SSE-streaming subprocess generator: a hung `ping` or a
spawn-failure must surface here, not when an operator runs diagnostics
in production.
"""

from __future__ import annotations

import subprocess

from web.diag import runner


class _FakeProc:
    """Minimal stand-in for subprocess.Popen used by stream_command."""

    def __init__(self, lines, *, exit_code: int = 0, raise_on_wait=None):
        self._lines = list(lines)
        self.returncode: int | None = None
        self._exit_code = exit_code
        self._raise_on_wait = raise_on_wait
        self.killed = False
        self.stdout = self  # the loop iterates `for line in proc.stdout`

    # Context-manager protocol — production code uses `with subprocess.Popen(...)`
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False  # do not swallow exceptions

    # Iterator protocol — yields lines one at a time, then stops.
    def __iter__(self):
        return iter(self._lines)

    def wait(self, timeout=None):
        if self._raise_on_wait is not None:
            exc = self._raise_on_wait
            self._raise_on_wait = None  # only raise once
            raise exc
        self.returncode = self._exit_code
        return self._exit_code

    def kill(self):
        self.killed = True

    def poll(self):
        return self.returncode


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


def test_stream_command_emits_start_data_end_for_normal_process(monkeypatch):
    fake = _FakeProc(["PING reply 1\n", "PING reply 2\n"], exit_code=0)
    monkeypatch.setattr(subprocess, "Popen", lambda *a, **k: fake)
    chunks = list(runner.stream_command(["/bin/ping", "-c", "2", "8.8.8.8"]))
    text = "".join(chunks)
    assert text.startswith("event: start\n")
    assert "data: PING reply 1" in text
    assert "data: PING reply 2" in text
    assert "event: end\ndata: 0" in text


def test_stream_command_handles_spawn_oserror(monkeypatch):
    def boom(*a, **k):
        raise OSError("ENOENT: No such tool")
    monkeypatch.setattr(subprocess, "Popen", boom)
    chunks = list(runner.stream_command(["/missing/tool"]))
    text = "".join(chunks)
    assert "event: start\n" in text
    assert "event: error" in text
    assert "spawn failed" in text


def test_stream_command_handles_value_error_on_spawn(monkeypatch):
    def boom(*a, **k):
        raise ValueError("argv malformed")
    monkeypatch.setattr(subprocess, "Popen", boom)
    text = "".join(runner.stream_command(["/bin/ping"]))
    assert "event: error" in text
    assert "argv malformed" in text


# ---------------------------------------------------------------------------
# Timeout / DoS guard
# ---------------------------------------------------------------------------


def test_stream_command_kills_process_on_timeout(monkeypatch):
    fake = _FakeProc(
        ["..."],
        raise_on_wait=subprocess.TimeoutExpired("/bin/ping", 30),
    )
    monkeypatch.setattr(subprocess, "Popen", lambda *a, **k: fake)
    text = "".join(runner.stream_command(["/bin/ping", "-c", "9999", "1.1.1.1"]))
    assert fake.killed is True
    assert "event: error" in text
    assert "timeout after" in text


def test_stream_command_truncates_oversized_output(monkeypatch):
    """DIAG_MAX_OUTPUT_BYTES is the only DoS defence — exercise it."""
    from web import config as cfg
    monkeypatch.setattr(cfg, "DIAG_MAX_OUTPUT_BYTES", 50)
    # First line fits (30 bytes), second line breaks the 50-byte budget.
    fits_line = ("X" * 30) + "\n"
    big_line = ("Y" * 60) + "\n"
    fake = _FakeProc([fits_line, big_line], exit_code=0)
    monkeypatch.setattr(subprocess, "Popen", lambda *a, **k: fake)
    text = "".join(runner.stream_command(["/bin/ping"]))
    assert "event: truncated" in text
    assert "data: " + ("X" * 30) in text
    assert "Y" not in text  # second line never made it through


def test_stream_command_finally_kills_lingering_process(monkeypatch):
    """`finally` block must reap the child if it's still running."""
    class _StillRunning(_FakeProc):
        def poll(self):
            # First poll returns running; after kill, the test should not care
            return None if not self.killed else 0

    fake = _StillRunning(["a\n"], exit_code=0)
    monkeypatch.setattr(subprocess, "Popen", lambda *a, **k: fake)
    list(runner.stream_command(["/bin/ping"]))
    assert fake.killed is True
