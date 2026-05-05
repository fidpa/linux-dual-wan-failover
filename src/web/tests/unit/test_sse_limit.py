"""Unit tests for the SSE per-IP slot reservation."""

from __future__ import annotations

from flask import Flask

from web.middleware import sse_limit


def _app():
    app = Flask(__name__)
    return app


def test_reserve_slot_yields_ip_when_under_cap():
    app = _app()
    sse_limit.reset_for_tests()
    with app.test_request_context("/", environ_overrides={"REMOTE_ADDR": "10.0.0.50"}):
        with sse_limit.reserve_slot() as slot:
            assert slot == "10.0.0.50"
            assert sse_limit.active_count("10.0.0.50") == 1
    # On exit the slot is released.
    assert sse_limit.active_count("10.0.0.50") == 0


def test_reserve_slot_returns_none_at_cap(monkeypatch):
    from web import config as cfg
    monkeypatch.setattr(cfg, "SSE_MAX_CONNECTIONS_PER_IP", 2)
    app = _app()
    sse_limit.reset_for_tests()
    with app.test_request_context("/", environ_overrides={"REMOTE_ADDR": "10.0.0.51"}):
        cm1 = sse_limit.reserve_slot()
        s1 = cm1.__enter__()
        cm2 = sse_limit.reserve_slot()
        s2 = cm2.__enter__()
        assert s1 == "10.0.0.51"
        assert s2 == "10.0.0.51"
        # Third request from same IP must be rejected.
        with sse_limit.reserve_slot() as s3:
            assert s3 is None
        # Drop the two reserved slots.
        cm1.__exit__(None, None, None)
        cm2.__exit__(None, None, None)
    assert sse_limit.active_count("10.0.0.51") == 0


def test_reserve_slot_releases_after_disconnect_so_new_connection_passes(monkeypatch):
    from web import config as cfg
    monkeypatch.setattr(cfg, "SSE_MAX_CONNECTIONS_PER_IP", 1)
    app = _app()
    sse_limit.reset_for_tests()
    with app.test_request_context("/", environ_overrides={"REMOTE_ADDR": "10.0.0.52"}):
        with sse_limit.reserve_slot() as s1:
            assert s1 == "10.0.0.52"
            with sse_limit.reserve_slot() as s2:
                assert s2 is None  # at cap
        # First slot released — second attempt now succeeds.
        with sse_limit.reserve_slot() as s3:
            assert s3 == "10.0.0.52"


def test_reserve_slot_distinct_ips_have_independent_caps(monkeypatch):
    from web import config as cfg
    monkeypatch.setattr(cfg, "SSE_MAX_CONNECTIONS_PER_IP", 1)
    app = _app()
    sse_limit.reset_for_tests()
    with app.test_request_context("/", environ_overrides={"REMOTE_ADDR": "10.0.0.53"}):
        cm_a = sse_limit.reserve_slot()
        cm_a.__enter__()
    with app.test_request_context("/", environ_overrides={"REMOTE_ADDR": "10.0.0.54"}):
        cm_b = sse_limit.reserve_slot()
        slot_b = cm_b.__enter__()
        assert slot_b == "10.0.0.54"
        cm_b.__exit__(None, None, None)
    cm_a.__exit__(None, None, None)
    sse_limit.reset_for_tests()


def test_reserve_slot_uses_rightmost_xff(monkeypatch):
    """Spoofing XFF must not bypass the per-IP cap — the rightmost hop wins."""
    from web import config as cfg
    monkeypatch.setattr(cfg, "SSE_MAX_CONNECTIONS_PER_IP", 1)
    app = _app()
    sse_limit.reset_for_tests()
    with app.test_request_context(
        "/",
        environ_overrides={
            "REMOTE_ADDR": "127.0.0.1",
            "HTTP_X_FORWARDED_FOR": "1.2.3.4, 10.0.0.55",  # nginx-appended truth
        },
    ):
        with sse_limit.reserve_slot() as ip:
            # rightmost — the trusted (nginx-appended) hop, not the spoofed first
            assert ip == "10.0.0.55"
    sse_limit.reset_for_tests()
