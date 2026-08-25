"""Atomic writer for the manual_action.json file consumed by failover-monitor.

Wire format (matches the daemon's ``process_manual_action_request``)::

    {"action":"failback|force_failover","request_id":"<uuid>","ts":<unix_seconds>}

We write to a sibling tempfile in the same directory, then ``os.rename`` —
POSIX guarantees this is atomic on the same filesystem, so the daemon either
sees the previous file (or nothing) or the complete new payload, never a
partially written one.

A file-level ``flock`` serialises concurrent writes from multiple gunicorn
workers; the daemon's request_id deduplication is the second line of defence.
"""

from __future__ import annotations

import errno
import json
import logging
import os
import time
import uuid
from pathlib import Path

from .. import config
from . import flock_path

_logger = logging.getLogger("failover_web.manual_action")


def _write_atomic(target: Path, payload: bytes) -> None:
    """Write ``payload`` to ``target`` via tempfile + rename in the same dir."""
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_name = f"{target.name}.{os.getpid()}.{uuid.uuid4().hex[:8]}.tmp"
    tmp = target.parent / tmp_name
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o664)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.rename(tmp, target)
    except OSError:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def submit_action(action: str, *, request_id: str | None = None) -> dict[str, object]:
    """Submit a manual action to the failover-monitor daemon.

    Args:
        action: One of ``failback`` or ``force_failover``.
        request_id: Optional UUID; one is generated if omitted.

    Returns:
        Dict with ``request_id``, ``action``, ``ts``, ``submitted`` (bool),
        and ``detail`` (string, present only on failure).

    Raises:
        ValueError: If the action is not in ``ALLOWED_MANUAL_ACTIONS``.
    """
    if action not in config.ALLOWED_MANUAL_ACTIONS:
        raise ValueError(f"Unknown action: {action!r}")
    rid = request_id or uuid.uuid4().hex
    ts = int(time.time())
    payload = {"action": action, "request_id": rid, "ts": ts}
    serialised = json.dumps(payload, separators=(",", ":")).encode("utf-8")

    result: dict[str, object] = {
        "request_id": rid,
        "action": action,
        "ts": ts,
        "submitted": False,
    }
    try:
        with flock_path(config.MANUAL_ACTION_LOCK):
            _write_atomic(config.MANUAL_ACTION_FILE, serialised)
        result["submitted"] = True
        _logger.info("manual_action submitted: %s (id=%s)", action, rid)
    except PermissionError as exc:
        result["detail"] = f"permission denied writing {config.MANUAL_ACTION_FILE}: {exc}"
        _logger.warning(result["detail"])
    except OSError as exc:
        if exc.errno == errno.ENOSPC:
            result["detail"] = "no space left on device"
        else:
            result["detail"] = f"OSError: {exc}"
        _logger.warning("manual_action write failed: %s", exc)
    return result
