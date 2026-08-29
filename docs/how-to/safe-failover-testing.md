# How-to: safely test a failover

You probably want to verify your failover works **before** you actually
need it. This document is the safe way to do that.

Read the timing section first. A failover is fast and a failback is not, and
the single most common "it's broken" report is someone who waited five minutes
for a failback that the daemon will not consider for an hour.

## Don't do this

```bash
sudo ip link set eth0 down
```

It will _probably_ work, but the orchestrator never sees a NetworkManager
event for it (since you bypassed NM). NM and the kernel disagree about the
link state, conntrack state survives the change, and SSH connections may
hang for 15+ minutes with no recovery short of a physical console.

## Timing: what to expect, and when

With the defaults from `config/failover.conf.example`:

| Direction | Gate | Default | Time |
|---|---|---|---|
| Failover (event path) | link-down confirmation | 5 s timeout, 500 ms poll | 4 to 6 s |
| Failover (score path) | `FAILURE_THRESHOLD` x `CHECK_INTERVAL` | 5 x 15 s | about 75 s |
| Failback | `RECOVERY_THRESHOLD` x `CHECK_INTERVAL` | 20 x 15 s | about 5 min |
| Failback | `MIN_BACKUP_TIME` | 3600 s | **1 h on the backup** |
| Failback | `MIN_STABLE_DURATION` | 900 s | 15 min of unbroken primary health |
| Failback | `MIN_FAILBACK_SCORE` | 60 | score at the moment of the decision |

**The failback gates are cumulative, and `MIN_BACKUP_TIME` dominates.** A
test failover at 14:00 will not fail back before 15:00, no matter how healthy
the primary looks at 14:05. Until then the daemon logs its reason once per
round:

```
Failback suppressed by MIN_BACKUP_TIME: 5min elapsed, 55min remaining (60min policy)
```

That line is the system working, not failing. If you want a test that
completes in minutes rather than an hour, lower the gates for the duration of
the test (see "Testing failback without waiting an hour" below) rather than
concluding that failback is broken.

## Safe trigger #1: NetworkManager-down

This produces a real "primary went away" event the way the failover stack
expects to see it.

```bash
# In one window, watch the orchestrator.
sudo journalctl -u failover-monitor -f

# In another, take the primary down via NM.
sudo nmcli connection down "WAN-Primary"
```

Within about five seconds the orchestrator logs the handover. The exact
wording, from `failover-monitor.sh`:

```
USR1 signal received - processing instant failover check
Processing instant failover request: eth0=<score> (fresh), lte0=<score> (fresh)
Failover triggered: eth0=<score>, lte0=<score> (delta >20, 1/5 consecutive failures)
```

Then bring the primary back:

```bash
sudo nmcli connection up "WAN-Primary"
```

The primary starts accumulating healthy rounds immediately, but the failback
waits for every gate in the table above. When they are finally met you get:

```
Stability requirements met: 3612s on backup (>= 3600s), 921s eth0 stable (>= 900s)
PREFER PRIMARY: eth0=<score> >= 60 after stability period (...) - triggering failback
```

## Safe trigger #2: Score-collapse

Simulate "primary still up, but unusable". Understanding why this works
matters, because a careless version of it does nothing at all.

The score sums four probes: `CHECK_IPS` reachability (0 to 25), DNS-over-HTTPS,
the gateway ping and an HTTP fetch (25 each). See
[`../reference/scoring.md`](../reference/scoring.md). Blocking the four default
`CHECK_IPS` takes out two probes at once, because the DoH resolvers live at two
of those same addresses (`dns.google` at 8.8.8.8, `cloudflare-dns.com` at
1.1.1.1):

| Probe | After the block | Points |
|---|---|---|
| Connectivity | all four targets unreachable | 0 |
| DNS | both DoH endpoints blocked | 0 |
| Gateway | one LAN hop, unaffected | 25 |
| HTTP | `http://google.com`, unaffected | 25 |

That is 50, below `FAILOVER_THRESHOLD_DOWN` (60), so the failover fires. Note
how little headroom there is: the gateway and HTTP probes alone are worth 50
points, and if your `CHECK_IPS` do **not** include the DoH addresses, DNS keeps
its 25 and the total lands at 75. Nothing happens, and the test looks like a
broken failover when it is really a test that never lowered the score enough.

