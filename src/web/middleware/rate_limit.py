"""In-process token-bucket rate limiter (per source IP, per endpoint).

We avoid Flask-Limiter to keep the dep-list small. The limiter is in-memory
per gunicorn worker, which is acceptable for an operations dashboard with
a handful of operators. On a single-worker setup the count is globally
accurate.
"""

from __future__ import annotations

import threading
import time
from collections import defaultdict
from collections.abc import Callable
from functools import wraps
from typing import Any

from flask import jsonify

from ._common import client_ip as _client_ip

# {(endpoint, ip): (last_call_ts, calls_in_window)}
_state: dict[tuple[str, str], tuple[float, int]] = defaultdict(lambda: (0.0, 0))
_lock = threading.Lock()


def rate_limit(endpoint: str, *, max_calls: int, per_seconds: float) -> Callable:
    """Decorator factory: enforce ``max_calls`` per ``per_seconds`` per IP."""

    def decorator(view: Callable) -> Callable:
        @wraps(view)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            ip = _client_ip()
            now = time.monotonic()
            key = (endpoint, ip)
            with _lock:
                last_ts, count = _state[key]
                if now - last_ts > per_seconds:
                    _state[key] = (now, 1)
                else:
                    if count >= max_calls:
                        retry_after = int(per_seconds - (now - last_ts)) + 1
                        resp = jsonify(
                            {
                                "error": "rate_limited",
                                "endpoint": endpoint,
                                "retry_after_seconds": retry_after,
                            }
                        )
                        resp.status_code = 429
                        resp.headers["Retry-After"] = str(retry_after)
                        return resp
                    _state[key] = (last_ts, count + 1)
            return view(*args, **kwargs)

        return wrapper

    return decorator


def reset_for_tests() -> None:
    """Test-only helper: clear all buckets."""
    with _lock:
        _state.clear()
