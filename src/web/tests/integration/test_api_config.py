"""Integration tests for /api/config (GET + PUT)."""

from __future__ import annotations

from typing import Any

import pytest

from web.middleware import rate_limit
from web.middleware.csrf import CSRF_COOKIE_NAME, CSRF_HEADER_NAME


@pytest.fixture(autouse=True)
def _clean_rate_limit():
    rate_limit.reset_for_tests()
    yield
    rate_limit.reset_for_tests()


def _csrf_put(client, path: str, *, data: dict[str, Any] | None = None, json_body: dict[str, Any] | None = None):
    client.get("/api/state")
    cookie_obj = next((c for c in client._cookies.values() if c.key == CSRF_COOKIE_NAME), None)
    assert cookie_obj is not None
    headers = {CSRF_HEADER_NAME: cookie_obj.value, "Origin": "http://localhost"}
    if json_body is not None:
        return client.put(path, headers=headers, json=json_body)
    return client.put(path, headers=headers, data=data or {})


def _seed_conf(tmp_path):
    conf = tmp_path / "failover.conf"
    conf.write_text(
        "FAILOVER_THRESHOLD_DOWN=60\nFAILOVER_THRESHOLD_UP=80\nMIN_FAILBACK_SCORE=60\n",
        encoding="utf-8",
    )
    return conf


def test_get_api_config_returns_schema_with_current_values(client, fixtures_dir, monkeypatch):
    conf = _seed_conf(fixtures_dir)
    from web import config as cfg
    monkeypatch.setattr(cfg, "CONFIG_PATH", conf)

    resp = client.get("/api/config")
    assert resp.status_code == 200
    body = resp.get_json()
    assert "fields" in body
    assert body["fields"]["FAILOVER_THRESHOLD_DOWN"]["current"] == 60
    assert body["fields"]["FAILOVER_THRESHOLD_DOWN"]["min"] == 0
    assert body["fields"]["FAILOVER_THRESHOLD_DOWN"]["max"] == 100


def test_put_api_config_rejects_empty_body(client, fixtures_dir):
    resp = _csrf_put(client, "/api/config", json_body={})
    assert resp.status_code == 400


def test_put_api_config_returns_422_for_validation_failures(client, fixtures_dir, monkeypatch):
    monkeypatch.setattr(
        "web.app.dispatcher.send", lambda *a, **k: True
    )
    resp = _csrf_put(
        client,
        "/api/config",
        json_body={"FAILOVER_THRESHOLD_DOWN": 9999, "DELETE_DB": 1},
    )
    assert resp.status_code == 422
    body = resp.get_json()
    assert body["error"] == "validation_failed"
    assert "FAILOVER_THRESHOLD_DOWN" in body["errors"]
    assert "DELETE_DB" in body["errors"]


def test_put_api_config_applies_valid_updates(client, fixtures_dir, monkeypatch):
    conf = _seed_conf(fixtures_dir)
    from web import config as cfg
    monkeypatch.setattr(cfg, "CONFIG_PATH", conf)

    sent: list[tuple[str, str]] = []
    monkeypatch.setattr(
        "web.app.dispatcher.send",
        lambda alert_type, msg, **k: sent.append((alert_type, msg)) or True,
    )
    monkeypatch.setattr(
        "web.app.config_writer.apply_updates",
        lambda accepted: {"status": "applied", "applied": list(accepted.keys()), "monitor_active": True},
    )

    resp = _csrf_put(
        client,
        "/api/config",
        json_body={"FAILOVER_THRESHOLD_DOWN": 55},
    )
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "applied"
    assert "FAILOVER_THRESHOLD_DOWN" in body["applied"]
    assert sent and sent[0][0] == "INFO_FAILOVER"


def test_put_api_config_returns_500_on_writer_failure(client, fixtures_dir, monkeypatch):
    monkeypatch.setattr(
        "web.app.dispatcher.send", lambda *a, **k: True
    )
    monkeypatch.setattr(
        "web.app.config_writer.apply_updates",
        lambda accepted: {"status": "error", "applied": [], "detail": "install denied"},
    )
    resp = _csrf_put(
        client,
        "/api/config",
        json_body={"FAILOVER_THRESHOLD_DOWN": 55},
    )
    assert resp.status_code == 500
    body = resp.get_json()
    assert body["status"] == "error"
    assert "install denied" in body["detail"]


def test_put_api_config_returns_207_on_installed_but_restart_failed(
    client, fixtures_dir, monkeypatch
):
    """Config persists, daemon restart fails → HTTP 207 + audit event.

    Operator must inspect daemon health; the change is on disk regardless.
    """
    sent: list[tuple[str, str]] = []
    monkeypatch.setattr(
        "web.app.dispatcher.send",
        lambda alert_type, msg, **k: sent.append((alert_type, msg)) or True,
    )
    monkeypatch.setattr(
        "web.app.config_writer.apply_updates",
        lambda accepted: {
            "status": "installed_but_restart_failed",
            "applied": list(accepted.keys()),
            "detail": "systemctl returned 1: Job failed",
            "restart": {"ok": False, "returncode": 1},
        },
    )

    resp = _csrf_put(
        client,
        "/api/config",
        json_body={"FAILOVER_THRESHOLD_DOWN": 55},
    )
    assert resp.status_code == 207
    body = resp.get_json()
    assert body["status"] == "installed_but_restart_failed"
    assert body["applied"] == ["FAILOVER_THRESHOLD_DOWN"]
    assert sent and sent[0][0] == "WARN_FAILOVER"

    # Verify audit-log gets the warning-result event
    from web import config as cfg

    audit_lines = [
        ln for ln in cfg.AUDIT_LOG.read_text().splitlines() if ln.strip()
    ]
    import json as _json

    last = _json.loads(audit_lines[-1])
    assert last["event"] == "config_updated_restart_failed"
    assert last["result"] == "warning"
