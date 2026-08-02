# Scoring algorithm

`failover-monitor`'s decision to switch routes is driven by a per-interface
score from 0 to 100. This document describes how that score is computed.

## Inputs

For each interface (independently, every `CHECK_INTERVAL`):

| Test | Implementation | Default weight |
|------|----------------|----------------|
| Connectivity | `ping` against each `CHECK_IPS` target, bound to `<iface>` | 0–25 |
| DNS | DNS-over-HTTPS via `curl --interface <iface>` | 0 or 25 |
| Gateway | `ping` to the auto-detected gateway for `<iface>` | 0 or 25 |
| HTTP | `curl --interface <iface>` against a known-good HTTP target | 0 or 25 |

Connectivity is **proportional** — the score scales with how many `CHECK_IPS`
targets answered. The other three tests are **binary**: the first successful
probe earns the full 25 points; total failure earns 0. Sum: 0–100.

> **On the DNS row**: the test binds with `curl --interface`, which is a real
> `SO_BINDTODEVICE` binding. An earlier implementation used `dig -b`, which only
> sets the *source address* — packets still left via the active default route, so
> the backup interface reported "DNS OK" even when it was unusable. If you
> reimplement this test, keep the device binding.

> **On the Gateway row**: this probe is deliberately a reachability check, not a
> quality one. The gateway is one LAN hop away and answers in about a
> millisecond regardless of uplink health, so it can only tell you "the modem or
> router is gone". Link quality comes from the connectivity, DNS and HTTP rows —
> and, for the graphs, from `wan_quality.prom` (see
> [metrics.md](metrics.md)).

## Modifiers

The raw score is then modulated:

### LTE bonus (cellular only)

If the interface name matches `lte*` or `wwan*` and its raw score ≥ 70:

> Note: the bonus is applied per interface name, not per the configured
> `BACKUP_IFACE`. An interface named `lte0` receives the bonus regardless
> of whether it is configured as primary or backup.

```
score += 15
```

This compensates for cellular's higher latency floor (~30–50 ms vs.
DSL's ~10–20 ms) so a "good" cellular link doesn't lose to a "barely
acceptable" DSL purely on the latency component.

### E2E penalty

If `wan_quality.prom` reports DNS or HTTP times above the latency thresholds,
a penalty is subtracted. This reflects "the link is up but everything
on top of it is slow" cases that the binary tests miss.

That file is written by `failover-metrics-collector`, which ships with this
repo — it is not something you have to supply. If the service is not running,
the file goes stale and the penalty is skipped after
`WAN_QUALITY_PROM_MAX_AGE` seconds (fail-safe: no penalty rather than a
penalty based on old data).

### Backup-link quota cap

If the backup interface and the quota provider plugin reports `limit_pct`
above one of the thresholds:

```
limit_pct ≥ 100   → cap = QUOTA_CAP_TIER_100   (default 0)
limit_pct ≥ 96    → cap = QUOTA_CAP_TIER_96    (default 10)
limit_pct ≥ 90    → cap = QUOTA_CAP_TIER_90    (default 40)
otherwise         → no cap
```

If the snapshot is older than `QUOTA_SNAPSHOT_MAX_STALE_SEC`, the cap is
ignored.

### Final clamp

```
score = max(0, min(100, score))
```

## Decision

After both interfaces have a score:

```
If current_active == primary:
    if primary_score < FAILOVER_THRESHOLD_DOWN  for FAILURE_THRESHOLD consecutive rounds
        → fail over to backup
    if primary_score < EMERGENCY_THRESHOLD on a single round
        → emergency fail over (skip consecutive-check)

If current_active == backup:
    if primary_score >= MIN_FAILBACK_SCORE for RECOVERY_THRESHOLD consecutive rounds
        AND time_on_backup >= MIN_BACKUP_TIME
        AND primary_continuously_stable_for >= MIN_STABLE_DURATION
        → fail back to primary
```

## Why these defaults?

- **5 consecutive failures × 15 s = 75 s tolerance.** Short enough for a
  real outage to trigger failover; long enough to ride through DSL line-sync
  events at 03:00 (a real-world false-positive source).
- **20 consecutive successes × 15 s = 5 min stability.** Short enough to
  recover usefully after a transient; long enough not to flap.
- **MIN_BACKUP_TIME=3600 (1 h).** After a failover, you've already paid
  the connection-disruption cost; staying on the working backup for at
  least an hour avoids ping-pong with a borderline primary.
- **MIN_STABLE_DURATION=900 (15 min).** Primary must be stable for the
  full 15-minute window before the orchestrator considers failback.

## Where the numbers actually live

The default values above are documented in
[`config/failover.conf.example`](../../config/failover.conf.example).
The implementation is in
[`src/lib/performance.sh::test_interface_comprehensive()`](../../src/lib/performance.sh).
