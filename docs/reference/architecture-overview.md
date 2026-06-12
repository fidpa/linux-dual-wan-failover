# Architecture overview

`linux-dual-wan-failover` is **four cooperating systemd services**.
There is a reason it isn't one.

## The four services

| Service | Role | Frequency |
|---------|------|-----------|
| `failover-monitor` | Orchestrator: scoring, decision, route switch | Every CHECK_INTERVAL (15 s default) |
| `nmcli-failover-monitor` | Event detection: signals orchestrator on NM state changes | Sub-second on event |
| `route-guardian` | Route enforcement: cleans duplicates, ensures correct metrics | Every ROUTE_GUARDIAN_CHECK_INTERVAL (10 s default) |
| `failover-metrics-collector` | Observability: Prometheus textfile + SQLite event log | Every 5 s |

## Data flow

```
                 ┌───────────────────────────┐
   nmcli         │ nmcli-failover-monitor    │
   monitor   ───▶│ (event detection)         │
                 │                           │
                 │ writes lockfile           │
                 │ kills -USR1 orchestrator  │
                 └─────────────┬─────────────┘
                               │ SIGUSR1
                               ▼
                 ┌───────────────────────────┐
   periodic   ───▶│ failover-monitor          │◀─── reads failover.conf
                 │ (orchestrator)            │
                 │                           │
                 │ scores both interfaces    │
                 │ applies anti-flap rules   │
                 │ switches default route    │
                 │ writes active_wan         │─────────┐
                 └─────────────┬─────────────┘         │
                               │ writes JSON           │ writes active_wan
                               ▼                       ▼
                 ┌───────────────────────────┐ ┌─────────────────────┐
                 │ failover-metrics-collector│ │ route-guardian      │
                 │ (read-only)               │ │ (route enforcement) │
                 │                           │ │                     │
                 │ Prometheus textfile +     │ │ deletes duplicates  │
                 │ SQLite event log          │ │ enforces metric     │
                 └───────────────────────────┘ │ matches active_wan  │
                                               └─────────────────────┘
```

## Coordination primitives

| Primitive | Path | Format | Owner | Reader |
|-----------|------|--------|-------|--------|
| Orchestrator PID | `/run/linux-dual-wan-failover/failover-monitor.pid` | int | failover-monitor | nmcli-failover-monitor |
| Failover lock | `/run/failover-in-progress.lock` | `<PID>_<TIMESTAMP>` | routing.sh `safe_route_change` (every failover/failback) + nmcli-failover-monitor (emergency path) | route-guardian (skips its whole check cycle while present) |
| Active WAN | `/run/linux-dual-wan-failover/wan-state/active_wan` | `eth0` or `lte0` | failover-monitor | route-guardian, metrics-collector |
| Score snapshot | `/run/linux-dual-wan-failover/wan-state/connection_metrics` | JSON | failover-monitor | metrics-collector |
| Quota snapshot | `/var/lib/linux-dual-wan-failover/quota-snapshot.json` | JSON (schema in `plugins/quota-providers/_schema/`) | quota provider | failover-monitor |

The lockfile uses `PID_TIMESTAMP` rather than a bare touch-file because of
a real-world incident where a crashed nmcli-failover-monitor left a stale
lockfile, paused the route-guardian indefinitely, and was only caught
after operators noticed routes weren't being cleaned up. Now route-guardian
verifies the PID is alive and the timestamp is fresh; if not, it removes
the lockfile and (optionally) alerts.

## Why separate detection and orchestration?

See [`../explanation/why-dual-service.md`](../explanation/why-dual-service.md)
for the full argument. Short version:

- **Single polling service** = reliable but slow (15-30 s reaction).
- **Single event service** = fast but brittle (NM doesn't always emit
  the events you'd expect — link bouncing, dhcp races, suspended state).
- **Both** = sub-5-second reaction in the common case, polling fallback
  for the cases the events don't cover.

## Why a separate route-guardian?

NetworkManager has its own ideas about what routes should exist. After
each DHCP renewal, address change, or ipv4 plugin re-evaluation, NM may
add a default route on the interface — including, helpfully, on the
interface that the orchestrator just demoted. The route-guardian undoes
those changes within a second.

The guardian also handles the **failback dangerous case** (which is more
dangerous than failover; see
[`../explanation/anti-flapping.md`](../explanation/anti-flapping.md)).
When LTE is being demoted back to backup, there's a moment where the
default route might briefly disappear; the guardian's `emergency_restore_any_route`
fallback ensures the system doesn't end up with zero default routes.

## Why a separate metrics collector (in Python)?

The orchestrator must run with `CAP_NET_ADMIN`. The metrics collector
just reads files and writes Prometheus textfile output — it has no need
for `CAP_NET_ADMIN`, so the metrics collector drops it (`CapabilityBoundingSet=`,
`AmbientCapabilities=`). It also runs under `DynamicUser=yes`. Splitting
the observability surface from the privileged orchestrator is a defence-in-depth
move that costs nothing in coupling (the JSON snapshot is the only
contract).