```bash
# Block the primary's outbound from reaching CHECK_IPS without taking
# the link down. Use a dedicated table so cleanup cannot take out your
# other rules.
sudo nft add table inet failover_test
sudo nft add chain inet failover_test out '{ type filter hook output priority 0; }'
for ip in 8.8.8.8 1.1.1.1 9.9.9.9 208.67.222.222; do
    sudo nft add rule inet failover_test out oif eth0 ip daddr "$ip" reject
done
```

The addresses above are the shipped default. Confirm they are what your
daemon actually probes before you start, and substitute your own if not:

```bash
grep '^CHECK_IPS=' /etc/linux-dual-wan-failover/failover.conf
```

After `FAILURE_THRESHOLD` (5) consecutive rounds at 50, roughly 75 seconds in,
the failover fires. Cleanup removes only the test table:

```bash
sudo nft delete table inet failover_test
```

## Testing failback without waiting an hour

Lower the two time gates temporarily. They live in `failover.conf`, so the
change survives nothing but your own edit:

```bash
sudo cp /etc/linux-dual-wan-failover/failover.conf /root/failover.conf.bak
sudo sed -i 's/^MIN_BACKUP_TIME=.*/MIN_BACKUP_TIME=120/;   s/^MIN_STABLE_DURATION=.*/MIN_STABLE_DURATION=60/' \
    /etc/linux-dual-wan-failover/failover.conf
sudo systemctl restart failover-monitor
```

Failback then becomes reachable about three minutes after the primary
recovers. **Put the file back when you are done** and restart again:

```bash
sudo cp /root/failover.conf.bak /etc/linux-dual-wan-failover/failover.conf
sudo systemctl restart failover-monitor
```

Leaving the short values in place turns every transient primary recovery into
a real failback, which is exactly the oscillation the gates exist to prevent.

## After testing: returning to the primary

**A service restart does not undo a failover.** The daemon deliberately reads
the active WAN back out of the kernel routing table on startup, so that a
restart during an in-flight failover does not reset the demoted metric and
disrupt it:

```
Initialized active_wan state: backup (detected from routing: traffic via lte0)
```

So after a test you are still on the backup, with the primary demoted to
metric 500. Three ways back, in order of preference:

1. **Wait for the normal failback.** It is the path you actually want to
   verify.
2. **Request a manual failback** through the Web-UI, if installed. It writes
   `manual_action.json` into the daemon's runtime directory; the daemon reads
   it within one round and honours a 30-second freshness window plus a
   request-ID de-duplication. See
   [`configure-web-ui.md`](configure-web-ui.md) and
   [`../explanation/web-ui-architecture.md`](../explanation/web-ui-architecture.md).
3. **Restore the metric by hand**, if you have neither the patience nor the
   Web-UI. `route-guardian` accepts it because the daemon re-reads the
   routing table:

```bash
sudo ip route replace default via <PRIMARY_GW> dev eth0 metric 50
sudo systemctl restart failover-monitor
ip route show | grep '^default'
# Expected afterwards:
#   default via <PRIMARY_GW> dev eth0 metric 50
#   default via <BACKUP_GW>  dev lte0 metric 200
```

Note that a manual failback is subject to `ANTI_FLAPPING_DELAY` (600 s by
default), the same cooldown that applies to an automatic one.

## What if it didn't fail over?

1. Check the orchestrator's log: `journalctl -u failover-monitor -n 200`.
2. Check whether the event-driven monitor saw the link change:
   `journalctl -u nmcli-failover-monitor -n 100`.
3. Confirm the orchestrator is running and reachable for `SIGUSR1`:
   `systemctl show -p MainPID failover-monitor`. The daemon also writes its
   PID to `/run/failover-monitor.pid`, which is the file
   `nmcli-failover-monitor` reads before signalling.
4. Check the route-guardian isn't holding an old metric:
   `journalctl -u route-guardian -n 100`.
5. Trace one specific event end-to-end by its Correlation-ID:
   [`trace-failover.md`](trace-failover.md).
6. See [`debug-failover.md`](debug-failover.md) for the full runbook.
