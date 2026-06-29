# How-to: debug a failover (or a failover that didn't happen)

> To reconstruct **one specific** failover across all four services by its
> Correlation-ID, see [trace-failover.md](trace-failover.md).

## "It failed over and I don't know why"

```bash
# Show the orchestrator's recent decisions.
sudo journalctl -u failover-monitor --since '15 minutes ago' | grep -E 'Score|Failover|Failback'

# Look at the metrics database (after-the-fact).
sudo sqlite3 /var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db \
    'SELECT timestamp, event_type, primary_score_before, backup_score_before, reason FROM failover_events ORDER BY timestamp DESC LIMIT 20'
```

The most informative log lines:

| Pattern | Meaning |
|---------|---------|
| `USR1 received: instant failover` | nmcli-failover-monitor signalled a fast failover. |
| `Failover triggered: eth0 → lte0 (score X)` | Score-based failover. |
| `Emergency-Failover: score below EMERGENCY_THRESHOLD` | One bad scoring round triggered failover (rare; thresholds were configured aggressively). |
| `Last-resort failover (LAST_RESORT_ENABLED=true)` | Cap was overridden because primary went catastrophic. |
| `Failback triggered after RECOVERY_THRESHOLD stable rounds` | DSL recovered and stayed stable. |

## "It should have failed over and didn't"

```bash
# Are all four services running?
systemctl is-active failover-monitor nmcli-failover-monitor route-guardian failover-metrics-collector

# What did nmcli-failover-monitor see?
sudo journalctl -u nmcli-failover-monitor -n 200

# Is the orchestrator's PID still reachable?
cat /run/linux-dual-wan-failover/failover-monitor.pid
ps -p "$(cat /run/linux-dual-wan-failover/failover-monitor.pid)" -o pid,cmd

# Is there a stale lockfile blocking route-guardian?
ls -la /run/linux-dual-wan-failover/failover-in-progress.lock
# If the file exists and the PID inside is dead → stale; remove it:
sudo rm -f /run/linux-dual-wan-failover/failover-in-progress.lock
```

## Score doesn't reflect reality

```bash
# What does the orchestrator currently think?
cat /run/linux-dual-wan-failover/wan-state/connection_metrics

# What's it actually measuring?
sudo journalctl -u failover-monitor --since '2 minutes ago' | grep -E 'latency|loss|dns|gateway'

# Manual check (same probes the scoring uses):
ping -c 3 -I eth0 8.8.8.8
ping -c 3 -I lte0 8.8.8.8
dig +short google.com @8.8.8.8 -b 0.0.0.0
```

## Routes look wrong

```bash
ip route show
# Good (steady-state, primary up):
#   default via <PRIMARY_GW> dev eth0 metric 50
#   default via <BACKUP_GW> dev lte0 metric 200
#
# Good (during failover to backup):
#   default via <PRIMARY_GW> dev eth0 metric 500   ← demoted
#   default via <BACKUP_GW> dev lte0 metric 200   ← winning
#
# Bad (route-guardian asleep):
#   default via <PRIMARY_GW> dev eth0 metric 50   ← should be 500!
#   default via <BACKUP_GW> dev lte0 metric 200
#   default via <PRIMARY_GW> dev eth0 metric 100  ← duplicate from NM!
```

If the route-guardian seems asleep:

```bash
sudo journalctl -u route-guardian -n 100
# Look for: "Skipping due to failover-in-progress lockfile"
# If you see that for many cycles → stale lockfile (see above).
```

## Quota cap behaving unexpectedly

```bash
# What does the orchestrator see?
cat /var/lib/linux-dual-wan-failover/quota-snapshot.json

# When was it last updated?
stat -c '%y' /var/lib/linux-dual-wan-failover/quota-snapshot.json

# If older than QUOTA_SNAPSHOT_MAX_STALE_SEC, the cap is ignored — that's
# the safety mechanism, not a bug.

# Force a refresh.
sudo systemctl start quota-provider-netgear-lm1200.service  # or your provider
```

## Total connectivity loss

If you have **zero default routes**, you've hit a worst-case bug.
Recovery first, debug after:

```bash
# Restore manually with your real gateway IPs:
sudo ip route add default via <PRIMARY_GW> dev eth0 metric 50
sudo ip route add default via <BACKUP_GW> dev lte0 metric 200
ping -c 3 8.8.8.8

# Then look at why:
sudo systemctl restart failover-monitor route-guardian
sudo journalctl -u failover-monitor -u route-guardian --since '5 minutes ago'
```

Open a bug report with the full output.
