"""CSRF middleware tests."""

from __future__ import annotations

from flask import Flask, jsonify

from web.middleware.csrf import (
    CSRF_COOKIE_NAME,
    CSRF_HEADER_NAME,
    csrf_protect,
    init_csrf,
)


def _build_app():
    app = Flask(__name__)
    init_csrf(app)

    @app.get("/issue")
    def issue():
        return jsonify({"ok": True})

    @app.post("/mutate")
    @csrf_protect
    def mutate():
        return jsonify({"ok": True})

    return app


_GOOD_ORIGIN = {"Origin": "http://localhost"}


def test_get_request_sets_csrf_cookie(monkeypatch):
    # Force the production posture (Secure=True) regardless of the env the
    # developer happens to have set for local-dev iteration.
    from web import config as cfg
    monkeypatch.setattr(cfg, "CSRF_COOKIE_SECURE", True)
    client = _build_app().test_client()
    resp = client.get("/issue")
    assert resp.status_code == 200
    set_cookie = resp.headers.get("Set-Cookie", "")
    assert CSRF_COOKIE_NAME in set_cookie
    assert "SameSite=Strict" in set_cookie
    assert "Path=/" in set_cookie
    assert "HttpOnly" in set_cookie  # cookie not readable from JS
    assert "Secure" in set_cookie    # cookie only over HTTPS


def test_post_without_token_is_rejected():
    client = _build_app().test_client()
    resp = client.post("/mutate", headers=_GOOD_ORIGIN)
    assert resp.status_code == 403
    assert resp.get_json()["error"] == "csrf_failed"


def test_post_with_matching_token_succeeds():
    client = _build_app().test_client()
    issue = client.get("/issue")
    set_cookie = issue.headers["Set-Cookie"]
    token = set_cookie.split(f"{CSRF_COOKIE_NAME}=", 1)[1].split(";", 1)[0]
    resp = client.post(
        "/mutate",
        headers={CSRF_HEADER_NAME: token, **_GOOD_ORIGIN},
    )
    assert resp.status_code == 200
    assert resp.get_json()["ok"] is True


def test_post_with_mismatched_token_is_rejected():
    client = _build_app().test_client()
    client.set_cookie(domain="localhost", key=CSRF_COOKIE_NAME, value="cookie-token")
    resp = client.post(
        "/mutate",
        headers={CSRF_HEADER_NAME: "header-token", **_GOOD_ORIGIN},
    )
    assert resp.status_code == 403


def test_post_without_origin_or_referer_is_rejected():
    """curl without Origin/Referer header must not bypass CSRF via cookie copy."""
    client = _build_app().test_client()
    issue = client.get("/issue")
    set_cookie = issue.headers["Set-Cookie"]
    token = set_cookie.split(f"{CSRF_COOKIE_NAME}=", 1)[1].split(";", 1)[0]
    resp = client.post("/mutate", headers={CSRF_HEADER_NAME: token})
    assert resp.status_code == 403
    assert "Origin" in resp.get_json().get("detail", "") or "Referer" in resp.get_json().get("detail", "")


def test_post_with_foreign_origin_is_rejected():
    client = _build_app().test_client()
    issue = client.get("/issue")
    set_cookie = issue.headers["Set-Cookie"]
    token = set_cookie.split(f"{CSRF_COOKIE_NAME}=", 1)[1].split(";", 1)[0]
    resp = client.post(
        "/mutate",
        headers={CSRF_HEADER_NAME: token, "Origin": "http://attacker.example.com"},
    )
    assert resp.status_code == 403


def test_post_with_referer_only_is_accepted():
    client = _build_app().test_client()
    issue = client.get("/issue")
    set_cookie = issue.headers["Set-Cookie"]
    token = set_cookie.split(f"{CSRF_COOKIE_NAME}=", 1)[1].split(";", 1)[0]
    resp = client.post(
        "/mutate",
        headers={CSRF_HEADER_NAME: token, "Referer": "http://localhost/"},
    )
    assert resp.status_code == 200


def test_origin_check_skipped_when_allowed_hosts_empty(monkeypatch):
    """Escape-hatch (csrf.py:44-46): empty CSRF_ALLOWED_HOSTS bypasses origin check.

    Documented as configured-out / CI-only fallback. Cookie+header still required.
    """
    from web import config as cfg

    monkeypatch.setattr(cfg, "CSRF_ALLOWED_HOSTS", ())
    client = _build_app().test_client()
    issue = client.get("/issue")
    set_cookie = issue.headers["Set-Cookie"]
    token = set_cookie.split(f"{CSRF_COOKIE_NAME}=", 1)[1].split(";", 1)[0]
    resp = client.post("/mutate", headers={CSRF_HEADER_NAME: token})  # no Origin
    assert resp.status_code == 200


def test_post_with_malformed_origin_is_rejected(monkeypatch):
    """csrf.py:51-54: urlparse ValueError on malformed Origin must not crash —
    the header is skipped and the request rejected when no other valid header
    is present.
    """
    client = _build_app().test_client()
    issue = client.get("/issue")
    set_cookie = issue.headers["Set-Cookie"]
    token = set_cookie.split(f"{CSRF_COOKIE_NAME}=", 1)[1].split(";", 1)[0]
    # `http://[bad` raises "Invalid IPv6 URL" inside urlparse — middleware must
    # swallow it and fall through to the rejection branch.
    resp = client.post(
        "/mutate",
        headers={CSRF_HEADER_NAME: token, "Origin": "http://[bad"},
    )
    assert resp.status_code == 403
    assert resp.get_json()["error"] == "csrf_failed"
