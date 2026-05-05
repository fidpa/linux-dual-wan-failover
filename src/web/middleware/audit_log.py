"""Append-only JSON-Lines audit log for every mutation."""

from __future__ import annotations

import json
import logging
import threading
import time
from logging.handlers import RotatingFileHandler
from typing import Any

from flask import request

from .. import config
from ._common import client_ip as _client_ip

_lock = threading.Lock()
_logger: logging.Logger | None = None


def _logger_singleton() -> logging.Logger:
    global _logger
    if _logger is not None:
        return _logger
    lg = logging.getLogger("failover_web.audit")
    lg.setLevel(logging.INFO)
    lg.propagate = False
    try:
        handler: logging.Handler = RotatingFileHandler(
            config.AUDIT_LOG,
            maxBytes=config.LOG_MAX_BYTES,
            backupCount=config.AUDIT_LOG_BACKUP_COUNT,
        )
    except (PermissionError, FileNotFoundError) as exc:
        # Audit-tampering threat: a silent fallback to stderr would let the
        # dashboard run without forensic evidence. Refuse loud rather than
        # degrade silent.
        if config.AUDIT_LOG_REQUIRE_FILE:
            raise RuntimeError(
                f"audit log not writable at {config.AUDIT_LOG}: {exc}; "
                "set FAILOVER_WEB_AUDIT_LOG_REQUIRE_FILE=0 to allow stderr fallback"
            ) from exc
        handler = logging.StreamHandler()
        logging.getLogger("failover_web").warning(
            "audit log unwritable at %s — falling back to stderr (forensic gap)",
            config.AUDIT_LOG,
        )
    handler.setFormatter(logging.Formatter("%(message)s"))
    lg.handlers = [handler]
    _logger = lg
    return lg


def emit(event: str, *, result: str = "ok", payload: dict[str, Any] | None = None) -> None:
    """Append one JSON-Lines record."""
    record: dict[str, Any] = {
        "ts": int(time.time()),
        "iso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "src_ip": _client_ip(),
        "method": request.method,
        "path": request.path,
        "event": event,
        "result": result,
    }
    if payload is not None:
        record["payload"] = payload
    line = json.dumps(record, separators=(",", ":"), sort_keys=True)
    with _lock:
        _logger_singleton().info(line)
