# Why two services for one job

`failover-monitor` and `nmcli-failover-monitor` look like they could be
one service. They were a single service once. They were split. Here's why.

## The combined version

```
loop forever:
    block on either:
        - nmcli monitor event (fast path)
        - 15-second timer    (slow path)
    if event:
        confirm link state, fail over immediately
    if timer:
        score both interfaces, decide whether to fail over
```

This works. It's fewer moving parts, fewer systemd units, fewer logs.

## What killed it

Three production realities ate the combined design:

### 1. Restart cost

`failover-monitor`'s scoring loop holds a non-trivial amount of in-memory
state: cache of recent latency/loss values, anti-flap counters, hysteresis
windows, lockfile ownership. Restarting it means losing that state and
re-priming the cache (~30 s of degraded-quality scoring as fresh data
flows in).

But the **event-detection** code is the part most likely to need updating
— NM's output format changes occasionally, edge cases keep emerging
(suspend/resume races, dhcp-during-failover handling, etc.).

If the event detection lives in the same process as the orchestrator,
every NM-parsing tweak forces an orchestrator restart, and you lose all
that scoring state for what should have been a parser bug-fix.

### 2. Crash blast radius

The orchestrator runs with `CAP_NET_ADMIN` (it has to — `ip route`).
The event detector parses untrusted input from `nmcli monitor`. Even
with `set -uo pipefail` and careful field-extraction, a malformed event
that crashes the parser would crash the privileged orchestrator if they
were the same process.

Splitting them means a parser crash takes down only the fast path; the
polling path still keeps the link healthy. The orchestrator continues
running with its scoring loop intact.

### 3. Different lifecycle requirements

The event detector wants `Restart=always` (events are continuous; downtime
between restarts means missed events).

The orchestrator wants `Restart=always` *with* `RestartSec=10s` (so a
config bug doesn't burn CPU restarting in a tight loop, since most
restart causes are config errors that won't fix themselves).

The metrics collector wants `Restart=on-failure` (it's read-only, no
need to restart on graceful shutdown).

`systemd` is great at managing different restart policies for different
units. Asking one service to embody three policies is fighting the
init system.

## What the split costs

- **Three units to enable** instead of one. Acceptable: `systemctl enable
  --now ...` takes the same wall-clock time for one or three.
- **Three logs to grep** instead of one. Acceptable: `journalctl -u
  failover-monitor -u nmcli-failover-monitor -u route-guardian` is one
  command.
- **Inter-process communication** (PID file + SIGUSR1) where the combined
  version had a function call. The IPC is small (one signal, one file
  read) and the SIGUSR1 contract is stable across versions.

The split has paid for itself many times over in incident review. If
you want a single-binary deployment, fork and merge — but expect to
re-encounter the issues above.
