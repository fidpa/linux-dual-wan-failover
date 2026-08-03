# Configuration reference

The complete list of variables understood by `failover-monitor`,
`nmcli-failover-monitor`, and `route-guardian` is in
[`config/failover.conf.example`](../../config/failover.conf.example), with
inline comments. That file is the source of truth — this page is a
high-level index.

## Variables by section

| Section | Variables | Required |
|---------|-----------|----------|
| Interfaces | `PRIMARY_IFACE`, `BACKUP_IFACE`, `PRIMARY_NM_CONNECTION`, `BACKUP_NM_CONNECTION` | yes (no working defaults) |
| Optional interfaces | `LAN_INTERFACE`, `MGMT_INTERFACE` | no (empty = disabled) |
| Routing metrics | `PRIMARY_METRIC_NORMAL`, `PRIMARY_METRIC_DEMOTED`, `BACKUP_METRIC` | no (sane defaults) |
| Gateways | `PRIMARY_GATEWAY`, `BACKUP_GATEWAY` | no (auto-detected) |
| Health checks | `CHECK_IPS`, `DNS_SERVERS`, `DNS_TEST_DOMAINS`, `DNS_TEST_METHOD` | no (sane defaults; `DNS_TEST_METHOD=doh` — leave it there, see note below) |
| WAN quality probe | `WAN_QUALITY_TARGET_MODE`, `WAN_QUALITY_PROBE_SAMPLES`, `WAN_QUALITY_PROM_MAX_AGE` | no (default: `internet`, 10 samples, 300 s) |
| Timing | `CHECK_INTERVAL`, `ROUTE_GUARDIAN_CHECK_INTERVAL` | no (sane defaults) |
| Hysteresis | `FAILOVER_THRESHOLD_DOWN`, `FAILURE_THRESHOLD`, `RECOVERY_THRESHOLD`, `EMERGENCY_THRESHOLD` | no (sane defaults) |
| Cooldowns | `ANTI_FLAPPING_DELAY`, `EMERGENCY_FAILBACK_COOLDOWN` | no (sane defaults) |
| Emergency failback | `EMERGENCY_FAILBACK_MIN_BACKUP_TIME`, `EMERGENCY_FAILBACK_DEGRADED_CHECKS`, `EMERGENCY_FAILBACK_DNS_THRESHOLD_MS` | no — but read the note below before lowering any of them |
| Failback gating | `MIN_FAILBACK_SCORE`, `MIN_BACKUP_TIME`, `MIN_STABLE_DURATION`, `STABILITY_RESET_THRESHOLD` | no (sane defaults) |
| Last-resort | `LAST_RESORT_ENABLED`, `LAST_RESORT_PRIMARY_THRESHOLD`, `LAST_RESORT_COOLDOWN` | no (disabled by default) |
| Latency / loss | `DSL_LATENCY_*`, `LTE_LATENCY_*`, `PACKET_LOSS_*` | no (sane defaults) |
| Alerting plugin | `ALERTING_BACKEND`, `ALERTING_PLUGIN_DIR`, `ALERTING_PLUGIN_PATH` | no (default: `none`) |
| Quota plugin | `QUOTA_PROVIDER`, `QUOTA_SNAPSHOT_PATH`, `QUOTA_SNAPSHOT_MAX_STALE_SEC`, `QUOTA_CAP_TIER_*` | no (default: `none`) |
| Hardware | `HARDWARE_TEMP_BACKEND` | no (default: `none`) |
| Directories | `LOG_DIR`, `STATE_DIR`, `RUNTIME_DIR` | no (systemd units set them) |
| Toolkit | `TOOLKIT_LIB` | no (auto-detected) |

## Top 10 variables to know

Most operators only ever touch these. Everything else has working defaults for the
"DSL primary, LTE backup" case.

| Variable | Default | Effect |
|---|---|---|
| `PRIMARY_IFACE` | **(required)** | Your primary WAN interface (e.g. `eth0`). No default — startup fails without it. |
| `BACKUP_IFACE` | **(required)** | Your backup WAN interface (e.g. `lte0`). No default — startup fails without it. |
| `PRIMARY_NM_CONNECTION` | **(required)** | NetworkManager connection name for the primary (`nmcli connection show`). |
| `BACKUP_NM_CONNECTION` | **(required)** | NetworkManager connection name for the backup. |
| `PRIMARY_METRIC_NORMAL` | `50` | Routing metric when primary is active. Lower = preferred. |
| `PRIMARY_METRIC_DEMOTED` | `500` | Routing metric during failover. Higher than `BACKUP_METRIC` so backup route wins. |
| `BACKUP_METRIC` | `200` | Routing metric for the backup interface. Always between normal and demoted. |
| `CHECK_INTERVAL` | `15` (s) | How often the orchestrator scores both interfaces. Shorter = faster detection; longer = more resilient to transients. |
| `FAILURE_THRESHOLD` | `5` | Consecutive bad-score rounds before failover. At 15 s intervals: 75 s of degradation before action. |
| `RECOVERY_THRESHOLD` | `20` | Consecutive good-score rounds before failback. At 15 s intervals: 5 minutes of stability required. |

