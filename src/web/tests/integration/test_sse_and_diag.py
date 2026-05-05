"""SSE heartbeat / disconnect tests + api_diag route tests (TEST-HIGH-01/02)."""

from __future__ import annotations

import time

import pytest

from web.middleware import rate_limit, sse_limit
from web.middleware.csrf import CSRF_COOKIE_NAME, CSRF_HEADER_NAME


@pytest.fixture(autouse=True)
def _clean_state():
    rate_limit.reset_for_tests()
    sse_limit.reset_for_tests()
    yield
    rate_limit.reset_for_tests()
    sse_limit.reset_for_tests()


def _csrf_post(client, path, json_body=None):
    client.get("/api/state")
    cookie_obj = next((c for c in client._cookies.values() if c.key == CSRF_COOKIE_NAME), None)
    assert cookie_obj is not None
    headers = {CSRF_HEADER_NAME: cookie_obj.value, "Origin": "http://localhost"}
    return client.post(path, headers=headers, json=json_body or {})


# ---------------------------------------------------------------------------
# SSE heartbeat (TEST-HIGH-01)
# ---------------------------------------------------------------------------


def test_sse_emits_heartbeat_after_threshold(client, monkeypatch):
    """Heartbeat keeps the connection alive through nginx proxy_read_timeout."""
    from web import config as cfg
    monkeypatch.setattr(cfg, "SSE_TICK_SECONDS", 0.05)
    # Trigger heartbeat after each tick.
    monkeypatch.setattr(cfg, "SSE_HEARTBEAT_SECONDS", 0.0)

    with client.get("/api/events/stream", buffered=False) as resp:
        assert resp.status_code == 200
        chunks: list[str] = []
        deadline = time.monotonic() + 2.0
        for raw in resp.response:
            chunks.append(raw.decode("utf-8"))
            joined = "".join(chunks)
            if "event: state" in joined and ": heartbeat" in joined:
                break
            if time.monotonic() > deadline:
                break
    joined = "".join(chunks)
    assert "event: state" in joined, "no state event in SSE stream"
    assert ": heartbeat" in joined, "no heartbeat in SSE stream"


def test_sse_per_ip_cap_returns_429(client, monkeypatch):
    """When the slot map already records the cap, a fresh request gets 429."""
    from web import config as cfg
    monkeypatch.setattr(cfg, "SSE_MAX_CONNECTIONS_PER_IP", 1)

    # Pre-populate the in-memory counter — equivalent to one already-active SSE.
    sse_limit._active["127.0.0.1"] = 1
    try:
        resp = client.get("/api/events/stream", buffered=False)
        assert resp.status_code == 429
        body = resp.get_json()
        assert body["error"] == "sse_per_ip_limit"
    finally:
        sse_limit._active.clear()


def test_sse_disconnect_releases_slot(client, monkeypatch):
    """Opening then closing an SSE response releases the slot."""
    from web import config as cfg
    monkeypatch.setattr(cfg, "SSE_MAX_CONNECTIONS_PER_IP", 2)
    monkeypatch.setattr(cfg, "SSE_TICK_SECONDS", 0.05)

    first = client.get("/api/events/stream", buffered=False)
    assert first.status_code == 200
    # Read one chunk then close — simulates client disconnect.
    iterator = iter(first.response)
    next(iterator, None)
    first.close()
    # Allow the generator's `finally` to run.
    time.sleep(0.05)
    # Slot count back at 0.
    assert sse_limit.active_count("127.0.0.1") == 0


# ---------------------------------------------------------------------------
# api_diag (TEST-HIGH-02)
# ---------------------------------------------------------------------------


def _patch_alerts(monkeypatch):
    monkeypatch.setattr(
        "web.app.dispatcher.send",
        lambda *a, **k: True,
    )


def test_api_diag_streams_lines(client, monkeypatch):
    _patch_alerts(monkeypatch)

    def fake_stream(argv):
        yield "event: start\ndata: ping 1.1.1.1\n\n"
        yield "data: 64 bytes from 1.1.1.1\n\n"
        yield "event: end\ndata: 0\n\n"

    monkeypatch.setattr(
        "web.app.diag_runner.stream_command", fake_stream
    )
    resp = _csrf_post(
        client,
        "/api/diag/ping",
        json_body={"target": "1.1.1.1", "iface": "eth0", "count": 2},
    )
    assert resp.status_code == 200
    assert resp.mimetype == "text/event-stream"
    body = resp.get_data(as_text=True)
    assert "event: start" in body
    assert "64 bytes" in body
    assert "event: end" in body


