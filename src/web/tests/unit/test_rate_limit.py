"""Rate-limit middleware tests."""

from __future__ import annotations

from flask import Flask, jsonify

from web.middleware import rate_limit


def _build_app(max_calls: int, per_seconds: float):
    app = Flask(__name__)

    @app.post("/limited")
    @rate_limit.rate_limit("test", max_calls=max_calls, per_seconds=per_seconds)
    def limited():
        return jsonify({"ok": True})

    return app


def setup_function(_):  # pytest hook
    rate_limit.reset_for_tests()


def test_allows_calls_below_limit():
    client = _build_app(max_calls=2, per_seconds=10).test_client()
    assert client.post("/limited").status_code == 200
    assert client.post("/limited").status_code == 200


def test_returns_429_when_exceeded():
    client = _build_app(max_calls=1, per_seconds=10).test_client()
    assert client.post("/limited").status_code == 200
    resp = client.post("/limited")
    assert resp.status_code == 429
    body = resp.get_json()
    assert body["error"] == "rate_limited"
    assert body["endpoint"] == "test"
    assert body["retry_after_seconds"] >= 1
    assert resp.headers["Retry-After"] == str(body["retry_after_seconds"])


def test_separate_endpoints_have_separate_buckets():
    app = Flask(__name__)

    @app.post("/a")
    @rate_limit.rate_limit("a", max_calls=1, per_seconds=10)
    def a():
        return jsonify({"ok": "a"})

    @app.post("/b")
    @rate_limit.rate_limit("b", max_calls=1, per_seconds=10)
    def b():
        return jsonify({"ok": "b"})

    client = app.test_client()
    assert client.post("/a").status_code == 200
    assert client.post("/b").status_code == 200
    assert client.post("/a").status_code == 429
    assert client.post("/b").status_code == 429


def test_separate_ips_have_separate_buckets():
    client = _build_app(max_calls=1, per_seconds=10).test_client()
    assert client.post("/limited", headers={"X-Forwarded-For": "10.0.0.5"}).status_code == 200
    # Different IP should get its own quota.
    assert client.post("/limited", headers={"X-Forwarded-For": "10.0.0.6"}).status_code == 200
    # Same first IP again → 429.
    assert client.post("/limited", headers={"X-Forwarded-For": "10.0.0.5"}).status_code == 429
