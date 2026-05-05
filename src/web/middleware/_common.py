"""Shared helpers for middleware modules.

``client_ip()`` is the single source of truth for source-IP extraction —
all rate-limit/audit/SSE-cap modules call this helper so any future
change to the X-Forwarded-For policy lives in one place.
"""

from __future__ import annotations

from flask import request


def client_ip() -> str:
    """Source-IP extraction with anti-spoofing.

    The reverse-proxy sample config (``systemd/failover-web.nginx.example``)
    sets ``proxy_set_header X-Forwarded-For $remote_addr`` (overwrite, not
    append) — client-supplied XFF is dropped before it reaches Flask.
    Reading the rightmost element is safe in both modes:
      * overwrite: only one element, equals rightmost.
      * append:    rightmost element is the trusted upstream.
    """
    fwd = request.headers.get("X-Forwarded-For", "")
    if fwd:
        return fwd.rsplit(",", 1)[-1].strip() or "unknown"
    return request.remote_addr or "unknown"


__all__ = ["client_ip"]
