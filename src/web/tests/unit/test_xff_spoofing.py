"""Tests for the X-Forwarded-For rightmost-hop policy.

Both the audit_log and the rate_limit middleware MUST treat the rightmost
X-Forwarded-For value as the trusted client IP. nginx is configured to
overwrite XFF with `$remote_addr`, but the parser is robust against either
mode (overwrite or legacy append) by reading the rightmost value.
"""

from __future__ import annotations

from flask import Flask

from web.middleware import audit_log, rate_limit


def _app():
    app = Flask(__name__)
    return app


def test_audit_log_client_ip_reads_rightmost_xff():
    app = _app()
    with app.test_request_context(
        "/",
        environ_overrides={
            "REMOTE_ADDR": "127.0.0.1",
            "HTTP_X_FORWARDED_FOR": "1.2.3.4, 192.168.100.7",
        },
    ):
        ip = audit_log._client_ip()
    assert ip == "192.168.100.7"


def test_audit_log_falls_back_to_remote_addr_when_no_xff():
    app = _app()
    with app.test_request_context(
        "/",
        environ_overrides={"REMOTE_ADDR": "192.168.100.7"},
    ):
        ip = audit_log._client_ip()
    assert ip == "192.168.100.7"


def test_audit_log_handles_empty_xff_after_split():
    app = _app()
    with app.test_request_context(
        "/",
        environ_overrides={"REMOTE_ADDR": "1.1.1.1", "HTTP_X_FORWARDED_FOR": ", "},
    ):
        ip = audit_log._client_ip()
    # rsplit on empty/whitespace yields "" → fallback to "unknown"
    assert ip == "unknown"


def test_rate_limit_client_ip_reads_rightmost_xff():
    app = _app()
    with app.test_request_context(
        "/",
        environ_overrides={
            "REMOTE_ADDR": "127.0.0.1",
            "HTTP_X_FORWARDED_FOR": "evil.example.com, 10.0.0.42",
        },
    ):
        ip = rate_limit._client_ip()
    assert ip == "10.0.0.42"


def test_xff_attacker_first_value_is_ignored():
    """Spoofing the leftmost XFF value must not influence the trusted client IP."""
    app = _app()
    # Pretend nginx appended its $remote_addr after a spoofed value.
    with app.test_request_context(
        "/",
        environ_overrides={
            "REMOTE_ADDR": "127.0.0.1",
            "HTTP_X_FORWARDED_FOR": "8.8.8.8, 192.168.100.99",
        },
    ):
        assert audit_log._client_ip() != "8.8.8.8"
        assert audit_log._client_ip() == "192.168.100.99"
