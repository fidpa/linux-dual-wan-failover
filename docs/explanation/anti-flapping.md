# Anti-flapping and hysteresis

Failover stacks that "just work" in a lab tend to flap in production. This
document covers the four mechanisms `failover-monitor` uses to make sure
that doesn't happen.

## 1. Asymmetric thresholds

Failover and failback use different score conditions:

```
fail over   when primary_score < FAILOVER_THRESHOLD_DOWN  (default 60)
fail back   when primary_score >= MIN_FAILBACK_SCORE      (default 60)
            AND the time-based stability gates have passed
            (MIN_BACKUP_TIME + MIN_STABLE_DURATION, section 3)
```

The asymmetry lives in the *time* domain, not in the score domain: a
failback additionally requires RECOVERY_THRESHOLD consecutive good checks,
a minimum dwell time on the backup, and a continuous stability window.

> Historical note: earlier designs used a score-based hysteresis pair
> (`FAILOVER_THRESHOLD_UP=80`, `HYSTERESIS_GAP=20`). The daemon no longer
> evaluates those variables — the time-based gates proved strictly more
> robust against score noise — and the dead hysteresis code path was
> removed. The config example keeps both names as commented-out
> documentation so operators migrating old configs aren't surprised.

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
that _almost_ works is worse than staying on a slightly-suboptimal
backup.

## 3. Cooldowns

Even if the thresholds-and-counters say "switch again", the cooldowns say
"wait":

```
ANTI_FLAPPING_DELAY         = 600 s  (10 min; failback + manual actions only — score-based failover has no cooldown)
EMERGENCY_FAILBACK_COOLDOWN = 3600 s (60 min after an emergency failback)
```

These bound the worst-case flap rate. Even adversarial traffic can't
ping-pong faster than ~6 switches/hour.

### A cooldown that never fires is not a cooldown

`last_failover_mono` is an in-memory variable, zero-initialised at daemon
start, and `get_monotonic_time()` reads `/proc/uptime`. Subtracting the two
without a guard means the daemon computes `uptime - 0` when no failover has
happened yet. On a host that has been up for days that is a harmlessly large
number; within the first `ANTI_FLAPPING_DELAY` seconds after a **reboot** it
suppresses every failback and every manual action, logging a confident
"last failover was 47s ago" for a failover that never occurred.

The fix is a one-line guard (`[[ $last_failover_mono -gt 0 ]]`), but the
lesson generalises: any "time since last X" check needs an explicit
"X never happened" case, and it will not show up in testing on a
long-running box. A test for it must fake the clock.

### Cooldowns and runtime state disappear together

`RuntimeDirectory=` without `RuntimeDirectoryPreserve=` clears the state
directory on **every** service restart. That takes `last_failover_to_backup`
with it — and readers that default a missing timestamp to `0` silently turn
"how long have we been on backup" into "seconds since 1970", which passes
every minimum-time gate ever written. The daemon now reseeds the timestamp at
startup when it finds itself on backup, and the emergency path refuses to act
on an unknown value.

## 4. Stability window for failback

Failback requires the primary to have been stable for `MIN_STABLE_DURATION`
(default 900 s = 15 min). The window starts when the primary's score first
returns to `FAILOVER_THRESHOLD_DOWN` or above after a dip.

`STABILITY_RESET_THRESHOLD` (default 50) was introduced to make the window
survive borderline scores: the two-tier design came from a real-world bug
where setting the reset threshold equal to the failover threshold (60) meant
any oscillation in the 50–75 range kept the window open _and_ the failover
counter rising, producing repeated failovers without clean failback.

> **The threshold does not actually do this.** Any score below
> `FAILOVER_THRESHOLD_DOWN` zeroes `consecutive_recoveries`, which is the
> first gate in `is_failback_needed()` — so the stability window is never
> read while the primary is degraded. When the primary recovers, the window
> restarts from that moment regardless of how far the score dipped. The
> threshold changes which log line you get, not when failback happens.
>
> The practical effect is that failback gating is slightly *stricter* than
> this section used to claim — the window restarts after every dip. That is
> the safe direction, which is why the behaviour is documented rather than
> "fixed": making the window genuinely survive a dip would shorten the
> stability actually required before returning to the primary.

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

- `STABILITY_RESET_THRESHOLD` — changing it will not change failback
  timing (see section 4). If you want a longer stability requirement,
  raise `MIN_STABLE_DURATION` instead.
