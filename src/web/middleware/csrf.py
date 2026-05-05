"""Double-submit-cookie CSRF protection for mutating endpoints.

Pattern:
  - On any GET that returns the dashboard or a JSON snapshot, set the
    ``csrf_token`` cookie if it is missing. SameSite=Strict + Secure +
    HttpOnly (the token is exposed to JS via a ``<meta>`` tag instead).
  - On every POST/PUT/DELETE on routes registered as mutations, require
    BOTH a matching ``X-CSRF-Token`` header AND an Origin/Referer
    pointing at the trusted host. Mismatch → 403.

The Origin/Referer check closes the in-LAN ``curl -c jar -b jar`` bypass
that the cookie-only mechanism allowed.
"""

from __future__ import annotations

import hmac
import secrets
from collections.abc import Callable
from functools import wraps
from typing import Any
from urllib.parse import urlparse

from flask import Flask, Response, current_app, g, make_response, request

from .. import config

CSRF_COOKIE_NAME = "csrf_token"
CSRF_HEADER_NAME = "X-CSRF-Token"
_TOKEN_LENGTH_BYTES = 32


def _new_token() -> str:
    return secrets.token_urlsafe(_TOKEN_LENGTH_BYTES)


def _origin_allowed() -> bool:
    """Return True iff Origin or Referer points at one of the trusted hosts."""
    allowed_hosts = config.CSRF_ALLOWED_HOSTS
    if not allowed_hosts:
        return True  # configured-out → still rely on cookie+header
    for header_name in ("Origin", "Referer"):
        raw = request.headers.get(header_name, "")
        if not raw:
            continue
        try:
            parsed = urlparse(raw)
        except ValueError:
            continue
        host = parsed.hostname or ""
        if host in allowed_hosts:
            return True
    return False


def init_csrf(app: Flask) -> None:
    """Generate the token before_request and persist it via after_request.

    Order matters: ``before_request`` runs BEFORE template rendering, so
    ``g.csrf_token`` is populated when the dashboard renders. The matching
    ``after_request`` hook writes the cookie back when the token was newly
    minted (so the meta tag value matches what the browser then echoes).
    """

    @app.before_request
    def _ensure_csrf_token() -> None:
        token = request.cookies.get(CSRF_COOKIE_NAME)
        if not token:
            token = _new_token()
            g.csrf_token_new = token
        g.csrf_token = token

    @app.after_request
    def _attach_csrf_cookie(response: Response) -> Response:
        if getattr(g, "csrf_token_new", None):
            response.set_cookie(
                CSRF_COOKIE_NAME,
                g.csrf_token_new,
                max_age=60 * 60 * 24 * 7,  # 7 days
                secure=config.CSRF_COOKIE_SECURE,
                httponly=True,  # JS reads from <meta name="csrf-token"> instead
                samesite="Strict",
                path="/",
            )
        return response


def csrf_protect(view: Callable) -> Callable:
    """Decorator: enforce double-submit + same-origin on the wrapped view."""

    @wraps(view)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        if not _origin_allowed():
            current_app.logger.warning(
                "csrf origin reject path=%s origin=%r referer=%r",
                request.path,
                request.headers.get("Origin", ""),
                request.headers.get("Referer", ""),
            )
            return make_response(
                {"error": "csrf_failed", "detail": "Origin/Referer rejected"}, 403
            )
        cookie = request.cookies.get(CSRF_COOKIE_NAME, "")
        header = request.headers.get(CSRF_HEADER_NAME, "")
        if not cookie or not header or not hmac.compare_digest(cookie, header):
            return make_response(
                {"error": "csrf_failed", "detail": "Missing or mismatched CSRF token"}, 403
            )
        return view(*args, **kwargs)

    return wrapper


__all__ = ["init_csrf", "csrf_protect", "CSRF_COOKIE_NAME", "CSRF_HEADER_NAME"]
