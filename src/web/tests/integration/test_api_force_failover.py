"""Integration tests for /api/force-failover."""

from __future__ import annotations

import json
from typing import Any

import pytest

from web.middleware import rate_limit
from web.middleware.csrf import CSRF_COOKIE_NAME, CSRF_HEADER_NAME


@pytest.fixture(autouse=True)
def _clean_rate_limit():
    rate_limit.reset_for_tests()
    yield
    rate_limit.reset_for_tests()


def _patch_alerts(monkeypatch):
    sent: list[tuple[str, str]] = []
    monkeypatch.setattr(
        "web.app.dispatcher.send",
        lambda alert_type, message, **k: sent.append((alert_type, message)) or True,
    )
    return sent


def _csrf_post(client, path: str, data: dict[str, Any] | None = None, json_body: dict[str, Any] | None = None):
    client.get("/api/state")
    cookie_obj = next((c for c in client._cookies.values() if c.key == CSRF_COOKIE_NAME), None)
    assert cookie_obj is not None
    headers = {CSRF_HEADER_NAME: cookie_obj.value, "Origin": "http://localhost"}
    if json_body is not None:
        return client.post(path, headers=headers, json=json_body)
    return client.post(path, headers=headers, data=data or {})


# ---------------------------------------------------------------------------
# /api/force-failover
#
# Operator confirmation is the browser `hx-confirm` dialog (consistent with
# failback). CSRF + Origin + rate-limit + audit-log are the server-side
# defences.
# ---------------------------------------------------------------------------


def test_force_failover_succeeds_when_on_primary(client, fresh_state, monkeypatch):
    sent = _patch_alerts(monkeypatch)
    # fresh_state has current_wan="primary" → force_failover is valid
    resp = _csrf_post(client, "/api/force-failover")
    assert resp.status_code == 202
    body = resp.get_json()
    assert body["status"] == "submitted"

    manual_action = fresh_state / "wan-state" / "manual_action.json"
    payload = json.loads(manual_action.read_text())
    assert payload["action"] == "force_failover"
    assert payload["request_id"] == body["request_id"]
    assert sent and sent[0][0] == "CRIT_FAILOVER"


def test_force_failover_csrf_required(client, fresh_state, monkeypatch):
    """No-CSRF callers (curl without cookie+header) must still hit 403."""
    _patch_alerts(monkeypatch)
    resp = client.post("/api/force-failover")
    assert resp.status_code == 403


def test_force_failover_rejects_when_already_on_backup(client, fixtures_dir, monkeypatch):
    # Re-write state to current_wan=backup
    payload = {
        "timestamp": 1,
        "current_wan": "backup",
        "primary_interface": "eth0",
        "backup_interface": "lte0",
        "scores": {"eth0": 50, "lte0": 90},
        "counters": {"eth0": {"failures": 5, "recoveries": 0}, "lte0": {"failures": 0, "recoveries": 50}},
        "thresholds": {"failure": 5, "recovery": 20},
    }
    (fixtures_dir / "wan-state" / "connection_metrics").write_text(json.dumps(payload))
    (fixtures_dir / "wan_quality.prom").write_text("wan_latency_milliseconds{interface=\"eth0\"} 5\n")

    from web.app import create_app
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        _patch_alerts(monkeypatch)
        resp = _csrf_post(c, "/api/force-failover")
        assert resp.status_code == 409
        assert resp.get_json()["status"] == "noop"


def test_force_failover_rate_limited_after_one_call(client, fresh_state, monkeypatch):
    _patch_alerts(monkeypatch)
    first = _csrf_post(client, "/api/force-failover")
    assert first.status_code == 202
    second = _csrf_post(client, "/api/force-failover")
    assert second.status_code == 429


def test_force_failover_returns_500_when_submission_fails(
    client, fresh_state, monkeypatch
):
    """writer failure (lock held / ENOSPC) → HTTP 500 + audit error event."""
    import time as _time

    _patch_alerts(monkeypatch)
    monkeypatch.setattr(
        "web.app.manual_action_writer.submit_action",
        lambda action, **k: {
            "request_id": "force-rid",
            "action": action,
            "ts": int(_time.time()),
            "submitted": False,
            "detail": "ENOSPC",
        },
    )

    resp = _csrf_post(client, "/api/force-failover")
    assert resp.status_code == 500
    body = resp.get_json()
    assert body["error"] == "submission_failed"
    assert body["request_id"] == "force-rid"

    audit_path = fresh_state / "audit.log"
    records = [
        json.loads(ln) for ln in audit_path.read_text().splitlines() if ln.strip()
    ]
    failed = [r for r in records if r["event"] == "force_failover_failed"]
    assert len(failed) == 1
    assert failed[0]["result"] == "error"
