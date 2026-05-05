"""Integration tests for POST /api/failback."""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from web.middleware import rate_limit
from web.middleware.csrf import CSRF_COOKIE_NAME, CSRF_HEADER_NAME


@pytest.fixture(autouse=True)
def _clean_rate_limit():
    rate_limit.reset_for_tests()
    yield
    rate_limit.reset_for_tests()


def _backup_state(fixtures_dir: Path):
    """Write a snapshot where current_wan='backup' so failback is valid."""
    payload = {
        "timestamp": int(time.time()),
        "current_wan": "backup",
        "primary_interface": "eth0",
        "backup_interface": "lte0",
        "scores": {"eth0": 95, "lte0": 88},
        "counters": {"eth0": {"failures": 0, "recoveries": 200}, "lte0": {"failures": 0, "recoveries": 200}},
        "thresholds": {"failure": 5, "recovery": 20},
    }
    (fixtures_dir / "wan-state" / "connection_metrics").write_text(json.dumps(payload))
    (fixtures_dir / "wan_quality.prom").write_text(
        'wan_latency_milliseconds{interface="eth0"} 0.5\n'
        'wan_latency_milliseconds{interface="lte0"} 1.2\n'
        'wan_quality_score{interface="eth0"} 80\n'
        'wan_quality_score{interface="lte0"} 60\n'
    )
    return fixtures_dir


def _patch_alerts(monkeypatch):
    sent: list[tuple[str, str]] = []

    def fake_send(alert_type, message, **kwargs):
        sent.append((alert_type, message))
        return True

    monkeypatch.setattr("web.app.dispatcher.send", fake_send)
    return sent


def _csrf_post(client, path: str, headers: dict | None = None):
    """Issue cookie via GET, then POST with matching X-CSRF-Token + Origin."""
    client.get("/api/state")  # ensures cookie is set on the test client jar
    # Read the cookie back from the test-client jar (works regardless of whether
    # the second/third GET re-issued Set-Cookie or not).
    cookie_obj = next(
        (c for c in client._cookies.values() if c.key == CSRF_COOKIE_NAME), None
    )
    assert cookie_obj is not None, "CSRF cookie was not issued"
    token = cookie_obj.value
    base_headers = {
        CSRF_HEADER_NAME: token,
        "Origin": "http://localhost",
    }
    return client.post(path, headers={**base_headers, **(headers or {})})


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


def test_failback_when_on_backup_writes_manual_action_and_returns_202(
    client, fixtures_dir, monkeypatch
):
    _backup_state(fixtures_dir)
    sent = _patch_alerts(monkeypatch)

    resp = _csrf_post(client, "/api/failback")
    assert resp.status_code == 202
    body = resp.get_json()
    assert body["status"] == "submitted"
    assert "request_id" in body
    assert "ts" in body

    manual_action = fixtures_dir / "wan-state" / "manual_action.json"
    assert manual_action.exists()
    payload = json.loads(manual_action.read_text())
    assert payload["action"] == "failback"
    assert payload["request_id"] == body["request_id"]
    assert payload["ts"] == body["ts"]

    assert len(sent) == 1
    assert sent[0][0] == "WARN_FAILOVER"
    assert "request_id" in sent[0][1]


def test_failback_writes_audit_record(client, fixtures_dir, monkeypatch):
    _backup_state(fixtures_dir)
    _patch_alerts(monkeypatch)

    resp = _csrf_post(client, "/api/failback")
    assert resp.status_code == 202

    audit_path = fixtures_dir / "audit.log"
    lines = [ln for ln in audit_path.read_text().splitlines() if ln.strip()]
    records = [json.loads(ln) for ln in lines]
    submitted = [r for r in records if r["event"] == "failback_submitted"]
    assert len(submitted) == 1
    assert submitted[0]["result"] == "ok"
    assert "request_id" in submitted[0]["payload"]


# ---------------------------------------------------------------------------
# CSRF / Rate-limit
# ---------------------------------------------------------------------------


def test_failback_without_csrf_token_returns_403(client, fixtures_dir):
    _backup_state(fixtures_dir)
    resp = client.post("/api/failback")
    assert resp.status_code == 403
    assert resp.get_json()["error"] == "csrf_failed"


def test_failback_rate_limit_429_after_one_call(client, fixtures_dir, monkeypatch):
    _backup_state(fixtures_dir)
    _patch_alerts(monkeypatch)

    first = _csrf_post(client, "/api/failback")
    assert first.status_code == 202
    second = _csrf_post(client, "/api/failback")
    assert second.status_code == 429
    body = second.get_json()
    assert body["error"] == "rate_limited"
    assert body["endpoint"] == "failback"


# ---------------------------------------------------------------------------
# Refusal paths (state preconditions)
# ---------------------------------------------------------------------------


def test_failback_when_on_primary_returns_409_noop(client, fresh_state, monkeypatch):
    # fresh_state fixture sets current_wan="primary"
    _patch_alerts(monkeypatch)
    resp = _csrf_post(client, "/api/failback")
    assert resp.status_code == 409
    body = resp.get_json()
    assert body["status"] == "noop"
    assert body["current_wan"] == "primary"

    manual_action = fresh_state / "wan-state" / "manual_action.json"
    assert not manual_action.exists()


def test_failback_when_state_missing_returns_503(client_no_state):
    # No connection_metrics file written → freshness=missing
    resp = _csrf_post(client_no_state, "/api/failback")
    assert resp.status_code == 503
    assert resp.get_json()["error"] == "state_missing"


def test_failback_returns_500_when_submission_fails(client, fixtures_dir, monkeypatch):
    """manual_action_writer failure (e.g. lock held) → HTTP 500.

    Triggered by submit_action returning ``submitted=False`` (Permission, ENOSPC,
    OSError). We patch the writer directly to keep the test deterministic.
    """
    _backup_state(fixtures_dir)
    _patch_alerts(monkeypatch)
    monkeypatch.setattr(
        "web.app.manual_action_writer.submit_action",
        lambda action, **k: {
            "request_id": "test-rid",
            "action": action,
            "ts": int(time.time()),
            "submitted": False,
            "detail": "lock held by another writer",
        },
    )

    resp = _csrf_post(client, "/api/failback")
    assert resp.status_code == 500
    body = resp.get_json()
    assert body["error"] == "submission_failed"
    assert body["request_id"] == "test-rid"

    audit_path = fixtures_dir / "audit.log"
    records = [
        json.loads(ln) for ln in audit_path.read_text().splitlines() if ln.strip()
    ]
    failed = [r for r in records if r["event"] == "failback_failed"]
    assert len(failed) == 1
    assert failed[0]["result"] == "error"
