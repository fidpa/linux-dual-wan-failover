# Prometheus metrics

`failover-metrics-collector` writes a Prometheus textfile to
`/var/lib/node_exporter/textfile_collector/linux-dual-wan-failover.prom`
(or wherever you configure it). It also maintains a SQLite event history
for after-the-fact analysis.

## Textfile metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `linux_dual_wan_failover_score` | gauge | `interface` | Current 0–100 score per interface. |
| `linux_dual_wan_failover_active` | gauge | `interface` | 1 if the interface is the active default route, 0 otherwise. |
| `linux_dual_wan_failover_failover_total` | counter | `from`, `to`, `reason` | Total failovers since start. `reason` is one of `score`, `event`, `emergency`, `last-resort`. |
| `linux_dual_wan_failover_failback_total` | counter | `from`, `to` | Total failbacks. |
| `linux_dual_wan_failover_quota_limit_pct` | gauge | (none) | Latest reported quota usage (0–100, or NaN if no provider). |
| `linux_dual_wan_failover_route_cleanup_total` | counter | `interface` | Duplicate routes the guardian deleted. |
| `linux_dual_wan_failover_lockfile_stale_total` | counter | (none) | Stale lockfiles cleaned up. |

## Recording rules and alerts

Suggested Prometheus alert rules (open a PR to add them under `examples/prometheus/`):

```yaml
groups:
- name: linux-dual-wan-failover
  rules:
  - alert: FailoverFlapping
    expr: rate(linux_dual_wan_failover_failover_total[15m]) > 4
    for: 1m
    annotations:
      summary: "Failover stack is flapping (>4 failovers in 15min)"

  - alert: BackupLinkQuotaCritical
    expr: linux_dual_wan_failover_quota_limit_pct >= 96
    for: 5m
    annotations:
      summary: "Backup-link quota at {{ $value }}% — failover effectively blocked"

  - alert: BothLinksDegraded
    expr: linux_dual_wan_failover_score < 50 unless on() linux_dual_wan_failover_score >= 60
    for: 2m
    annotations:
      summary: "Both WAN interfaces scoring below 50"
```

## SQLite event log

```bash
sqlite3 /var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db <<'SQL'
.headers on
.mode column
SELECT
    datetime(timestamp) AS at,
    event_type,
    from_interface,
    to_interface,
    primary_score_before,
    backup_score_before,
    reason,
    event_id
FROM failover_events
ORDER BY timestamp DESC
LIMIT 20;
SQL
```

`timestamp` is stored as a local datetime string (not a Unix epoch), so it is
read back directly. `event_id` is the failover Correlation-ID — see
[../how-to/trace-failover.md](../how-to/trace-failover.md).

The schema is intentionally simple — one row per failover/failback,
one row per anomaly (lockfile stale, score-cap-applied, etc.).
