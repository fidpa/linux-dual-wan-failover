"""Alerting plugin dispatcher.

The Web-UI does not call any specific notification backend directly. It
delegates to the same plugin contract documented in
``plugins/alerting/README.md`` — a Bash file that defines a single
``send_alert`` function.

Resolution order (mirrors ``common.sh::send_notification``):

  1. ``ALERTING_PLUGIN_PATH`` (full path override, custom plugins).
  2. ``ALERTING_PLUGIN_DIR/<ALERTING_BACKEND>.sh``.
  3. ``<repo>/plugins/alerting/<ALERTING_BACKEND>.sh`` (dev / tests).

If ``ALERTING_BACKEND=none`` (default) or no plugin file resolves, the
dispatcher silently degrades to a no-op so the request flow is never
blocked by an alerting failure.
"""

from __future__ import annotations

import logging
import shlex
import subprocess
from pathlib import Path

from .. import config

_logger = logging.getLogger("failover_web.alerts")


def _repo_plugin_path(backend: str) -> Path:
    """Best-effort fallback used by tests and dev installs.

    Walks up to ``<repo>/plugins/alerting/<backend>.sh`` based on the
    ``src/web/`` location of this module.
    """
    here = Path(__file__).resolve()
    # src/web/alerts/dispatcher.py → src/web/alerts → src/web → src → repo
    repo = here.parents[3]
    return repo / "plugins" / "alerting" / f"{backend}.sh"


def _resolve_plugin() -> Path | None:
    """Return the plugin path for the configured backend, or ``None``."""
    backend = config.ALERTING_BACKEND
    if not backend or backend == "none":
        return None

    if config.ALERTING_PLUGIN_PATH:
        path = Path(config.ALERTING_PLUGIN_PATH)
        if path.is_file():
            return path
        _logger.warning(
            "ALERTING_PLUGIN_PATH=%s does not exist — falling back to ALERTING_PLUGIN_DIR",
            path,
        )

    dir_path = config.ALERTING_PLUGIN_DIR / f"{backend}.sh"
    if dir_path.is_file():
        return dir_path

    repo_path = _repo_plugin_path(backend)
    if repo_path.is_file():
        return repo_path

    _logger.warning(
        "alerting plugin %r not found (checked %s, %s) — alert dropped",
        backend,
        dir_path,
        repo_path,
    )
    return None


def send(alert_type: str, message: str, *, timeout: float | None = None) -> bool:
    """Dispatch an alert to the configured plugin.

    Args:
        alert_type: One of ``INFO_FAILOVER``, ``WARN_FAILOVER``, ``CRIT_FAILOVER``
            (mirrors the Bash plugin contract). Backends that need a finer
            severity may parse this further.
        message: Human-readable message body.
        timeout: Optional override for the subprocess timeout (seconds).

    Returns:
        ``True`` if the plugin invocation succeeded (exit code 0), ``False``
        otherwise. Failures are always logged but never raised — the
        caller's request flow must not be blocked by alerting.
    """
    plugin = _resolve_plugin()
    if plugin is None:
        return False

    quoted_type = shlex.quote(alert_type)
    quoted_msg = shlex.quote(message)
    quoted_plugin = shlex.quote(str(plugin))
    cmd = [
        "/bin/bash",
        "-c",
        f". {quoted_plugin} && send_alert {quoted_type} {quoted_msg}",
    ]

    effective_timeout = timeout if timeout is not None else config.ALERT_TIMEOUT_SECONDS
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=effective_timeout,
            check=False,
        )
        if proc.returncode != 0:
            _logger.warning(
                "alerting plugin %s returned %s: stderr=%s",
                plugin.name,
                proc.returncode,
                proc.stderr.strip()[:500],
            )
            return False
        return True
    except subprocess.TimeoutExpired:
        _logger.warning("alerting plugin %s timed out after %ss", plugin.name, effective_timeout)
        return False
    except (OSError, ValueError) as exc:
        _logger.warning("alerting plugin %s failed: %s", plugin.name, exc)
        return False


__all__ = ["send"]
