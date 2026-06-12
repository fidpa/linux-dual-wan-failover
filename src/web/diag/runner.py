"""On-demand diagnostic tool runner (ping/dig/traceroute/mtr) with SSE streaming.

The interface whitelist is taken from ``config.DIAG_INTERFACES`` — by
default this resolves to ``(PRIMARY_IFACE, BACKUP_IFACE)`` so the operator
can scope a probe to a specific uplink without leaking arbitrary kernel
interfaces.
"""

from __future__ import annotations

import re
import shlex
import subprocess
import time
from collections.abc import Iterator
from typing import IO, cast

from .. import config

# Hostname / IP regex — covers IPv4 dotted, IPv6 colons, and DNS hostnames.
# Deliberately strict: rejects shell metacharacters.
_TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-:]{0,253}$")


def build_command(tool: str, *, target: str, iface: str | None, count: int) -> list[str]:
    """Construct the argv for the chosen diag tool. Raises ValueError on input violations."""
    if tool not in config.DIAG_TOOLS:
        raise ValueError(f"unknown tool: {tool!r}")
    if not _TARGET_RE.fullmatch(target or ""):
        raise ValueError(f"target rejected: {target!r}")
    if iface is not None and iface not in config.DIAG_INTERFACES:
        raise ValueError(f"interface rejected: {iface!r}")
    if not (1 <= int(count) <= 10):
        raise ValueError(f"count out of range [1,10]: {count}")

    binary = config.DIAG_TOOLS[tool]
    if tool == "ping":
        argv = [binary, "-c", str(count), "-W", "2"]
        if iface:
            argv += ["-I", iface]
        argv.append(target)
    elif tool == "dig":
        argv = [binary, "+time=2", "+tries=1", target]
    elif tool == "traceroute":
        argv = [binary, "-w", "2", "-q", "1"]
        if iface:
            argv += ["-i", iface]
        argv.append(target)
    elif tool == "mtr":
        argv = [binary, "-r", "-c", str(count)]
        if iface:
            argv += ["-I", iface]
        argv.append(target)
    else:
        raise ValueError(f"tool not implemented: {tool!r}")
    return argv


def stream_command(argv: list[str]) -> Iterator[str]:
    """Stream the command's combined stdout+stderr as SSE-encoded lines.

    Yields complete SSE messages (``data: ...\\n\\n``). Terminates with
    ``event: end`` carrying the exit code, or ``event: error`` on timeout.
    """
    yield f"event: start\ndata: {shlex.join(argv)}\n\n"
    try:
        proc_cm = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,  # line-buffered
        )
    except (OSError, ValueError) as exc:
        yield f"event: error\ndata: spawn failed: {exc}\n\n"
        return

    bytes_yielded = 0
    truncated = False
    # The deadline covers the WHOLE run. Previously the timeout only applied
    # to proc.wait() AFTER the read loop — a slowly-dripping traceroute could
    # stream for 60-90s despite DIAG_TIMEOUT_SECONDS=30.
    deadline = time.monotonic() + config.DIAG_TIMEOUT_SECONDS
    timed_out = False
    with proc_cm as proc:
        stdout = cast(IO[str], proc.stdout)
        try:
            for line in stdout:
                if time.monotonic() > deadline:
                    timed_out = True
                    break
                chunk = line.rstrip("\n")
                if bytes_yielded + len(chunk) > config.DIAG_MAX_OUTPUT_BYTES:
                    truncated = True
                    break
                bytes_yielded += len(chunk)
                yield f"data: {chunk}\n\n"
            if timed_out:
                proc.kill()
                proc.wait()
                yield f"event: error\ndata: timeout after {config.DIAG_TIMEOUT_SECONDS}s\n\n"
                return
            proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            yield f"event: error\ndata: timeout after {config.DIAG_TIMEOUT_SECONDS}s\n\n"
            return
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

    if truncated:
        yield f"event: truncated\ndata: output exceeded {config.DIAG_MAX_OUTPUT_BYTES} bytes\n\n"
    yield f"event: end\ndata: {proc.returncode}\n\n"
