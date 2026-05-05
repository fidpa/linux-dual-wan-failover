"""Privileged service control via NOPASSWD sudo.

Restart is the only mutation. The sudoers fragment shipped at
``systemd/failover-web.sudoers`` scopes the rule to exactly this
invocation; anything else is denied.
"""

from __future__ import annotations

import logging
import subprocess

from .. import config

_logger = logging.getLogger("failover_web.service_controller")

SYSTEMCTL = "/usr/bin/systemctl"


def restart_target_service(timeout: float = 15.0) -> dict[str, object]:
    """Run ``sudo systemctl restart <TARGET_SERVICE>``."""
    cmd = ["/usr/bin/sudo", "-n", SYSTEMCTL, "restart", config.TARGET_SERVICE]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": proc.stdout.strip()[:500],
            "stderr": proc.stderr.strip()[:500],
        }
    except subprocess.TimeoutExpired:
        _logger.warning("systemctl restart timed out after %ss", timeout)
        return {"ok": False, "returncode": -1, "stdout": "", "stderr": "timeout"}
    except (OSError, ValueError) as exc:
        _logger.warning("systemctl restart failed: %s", exc)
        return {"ok": False, "returncode": -1, "stdout": "", "stderr": str(exc)}


def is_target_service_active() -> bool:
    """Run ``sudo systemctl is-active <TARGET_SERVICE>``."""
    cmd = ["/usr/bin/sudo", "-n", SYSTEMCTL, "is-active", config.TARGET_SERVICE]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5, check=False)
        return proc.returncode == 0 and proc.stdout.strip() == "active"
    except (subprocess.TimeoutExpired, OSError):
        return False


# Backwards-compatible aliases (older code expected the failover-specific names).
restart_failover_monitor = restart_target_service
is_failover_monitor_active = is_target_service_active
