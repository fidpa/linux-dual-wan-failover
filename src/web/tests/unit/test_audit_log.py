"""Audit log middleware tests."""

from __future__ import annotations

import json

from flask import Flask

from web.middleware import audit_log


def _setup_logger(tmp_path, monkeypatch):
    log_path = tmp_path / "audit.log"
    from web import config as cfg

    monkeypatch.setattr(cfg, "AUDIT_LOG", log_path)
    monkeypatch.setattr(audit_log, "_logger", None)
    return log_path


def test_emit_writes_json_lines(tmp_path, monkeypatch):
    log_path = _setup_logger(tmp_path, monkeypatch)
    app = Flask(__name__)
    with app.test_request_context(
        "/api/failback", method="POST", headers={"X-Forwarded-For": "10.0.0.5"}
    ):
        audit_log.emit("failback_requested", payload={"request_id": "abc"})
        audit_log.emit("failback_accepted", payload={"request_id": "abc"})

    lines = [ln for ln in log_path.read_text().splitlines() if ln.strip()]
    assert len(lines) == 2
    parsed = [json.loads(ln) for ln in lines]
    for record in parsed:
        assert record["src_ip"] == "10.0.0.5"
        assert record["method"] == "POST"
        assert record["path"] == "/api/failback"
        assert "ts" in record and isinstance(record["ts"], int)
    assert parsed[0]["event"] == "failback_requested"
    assert parsed[0]["payload"]["request_id"] == "abc"
    assert parsed[0]["result"] == "ok"
    assert parsed[1]["event"] == "failback_accepted"


def test_emit_uses_remote_addr_when_no_xff(tmp_path, monkeypatch):
    log_path = _setup_logger(tmp_path, monkeypatch)
    app = Flask(__name__)
    with app.test_request_context(
        "/api/state",
        method="GET",
        environ_overrides={"REMOTE_ADDR": "192.168.100.50"},
    ):
        audit_log.emit("state_read")

    record = json.loads(log_path.read_text().splitlines()[0])
    assert record["src_ip"] == "192.168.100.50"


def test_emit_records_failure_result(tmp_path, monkeypatch):
    log_path = _setup_logger(tmp_path, monkeypatch)
    app = Flask(__name__)
    with app.test_request_context("/api/failback", method="POST"):
        audit_log.emit("failback_rate_limited", result="rejected", payload={"reason": "429"})

    record = json.loads(log_path.read_text().splitlines()[0])
    assert record["result"] == "rejected"
    assert record["payload"]["reason"] == "429"


def test_logger_singleton_raises_when_path_unwritable_and_require_file_true(
    tmp_path, monkeypatch
):
    """T7 fail-loud (audit_log.py:33-41): refuse to start when audit log not writable.

    Production sets FAILOVER_WEB_AUDIT_LOG_REQUIRE_FILE=1 — the operator must
    fix the permission/path issue rather than run with a forensic gap.
    """
    import pytest

    from web import config as cfg

    unwritable = tmp_path / "nonexistent" / "subdir" / "audit.log"
    monkeypatch.setattr(cfg, "AUDIT_LOG", unwritable)
    monkeypatch.setattr(cfg, "AUDIT_LOG_REQUIRE_FILE", True)
    monkeypatch.setattr(audit_log, "_logger", None)

    # Make the parent path unresolvable so WatchedFileHandler raises.
    monkeypatch.setattr(
        audit_log, "WatchedFileHandler",
        _raise_permission_error,
    )

    with pytest.raises(RuntimeError, match="audit log not writable"):
        audit_log._logger_singleton()


def test_logger_singleton_falls_back_to_stderr_when_require_file_false(
    tmp_path, monkeypatch, caplog
):
    """T7 graceful: with REQUIRE_FILE=0, fall back to stderr handler + warning.

    Used in tests/dev where the production log path is not writable.
    """
    import logging

    from web import config as cfg

    unwritable = tmp_path / "nonexistent" / "subdir" / "audit.log"
    monkeypatch.setattr(cfg, "AUDIT_LOG", unwritable)
    monkeypatch.setattr(cfg, "AUDIT_LOG_REQUIRE_FILE", False)
    monkeypatch.setattr(audit_log, "_logger", None)
    monkeypatch.setattr(
        audit_log, "WatchedFileHandler",
        _raise_permission_error,
    )

    with caplog.at_level(logging.WARNING, logger="failover_web"):
        lg = audit_log._logger_singleton()

    assert any(isinstance(h, logging.StreamHandler) for h in lg.handlers)
    assert any("forensic gap" in rec.getMessage() for rec in caplog.records)


def _raise_permission_error(*_args, **_kwargs):
    raise PermissionError("simulated unwritable audit log")
