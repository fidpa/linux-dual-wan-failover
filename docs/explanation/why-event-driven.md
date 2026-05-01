# Why event-driven (not just polling)

A polling-only failover stack is correct, simple, and slow. This stack uses
polling **plus** event detection because the cost of slow failover is sometimes
worse than the cost of more code.

## Polling alone

```
T+0.0s   primary link goes dead
T+0.0s   ...
T+15.0s  next scoring round: primary score = 0
T+15.0s  consecutive_failures = 1 (need 5)
T+30.0s  consecutive_failures = 2
T+45.0s  consecutive_failures = 3
T+60.0s  consecutive_failures = 4
T+75.0s  consecutive_failures = 5 → trigger failover
T+76.0s  default route now via lte0
```

**Total: ~76 seconds** before the route switches. For a video call or an
SSH session, that's an end-of-call event, not a glitch.

You could shorten the loop and tighten the threshold, but you'd start
chasing every transient: line-sync glitches at 03:00, brief packet-loss
spikes during BGP reconvergence, your modem deciding to reboot for a
firmware check. The threshold-of-5 exists for a reason.

## Adding event detection

NetworkManager already knows when an interface goes down. It emits an
event almost immediately. The event-driven monitor turns that event into
a `SIGUSR1` to the orchestrator, which has a fast-path that skips scoring:

```
T+0.0s   primary link goes dead
T+0.0s   NetworkManager emits "device disconnected"
T+0.1s   nmcli-failover-monitor parses event
T+5.0s   wait_for_link_down confirmation window passes (no flapping)
T+5.0s   nmcli-failover-monitor creates lockfile, sends SIGUSR1
T+5.1s   failover-monitor's USR1 handler sets pending flag
T+5.2s   main loop sees flag → emergency-failover code path
T+5.3s   default route now via lte0
```

**Total: ~5 seconds.** An SSH session might notice; a TCP connection
that already has data in flight will likely survive.

The five-second confirmation window matters: it filters out brief
disconnect/reconnect bounces (NM rapidly emitting two events as the
modem re-DHCPs, for example).

## Why not skip polling entirely?

Three reasons:

1. **NM doesn't fire events for *quality* changes.** A link that's up but
   rate-limited to 5 kbit/s is invisible to NM. Only the score-based
   monitor will notice and (eventually) fail over.
2. **NM doesn't always emit the events you'd expect.** Some firmware
   bugs cause an interface to drop packets without changing NM state.
   Suspend/resume can leave NM with stale state. Polling is the
   safety net.
3. **Quota-based capping is a polling phenomenon.** The quota provider
   updates a snapshot file every 15 minutes; the orchestrator only
   notices in its scoring loop. There's no NM event for "you've used 96 %
   of your data this month."

So: events are the fast path for the common case (interface fully dies),
polling is the comprehensive path for everything else, and they signal
each other through a lockfile and SIGUSR1 to keep the two coordinated.
