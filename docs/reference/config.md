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
| Health checks | `CHECK_IPS`, `DNS_SERVERS`, `DNS_TEST_DOMAINS` | no (sane defaults) |
| Timing | `CHECK_INTERVAL`, `ROUTE_GUARDIAN_CHECK_INTERVAL` | no (sane defaults) |
| Hysteresis | `FAILOVER_THRESHOLD_DOWN`, `FAILURE_THRESHOLD`, `RECOVERY_THRESHOLD`, `EMERGENCY_THRESHOLD` | no (sane defaults) |
| Cooldowns | `ANTI_FLAPPING_DELAY`, `EMERGENCY_FAILBACK_COOLDOWN` | no (sane defaults) |
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
