# How-to: trace one failover end-to-end (Correlation-ID)

A failover crosses four services — `nmcli-failover-monitor` (detection) →
`failover-monitor` (orchestration) → `routing.sh` (route change) →
`route-guardian` (protection) — plus the metrics collector. Each event carries a
single **Event-ID** (Correlation-ID, `PID_TIMESTAMP`) so you can reconstruct one
failover across all of them instead of correlating per-service logs by timestamp.

## TL;DR

```bash
# List recent failover events with their Event-IDs.
src/tools/trace-failover.sh --list 10

# Full trace of one failover: the DB row (symptom) plus a time-merged
# service-log waterfall (cause).
src/tools/trace-failover.sh <PID_TIMESTAMP>
src/tools/trace-failover.sh --last        # the most recent failover
```

(Installed system-wide, the tool lives at
`/usr/local/lib/linux-dual-wan-failover/tools/trace-failover.sh`.)

## What the Event-ID ties together

| Question | Signal | Where |
|----------|--------|-------|
| Is something wrong? | metric / event | `failover_events` SQLite row |
| Where / what? | the active-interface change | same row (`from`/`to`) |
| Why? | the service logs | the journal of each unit, or `/var/log/linux-dual-wan-failover/*.log` |

The ID is minted by `nmcli-failover-monitor` at detection (or by
`failover-monitor` for health-check / failback / manual failovers), propagated
through `pending_failover_id` and the lockfile, stamped into every structured log
line as `FAILOVER_EVENT_ID=<id>`, and written to the `event_id` column of the
events database.

## Where the log lines come from

The Event-ID is part of the message text, not a separate journal field, so it is
found with a text search. For each service the tool searches the journal first,
selected by the unit's `SyslogIdentifier` (`nmcli-failover-monitor`,
`failover-monitor`, `route-guardian`), and falls back to the service's log file
when the journal has no hit. The `Sources:` line of the output says which one
each lane came from.

| Logger | Journal | Log files |
|--------|---------|-----------|
| [bash-production-toolkit](https://github.com/fidpa/bash-production-toolkit) v3.x | every line, with its priority | with `LOG_TO_FILE=true`, the project default |
| bash-production-toolkit v2.x | `failover-monitor` only (the other two run with `LOG_TO_STDOUT=false`) | always |
| no toolkit (`common.sh` fallback logger) | every line, at priority info | none |

Reading the system journal needs root or membership in the `adm` or
`systemd-journal` group; without it the tool silently uses the files only.

## Manual (without the tool)

```bash
ID=3741608_1782676271

# Journal: one service at a time (the ID is in the message text).
sudo journalctl -t failover-monitor --grep "FAILOVER_EVENT_ID=$ID"

# Files: chronological across the three service logs.
grep -hE "FAILOVER_EVENT_ID=$ID([^0-9]|\$)" \
    /var/log/linux-dual-wan-failover/{nmcli-monitor,failover,route-guardian}.log \
    | sort

# The matching event-DB row.
sqlite3 "file:/var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db?mode=ro" \
    "SELECT * FROM failover_events WHERE event_id = '$ID';"
```

## Overriding paths

The tool reads device-agnostic defaults that can be overridden via environment
variables (useful for tests or non-standard installs):

```bash
LOG_DIR=/var/log/linux-dual-wan-failover \
STATE_DIR=/run/linux-dual-wan-failover/wan-state \
EVENTS_DB=/var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db \
    src/tools/trace-failover.sh <id>
```

## Known limits

- **Pre-feature events** (recorded before this release) have `event_id = NULL`;
  the log trace only works while the logs have not rotated.
- **5 s sampling**: two failovers inside one collector poll can share the same
  `last_failover_id` in the database (accepted sampling trade-off).
- **Retention** bounds how far back the trace reaches: journald's limits for the
  journal, `/etc/logrotate.d/linux-dual-wan-failover` for the files (weekly,
  eight generations, compressed).
- **Up to v0.11.0 `nmcli-failover-monitor` wrote `failover.log`**, not
  `nmcli-monitor.log`. In the journal those older lines are attributed
  correctly; from the files they appear in the `[monitor]` lane.

## See also

- [how-to/debug-failover.md](debug-failover.md) — broader failover debugging runbook
- [explanation/state-file-ownership.md](../explanation/state-file-ownership.md) — the lockfile and `/run` state files
- [reference/architecture-overview.md](../reference/architecture-overview.md) — the four-service architecture
