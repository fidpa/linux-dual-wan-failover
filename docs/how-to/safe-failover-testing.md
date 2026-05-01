# How-to: safely test a failover

You probably want to verify your failover works **before** you actually
need it. This document is the safe way to do that.

## Don't do this

```bash
sudo ip link set eth0 down
```

It will *probably* work, but the orchestrator never sees a NetworkManager
event for it (since you bypassed NM). NM and the kernel disagree about the
link state, conntrack state survives the change, and SSH connections may
hang for 15+ minutes with no recovery short of a physical console.

## Safe trigger #1: NetworkManager-down

This produces a real "primary went away" event the way the failover stack
expects to see it.

```bash
# In one window, watch the orchestrator.
sudo journalctl -u failover-monitor -f

# In another, take the primary down via NM.
sudo nmcli connection down "WAN-Primary"
# Within 5 seconds, the orchestrator logs:
#   USR1 received: instant failover
#   Failover triggered: eth0 → lte0
#   default via <BACKUP_GATEWAY> dev lte0 metric 200
```

Bring it back up:

```bash
sudo nmcli connection up "WAN-Primary"
# Within 5 minutes (RECOVERY_THRESHOLD × CHECK_INTERVAL):
#   Recovery threshold reached: eth0 stable
#   Failback triggered: lte0 → eth0
```

## Safe trigger #2: Score-collapse

Simulate "primary still up, but unusable":

```bash
# Block the primary's outbound from reaching CHECK_IPS without taking
# the link down. Use a temporary nftables rule.
sudo nft add rule inet filter output oif eth0 ip daddr 8.8.8.8 reject
sudo nft add rule inet filter output oif eth0 ip daddr 1.1.1.1 reject
sudo nft add rule inet filter output oif eth0 ip daddr 9.9.9.9 reject
sudo nft add rule inet filter output oif eth0 ip daddr 208.67.222.222 reject

# Score collapses → consecutive-failures threshold → failover.
```

To clean up: `sudo nft flush ruleset` (warning: also flushes all your
other rules — better to use a dedicated table).

## Resetting after testing

```bash
# Hard-reset all routes to the example-config baseline.
sudo systemctl restart failover-monitor route-guardian
ip route show | grep "^default"
# Should show two default routes:
#   default via <PRIMARY_GW> dev eth0 metric 50
#   default via <BACKUP_GW>  dev lte0 metric 200
```

## What if it didn't fail over?

1. Check the orchestrator's log: `journalctl -u failover-monitor -n 200`.
2. Check whether the event-driven monitor saw the link change:
   `journalctl -u nmcli-failover-monitor -n 100`.
3. Confirm the orchestrator's PID is reachable:
   `cat /run/linux-dual-wan-failover/failover-monitor.pid`.
4. Check the route-guardian isn't holding an old metric:
   `journalctl -u route-guardian -n 100`.
5. See [`debug-failover.md`](debug-failover.md) for the full runbook.
