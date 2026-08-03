# Prometheus metrics

`failover-metrics-collector` writes **three** Prometheus textfiles into the
node_exporter textfile directory (`/var/lib/node_exporter/textfile_collector/`
by default, `PROM_TEXTFILE_DIR` to change it). It also maintains a SQLite event
history for after-the-fact analysis.

| File | Written by | Contents |
|------|-----------|----------|
| `wan_quality.prom` | `test_wan_quality()` in `src/lib/network.sh` | Per-interface link quality |
| `failover_duration.prom` | failover-event detection | How long failovers took |
| `dns_performance.prom` | `measure_dns_detailed()` | Per-resolver DNS behaviour |

## Textfile metrics

### Failover events (`failover_duration.prom`)

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `failover_actual_duration_milliseconds` | gauge | `event_type` | Actual failover execution time, measured in Bash. |
| `failover_actual_duration_seconds` | gauge | `event_type` | Same value in seconds. |
| `failover_inter_event_seconds` | gauge | `event_type` | Time between consecutive failover events — low values mean flapping. |
| `failover_last_duration_seconds` | gauge | (none) | Last failover duration of any type. Legacy, kept for existing dashboards. |

### DNS performance (`dns_performance.prom`)

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `dns_success_rate_percent` | gauge | `interface` | Share of successful DNS queries. |
| `dns_failures_total` | counter | `interface`, `type` | Failures split by `timeout` and `servfail`. |
| `dns_quality_score` | gauge | `interface` | DNS-specific 0–100 score. |
| `dns_resolver_time_milliseconds` | gauge | `interface` | Resolution time per resolver. |

### WAN quality (`wan_quality.prom`)

Written from `test_wan_quality()` in `src/lib/network.sh`.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `wan_latency_milliseconds` | gauge | `interface`, `type` | Average RTT to the probe target. |
| `wan_packet_loss_percent` | gauge | `interface` | Packet loss to the probe target. |
| `wan_jitter_milliseconds` | gauge | `interface` | RTT standard deviation (`mdev`) to the probe target. |
| `wan_gateway_latency_milliseconds` | gauge | `interface` | RTT to the next LAN hop (the interface's gateway). |
| `wan_gateway_reachable` | gauge | `interface` | 1 if the gateway answers ICMP, 0 otherwise. |
| `wan_dns_time_milliseconds` | gauge | `interface` | DNS-over-HTTPS resolution time. 999 means timeout. |
| `wan_http_time_milliseconds` | gauge | `interface` | HTTP connectivity-check time. 999 means failure. |
| `wan_quality_score` | gauge | `interface` | Weighted 0–100 composite: latency 25 %, packet loss 25 %, DNS 20 %, jitter 15 %, HTTP 15 %. The gateway metrics are reported alongside but do **not** feed this score. |

**Probe target vs. gateway.** The first three metrics measure the *internet*
path — the first `CHECK_IPS` entry that answers. The gateway is measured
separately because the two answer different questions: a dead gateway means the
modem or router is gone, while a healthy gateway paired with bad path metrics
means the uplink itself is degraded.

This distinction matters most on the backup interface. Measuring latency against
the gateway means measuring a LAN cable — it reports roughly 1 ms and 0 % loss
regardless of the uplink's true state, so an idle backup link scores high right
up to the moment it is promoted to active WAN. Set
`WAN_QUALITY_TARGET_MODE=gateway` to restore the old behaviour; expect a step
change in historical series when switching either way.

## Recording rules and alerts

Suggested Prometheus alert rules (open a PR to add them under `examples/prometheus/`):

```yaml
groups:
- name: linux-dual-wan-failover
  rules:
  - alert: FailoverFlapping
    # Short gaps between consecutive failovers are the flapping signature.
    expr: failover_inter_event_seconds < 900
    for: 1m
    annotations:
      summary: "Failovers less than 15min apart — link is flapping"

  - alert: BothLinksDegraded
    expr: max(wan_quality_score) < 50
    for: 2m
    annotations:
      summary: "No WAN interface scores above 50"

  - alert: UplinkDegradedButGatewayFine
    # The case the gateway probe alone cannot see: LAN hop healthy, path bad.
    expr: wan_gateway_reachable == 1 and wan_dns_time_milliseconds > 800
    for: 5m
    annotations:
      summary: "{{ $labels.interface }}: gateway reachable but DNS above 800ms"

  - alert: WanQualityStale
    expr: time() - timestamp(wan_quality_score) > 300
    for: 5m
    annotations:
      summary: "wan_quality.prom has not been updated for 5min"
```

> These reference the metric names the collector actually emits. Until v0.7.0
> this section listed a `linux_dual_wan_failover_*` namespace that was never
> implemented — those rules could not have fired.

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
