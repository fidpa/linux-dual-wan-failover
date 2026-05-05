"""Per-IP cap for long-lived SSE connections.

gunicorn ``gthread`` workers hold a thread for the lifetime of an SSE
response. Without a per-IP cap, a single tab refresh loop or stuck client
can starve ``/api/state`` and other endpoints. ``SSE_MAX_CONNECTIONS_PER_IP``
caps the concurrent SSE slots per source IP.

Usage::

    @app.get("/api/events/stream")
    def stream():
        with reserve_slot() as slot:
            if slot is None:
                return jsonify({"error": "sse_per_ip_limit"}), 429
            return Response(_generator_using(slot), mimetype="text/event-stream")
"""

from __future__ import annotations

import threading
from collections import defaultdict
from collections.abc import Iterator
from contextlib import contextmanager

from .. import config
from ._common import client_ip as _client_ip

# Per-IP active-connection counters. With multiple gunicorn workers the
# counter is per-worker, not global — pick `--workers 1` for global accuracy.
_active: dict[str, int] = defaultdict(int)
_lock = threading.Lock()


@contextmanager
def reserve_slot() -> Iterator[str | None]:
    """Reserve an SSE slot for the current client IP.

    Yields:
        The client-IP string on success; ``None`` when the per-IP cap is
        already exhausted (caller should return 429).
    """
    ip = _client_ip()
    cap = config.SSE_MAX_CONNECTIONS_PER_IP
    with _lock:
        if _active[ip] >= cap:
            yield None
            return
        _active[ip] += 1
    try:
        yield ip
    finally:
        with _lock:
            _active[ip] -= 1
            if _active[ip] <= 0:
                _active.pop(ip, None)


def active_count(ip: str | None = None) -> int:
    """Inspection helper for tests + diagnostics."""
    with _lock:
        if ip is None:
            return sum(_active.values())
        return _active.get(ip, 0)


def reset_for_tests() -> None:
    with _lock:
        _active.clear()


__all__ = ["reserve_slot", "active_count", "reset_for_tests"]