def test_api_diag_rejects_invalid_target(client, monkeypatch):
    _patch_alerts(monkeypatch)
    resp = _csrf_post(
        client,
        "/api/diag/ping",
        json_body={"target": "8.8.8.8;rm -rf", "iface": "eth0", "count": 2},
    )
    assert resp.status_code == 400
    body = resp.get_json()
    assert body["error"] == "invalid_input"


def test_api_diag_default_iface_empty_string_normalised_to_none(client, monkeypatch):
    """Empty-string iface (the dashboard default) must be normalised to None."""
    _patch_alerts(monkeypatch)

    def fake_stream(argv):
        yield "event: start\ndata: ok\n\n"
        yield "event: end\ndata: 0\n\n"

    monkeypatch.setattr(
        "web.app.diag_runner.stream_command", fake_stream
    )
    resp = _csrf_post(
        client,
        "/api/diag/ping",
        json_body={"target": "1.1.1.1", "iface": "", "count": 1},
    )
    assert resp.status_code == 200, resp.get_data(as_text=True)


def test_api_diag_unknown_tool_rejected(client, monkeypatch):
    _patch_alerts(monkeypatch)
    resp = _csrf_post(
        client,
        "/api/diag/format-c",
        json_body={"target": "1.1.1.1", "count": 1},
    )
    assert resp.status_code == 400
    assert resp.get_json()["error"] == "invalid_input"


def test_api_diag_rate_limited(client, monkeypatch):
    _patch_alerts(monkeypatch)

    def fake_stream(argv):
        yield "event: end\ndata: 0\n\n"

    monkeypatch.setattr(
        "web.app.diag_runner.stream_command", fake_stream
    )
    first = _csrf_post(client, "/api/diag/ping", json_body={"target": "1.1.1.1", "count": 1})
    first.close()
    second = _csrf_post(client, "/api/diag/ping", json_body={"target": "1.1.1.1", "count": 1})
    assert second.status_code == 429


def test_api_diag_writes_audit_log(client, fixtures_dir, monkeypatch):
    _patch_alerts(monkeypatch)

    def fake_stream(argv):
        yield "event: end\ndata: 0\n\n"

    monkeypatch.setattr(
        "web.app.diag_runner.stream_command", fake_stream
    )
    resp = _csrf_post(
        client,
        "/api/diag/ping",
        json_body={"target": "1.1.1.1", "iface": "eth0", "count": 1},
    )
    assert resp.status_code == 200

    # Drain the response so the SSE generator's `finally` runs.
    list(resp.response)
    resp.close()

    audit_path = fixtures_dir / "audit.log"
    if audit_path.exists():
        records = [r for r in audit_path.read_text().splitlines() if r]
        events = {r.split('"event":"')[1].split('"')[0] for r in records}
        assert "diag_started" in events


def test_api_diag_csrf_is_required(client):
    resp = client.post("/api/diag/ping", json={"target": "1.1.1.1"})
    assert resp.status_code == 403


def test_api_diag_returns_429_when_sse_slot_cap_exhausted(client, monkeypatch):
    """TEST-OPT-5: api_diag share the per-IP SSE pool with /api/events/stream.

    Pre-fill the slot counter to the cap so the diag-route's own slot reserve
    fails — we must get 429 with `sse_per_ip_limit`, AND the diag command must
    NOT have been spawned (the audit log records `diag_started` BEFORE the slot
    reservation, but `stream_command` must not run).
    """
    from web import config as cfg

    monkeypatch.setattr(cfg, "SSE_MAX_CONNECTIONS_PER_IP", 1)
    spawned: list[list[str]] = []

    def fake_stream(argv):
        spawned.append(argv)
        yield "data: should-not-happen\n\n"

    monkeypatch.setattr(
        "web.app.diag_runner.stream_command", fake_stream
    )
    _patch_alerts(monkeypatch)

    sse_limit._active["127.0.0.1"] = 1
    try:
        resp = _csrf_post(
            client, "/api/diag/ping", json_body={"target": "1.1.1.1", "count": 1}
        )
        assert resp.status_code == 429
        body = resp.get_json()
        assert body["error"] == "sse_per_ip_limit"
        # Generator must not have been consumed.
        assert spawned == []
    finally:
        sse_limit._active.clear()
