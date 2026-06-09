# State file ownership

Every state file has exactly one writer and any number of readers. This is
non-negotiable.

## Why single-writer

Both alternatives have been tried and rejected:

- **Multiple writers, no locking.** Two services try to update
  `connection_metrics.json` at the same time → torn read on the metrics
  collector → SQLite error → metrics gap.
- **Multiple writers, with locking.** All readers stall behind writers;
  the route-guardian's "is the lockfile fresh" check itself blocks while
  some other writer holds the lock. Cascading-stall failure mode.

Single-writer plus atomic-write (`mktemp` + `rename`) is the simplest
discipline that doesn't require any locking on the read side.

## Ownership table

| File | Writer | Readers |
|------|--------|---------|
| `/run/linux-dual-wan-failover/failover-monitor.pid` | `failover-monitor` (on startup) | `nmcli-failover-monitor`, operators |
| `/run/linux-dual-wan-failover/failover-in-progress.lock` | `nmcli-failover-monitor` (only on emergency failover) | `route-guardian` (skips while present) |
| `/run/linux-dual-wan-failover/wan-state/active_wan` | `failover-monitor` (after each route change) | `route-guardian`, `failover-metrics-collector` |
| `/run/linux-dual-wan-failover/wan-state/connection_metrics` | `failover-monitor` (every 5 s) | `failover-metrics-collector` |
| `/var/lib/linux-dual-wan-failover/quota-snapshot.json` | quota-provider plugin | `failover-monitor` |
| `/var/lib/linux-dual-wan-failover/route-guardian/state.json` | `route-guardian` | route-guardian (only) |
| `/var/lib/linux-dual-wan-failover/metrics/failover-events.db` | `failover-metrics-collector` | metrics-collector (only) |

## Atomic-write pattern

Bash:

```bash
sfu_write_file "$content" "$target_path" "$mode"
# is approximately:
#   tmp="$(mktemp "${target}.XXXXXX")"
#   printf '%s' "$content" > "$tmp"
#   install -m "$mode" "$tmp" "$target"
#   rm -f "$tmp"
```

Python:

```python
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(snapshot))
tmp.replace(path)
```

Both produce a single atomic `rename(2)`, so a reader either sees the
old file or the new file, never a partial write. As long as readers
re-open between calls (don't `tail -f` your way around the abstraction),
they get a consistent snapshot.

## What about `flock`?

The lockfile (`failover-in-progress.lock`) is a _coordination_ primitive,
not an exclusion lock. Its presence means "the route table is being
modified emergency-style; please don't second-guess the routes for the
next 30 seconds, route-guardian." Removing it is the _signal_ that the
emergency window is over.

`flock` is not used here because there is no need to serialize writes — there
is only ever one writer per file. The lockfile is signalling, not locking.

The PID-and-timestamp format (`PID_TIMESTAMP`) is so a stale lockfile
(parent process crashed before cleanup) can be detected and cleaned up
by a sibling — see `route-guardian` for the cleanup logic.
