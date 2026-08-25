"""Apply validated config updates to ``failover-overrides.conf``.

Pipeline (override design):

  1. flock ``CONFIG_LOCK`` — only one writer at a time.
  2. Read current ``OVERRIDE_CONFIG_PATH`` (missing file = bootstrap header).
  3. Replace each accepted ``KEY=value`` line in-place; append new keys.
  4. Write to the staging file (owned by failover-web).
  5. Invoke the root-owned validating installer (``INSTALL_HELPER``) — it
     re-validates EVERY line (whitelist keys, integers only) and atomically
     installs the override file.
  6. Restart ``TARGET_SERVICE``.
  7. Verify the daemon is active.

The base config (``CONFIG_PATH``) is never written by the web app. The
daemon sources base first, then the override file (bash last-wins). This is
also what makes the install helper's strict whitelist workable: the full
base config contains non-whitelisted keys (interfaces, test targets) that
would always fail its per-line validation — the override file by
construction only ever contains whitelisted integer tunables. Resetting a
value to the base default leaves an explicit override line behind —
harmless, remove manually if desired.
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
from typing import Any

from .. import config
from . import flock_path
from .service_controller import (
    is_failover_monitor_active,  # alias of is_target_service_active
    is_target_service_active,
    restart_failover_monitor,    # alias of restart_target_service
    restart_target_service,
)

__all__ = [
    "DuplicateKeyError",
    "apply_updates",
    "is_failover_monitor_active",
    "is_target_service_active",
    "restart_failover_monitor",
    "restart_target_service",
]

_logger = logging.getLogger("failover_web.config_writer")


class DuplicateKeyError(ValueError):
    """Raised when the source config has the same KEY= line more than once.

    Bash ``source`` uses last-wins, but a line-by-line patch only updates
    the first occurrence — refuse rather than silently write a value the
    daemon would overwrite at runtime.
    """


def _count_key_lines(text: str, key: str) -> int:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=", re.MULTILINE)
    return len(pattern.findall(text))


def _patch_text(text: str, accepted: dict[str, int]) -> tuple[str, list[str]]:
    """Return ``(patched_text, applied_keys)``. Preserves order and quoting.

    Refuses (raises ``DuplicateKeyError``) when a key appears more than
    once in the source.
    """
    if not accepted:
        return text, []

    duplicates = [k for k in accepted if _count_key_lines(text, k) > 1]
    if duplicates:
        raise DuplicateKeyError(
            f"refusing patch: duplicate KEY= lines for {sorted(duplicates)} — "
            "manual cleanup required"
        )

    applied: list[str] = []
    out_lines: list[str] = []
    seen: set[str] = set()
    line_re_template = (
        r"^(\s*)({key})(\s*)=(\s*)(?P<q>['\"]?)(?P<val>[^#\n'\"]*)(?P=q)(\s*)(#.*)?$"
    )
    for raw in text.splitlines(keepends=True):
        replaced = False
        for key, new_value in accepted.items():
            if key in seen:
                continue
            match = re.match(line_re_template.format(key=re.escape(key)), raw)
            if match:
                indent_pre = match.group(1)
                eq_left = match.group(3)
                eq_right = match.group(4)
                quote = match.group("q") or ""
                trail_ws = match.group(7) or ""
                comment = match.group(8) or ""
                comment_with_space = (
                    f" {comment}" if comment and not trail_ws.endswith(" ")
                    else (f"{trail_ws}{comment}" if comment else "")
                )
                out_lines.append(
                    f"{indent_pre}{key}{eq_left}={eq_right}{quote}{new_value}{quote}{comment_with_space}\n"
                )
                applied.append(key)
                seen.add(key)
                replaced = True
                break
        if not replaced:
            out_lines.append(raw)

    for key, value in accepted.items():
        if key not in seen:
            out_lines.append(f"{key}={value}\n")
            applied.append(key)

    return "".join(out_lines), applied


def apply_updates(accepted: dict[str, int]) -> dict[str, Any]:
    """Stage + install + restart. Returns a structured result dict."""

    if not accepted:
        return {"status": "noop", "applied": [], "detail": "No accepted updates"}

    with flock_path(config.CONFIG_LOCK):
        try:
            current = config.OVERRIDE_CONFIG_PATH.read_text(encoding="utf-8")
        except FileNotFoundError:
            # First override ever — start from an empty file with a header.
            current = (
                "# failover-overrides.conf — operator overrides via the web UI\n"
                "# Sourced by the daemon AFTER failover.conf (last-wins).\n"
                "# Integer tunables only; root-validated by install-failover-conf.\n"
            )
        except (PermissionError, OSError) as exc:
            return {
                "status": "error",
                "applied": [],
                "detail": f"cannot read {config.OVERRIDE_CONFIG_PATH}: {exc}",
            }

        try:
            patched, applied = _patch_text(current, accepted)
        except DuplicateKeyError as exc:
            return {"status": "error", "applied": [], "detail": str(exc)}
        if not applied:
            return {
                "status": "noop",
                "applied": [],
                "detail": "Updates produced no diff (values already current)",
            }
        if patched == current:
            return {
                "status": "noop",
                "applied": [],
                "detail": "Patched content identical to current",
            }

        # Write to staging (failover-web owned, mode 0640) — the helper below
        # re-reads as root and re-validates every line.
        config.STAGING_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        config.STAGING_CONFIG_PATH.write_text(patched, encoding="utf-8")
        os.chmod(config.STAGING_CONFIG_PATH, 0o640)

        # Invoke the root-owned validating installer. The helper takes NO
        # arguments — both source and destination are baked in to eliminate
        # path-injection. failover-web sudoers grants exactly this command.
        install_cmd = ["/usr/bin/sudo", "-n", config.INSTALL_HELPER]
        try:
            inst = subprocess.run(install_cmd, capture_output=True, text=True, timeout=10, check=False)
        except (subprocess.TimeoutExpired, OSError) as exc:
            return {
                "status": "error",
                "applied": [],
                "detail": f"install helper failed: {exc}",
            }
        if inst.returncode != 0:
            return {
                "status": "error",
                "applied": [],
                "detail": f"install helper returned {inst.returncode}: {inst.stderr.strip()[:500]}",
            }

        # Indirect via the module-global so tests can monkeypatch the alias
        # (the older name `restart_failover_monitor` is what existing tests
        # patch — both names resolve to the same callable).
        restart = restart_failover_monitor()
        if not restart["ok"]:
            return {
                "status": "installed_but_restart_failed",
                "applied": applied,
                "detail": restart.get("stderr", ""),
                "restart": restart,
            }

        return {
            "status": "applied",
            "applied": applied,
            "monitor_active": is_failover_monitor_active(),
        }
