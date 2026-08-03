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
| `/run/failover-in-progress.lock` | `routing.sh::safe_route_change` (every route change) + `nmcli-failover-monitor` (emergency path) | `route-guardian` (skips its whole check cycle while present) |
| `/run/linux-dual-wan-failover/wan-state/active_wan` | `failover-monitor` (after each route change) | `route-guardian`, `failover-metrics-collector` |
| `/run/linux-dual-wan-failover/wan-state/connection_metrics` | `failover-monitor` (every 5 s) | `failover-metrics-collector` |
| `/run/linux-dual-wan-failover/wan-state/pending_failover_id` | `nmcli-failover-monitor` (before USR1) | `failover-monitor` (consumes it) |
| `/run/linux-dual-wan-failover/wan-state/last_failover_id` | `routing.sh` / `nmcli-failover-monitor` (== lockfile ID) | `failover-metrics-collector` |
| `/run/linux-dual-wan-failover/wan-state/last_failover` | `failover-monitor` (after each route change) | `failover-web` (anti-flapping pre-check) |
| `/run/linux-dual-wan-failover/wan-state/last_failover_to_backup` | `failover-monitor` (on failover to backup; reseeded at startup if missing while on backup) | `failover-monitor` (`MIN_BACKUP_TIME`, emergency-failback gate, prolonged-backup alert) |
| `/var/lib/linux-dual-wan-failover/quota-snapshot.json` | quota-provider plugin | `failover-monitor` |
| `/var/lib/linux-dual-wan-failover/route-guardian/state.json` | `route-guardian` | route-guardian (only) |
| `/var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db` | `failover-metrics-collector` | metrics-collector (only) |

## These files do not survive a service restart

`RuntimeDirectory=` in the systemd units has no `RuntimeDirectoryPreserve=`,
so systemd removes `/run/linux-dual-wan-failover/` — including all of
`wan-state/` — every time a service stops. That is deliberate (no stale
state after a crash), but it makes one class of bug easy to write:

> The failover lockfile is the one exception: it lives at `/run` root, not
> inside the `RuntimeDirectory=` tree, precisely so it is shared between four
> services with different runtime directories. It therefore survives a restart
> and has to be aged out explicitly — which is what the `PID_TIMESTAMP` format
> and `route-guardian`'s staleness check are for.

> A reader that defaults a missing timestamp to `0` does not get
> "no information". It gets **1 January 1970**, and every
> `now - timestamp >= threshold` check it feeds passes immediately.

That is how `MIN_BACKUP_TIME` and the emergency-failback minimum silently
stopped applying after any restart while on backup, and how the
prolonged-backup alert came to announce ~496 000 hours on the backup link.
Two rules follow:

1. **A missing timestamp is a distinct case**, not a small number. Either
   refuse to act (the emergency path does this) or re-establish a defensible
   value (`failover-monitor` reseeds `last_failover_to_backup` with the
   restart instant when it comes up on backup — the window restarts rather
   than vanishing).
2. **In-memory counters are wiped at the same moment.** `last_failover_mono`
   resets to `0` on every daemon start, so any "time since last failover"
   arithmetic needs the same explicit "never happened" branch — see
   [anti-flapping.md](anti-flapping.md).

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
modified; please don't second-guess the routes for the next 30 seconds,
route-guardian." Removing it is the _signal_ that the window is over.

Until v0.4.0 only the nmcli emergency path wrote it, so regular score-based
and manual failovers ran without pausing the guardian — which could revert a
fresh metric swap in the window before `active_wan` is persisted. Every route
change writes it now.

`flock` is not used here because there is no need to serialize writes — there
is only ever one writer per file. The lockfile is signalling, not locking.

The PID-and-timestamp format (`PID_TIMESTAMP`) is so a stale lockfile
(parent process crashed before cleanup) can be detected and cleaned up
by a sibling — see `route-guardian` for the cleanup logic.