For alerting and quota, set `ALERTING_BACKEND` and `QUOTA_PROVIDER` — see their
respective how-to guides.

## Note on `DNS_TEST_METHOD`

`doh` (the default since v0.1.1) runs the DNS probe as DNS-over-HTTPS through
`curl --interface`, which is a real `SO_BINDTODEVICE` binding. The `dig` setting
is a rollback path only: `dig -b` sets the *source address* but cannot force the
outgoing interface, so on a demoted primary the packets leave via the active
backup carrying the primary's source IP, the answer never comes back, and a
perfectly healthy primary reports a 999 ms timeout — which blocks failback. Do
not switch to `dig` to "fix" a DNS score.

## Note on `WAN_QUALITY_TARGET_MODE`

Leave this at `internet` unless you are debugging. The `gateway` setting exists
only as a rollback switch to the historical behaviour, where latency, loss and
jitter were measured against the interface's own gateway.

That measurement is misleading on purpose-built dual-WAN boxes: the gateway is
one LAN hop away, so it answers in about a millisecond with zero loss whatever
the uplink is doing. The backup interface is hit hardest — it looks healthy for
as long as it sits idle, and the true state only surfaces after a failover has
already happened. The gateway is still probed and exported separately as
`wan_gateway_latency_milliseconds` / `wan_gateway_reachable`, so nothing is lost
by measuring the real path.

Switching modes produces a step change in any historical Prometheus series for
`wan_latency_milliseconds`, `wan_packet_loss_percent` and
`wan_jitter_milliseconds`. Annotate the switchover in your dashboards.

## Note on the emergency-failback variables

`EMERGENCY_FAILBACK_*` controls the escape hatch for "the backup is up but
end-to-end unusable". It bypasses `MIN_BACKUP_TIME` and
`MIN_STABLE_DURATION`, which makes it the one group where loosening a
default changes behaviour the most.

Two things are easy to get wrong:

- **`EMERGENCY_FAILBACK_MIN_BACKUP_TIME` is the real trigger rate.** If the
  degradation signal is present continuously — which it is whenever the
  backup is genuinely narrow rather than broken — the escape hatch fires
  the moment this timer expires, every time. Set too low against a
  *flapping primary*, it stops being an escape hatch and becomes the normal
  failback path, returning traffic to a link that is still broken. Raise
  this before lowering `EMERGENCY_FAILBACK_DNS_THRESHOLD_MS`.
- **`EMERGENCY_FAILBACK_DEGRADED_CHECKS` is not "N × `CHECK_INTERVAL` of
  evidence".** The counter ticks once per orchestrator round, but the DNS
  value it reads comes from `failover-metrics-collector`, which refreshes on
  its own and slower cycle. Measure your collector's actual cadence:

  ```bash
  sqlite3 /var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db \
    "SELECT ROUND(AVG(d),1) FROM (SELECT (julianday(timestamp) -
     julianday(LAG(timestamp) OVER (ORDER BY id))) * 86400 AS d
     FROM wan_quality_metrics WHERE interface = 'lte0');"
  ```

  If that prints ~50 and `CHECK_INTERVAL` is 15, then 20 checks (300 s) are
  roughly 6 independent samples — and the pre-0.6.0 default of 6 checks was
  fewer than two, with the same value counted up to four times.

A slow backup is not a dead backup. Before lowering the DNS threshold,
check whether the uplink is merely saturated: DNS-over-HTTPS needs a TLS
handshake (~3 RTT of small upstream packets), so a narrow *uplink* inflates
DNS timing long before the link stops carrying traffic. Comparing DNS timing
under downlink-saturation versus uplink-saturation separates the two cases.

## Reading order for a new operator

1. Start with the **Interfaces** section — these are the only required
   variables.
2. **Routing metrics** if your existing setup already uses non-default
   metrics; otherwise skip.
3. **Plugins (alerting, quota)** if you want either.
4. **Hysteresis** only when you've seen real-world data and want to
   tune the failover behaviour. The defaults are good for the
   "DSL primary, LTE backup" case.

## Validation

The orchestrator validates required variables on startup and refuses
to run if `PRIMARY_IFACE` or `BACKUP_IFACE` are unset. Most other
validation is done lazily — typos in `CHECK_IPS` show up as DNS or ping
failures during scoring, not as configuration errors.

For a runtime check:

```bash
sudo systemctl restart failover-monitor.service
journalctl -u failover-monitor -n 50 | grep -E '(FATAL|ERROR|loaded)'
```
