# Anti-flapping and hysteresis

Failover stacks that "just work" in a lab tend to flap in production. This
document covers the four mechanisms `failover-monitor` uses to make sure
that doesn't happen.

## 1. Asymmetric thresholds

Failover and failback use different score thresholds:

```
fail over   when primary_score < FAILOVER_THRESHOLD_DOWN  (default 60)
fail back   when primary_score > FAILOVER_THRESHOLD_UP    (default 80)
```

The 20-point gap (`HYSTERESIS_GAP`) prevents the orchestrator from
oscillating when the primary is hovering at exactly the threshold.

## 2. Consecutive-check requirements

A single bad scoring round doesn't trigger failover:

```
fail over only after FAILURE_THRESHOLD = 5 consecutive failures
fail back only after RECOVERY_THRESHOLD = 20 consecutive successes
```

At the default `CHECK_INTERVAL=15s`:

| Action | Total time |
|--------|------------|
| fail over | 5 × 15 = **75 s** of bad-score before action |
| fail back | 20 × 15 = **300 s** of good-score before action |

Failback is harder than failover on purpose. Failback into a primary
that *almost* works is worse than staying on a slightly-suboptimal
backup.

## 3. Cooldowns

Even if the thresholds-and-counters say "switch again", the cooldowns say
"wait":

```
ANTI_FLAPPING_DELAY        = 600 s  (10 min between any two switches)
EMERGENCY_FAILBACK_COOLDOWN = 900 s  (15 min after an emergency-failover)
```

These bound the worst-case flap rate. Even adversarial traffic can't
ping-pong faster than ~6 switches/hour.

## 4. Stability window for failback

Failback requires the primary to have been stable for `MIN_STABLE_DURATION`
(default 900 s = 15 min). The window resets if the primary's score drops
below `STABILITY_RESET_THRESHOLD` (default 50).

The two-tier reset is here to avoid a real-world bug: setting the reset
threshold equal to the failover threshold (60) meant any oscillation in
the 50–75 range kept the window open *and* the failover counter rising,
producing repeated failovers without clean failback. Splitting the
reset threshold below the failover threshold lets the window survive
borderline scores while still resetting on truly bad scores.

## Why "failback is more dangerous than failover"

Empirically, failback failures outnumber failover failures roughly 3:1.

The reasons:

1. **The primary route may be only partially restored.** DHCP renewal on
   the primary happens before the link's actual quality stabilises. A
   primary with `metric 50` route and a not-yet-converged BGP session is
   worse than a stable backup.
2. **`ip route` operations are not atomic.** During failback, you delete
   the active backup route, then add the primary route. If the add fails
   (typo, stale gateway, conntrack confused), you have zero default
   routes for an instant — and the kernel may drop in-flight connections.
3. **NetworkManager fights you.** During the moment of route-table
   manipulation, NM may choose to add or remove routes of its own,
   producing duplicates that then need cleanup.

`route-guardian::emergency_restore_any_route` is the safety net: if a
failback leaves the system without any default route, the guardian's
next iteration restores whichever default route is available. That's
why route-guardian runs at a tighter interval than failover-monitor.

## What to tune (and what not to)

If you're seeing flapping:

- **First, check** that all four services are running. A crashed
  route-guardian masquerades as flapping (the orchestrator switches,
  the routes don't get cleaned up, scores look weird, the orchestrator
  switches back).
- **Increase `FAILURE_THRESHOLD`** before lowering thresholds. More
  consecutive failures = more confidence in the failure.
- **Lengthen `MIN_BACKUP_TIME`** if you're seeing "failed over,
  backup was fine, failed back too quickly".
- **Lower `EMERGENCY_THRESHOLD`** before you raise it. Emergency
  failover should be reserved for catastrophic primary failures
  (score 0–15), not borderline ones.

What not to touch unless you know why:

- `STABILITY_RESET_THRESHOLD` — the 10-point gap below
  `FAILOVER_THRESHOLD_DOWN` exists for the bug above.
- `HYSTERESIS_GAP` — already large enough at 20 points to suppress
  most natural noise.
