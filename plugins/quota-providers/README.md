# Quota providers

Optional plugins that report how much of your **backup-link's** monthly data
quota has been consumed. The `failover-monitor` reads the snapshot to cap
the backup-interface score when you approach the quota — protecting you
from overage charges during a flaky-but-not-dead primary.

## Built-in providers

| Provider | Directory | Status |
|----------|-----------|--------|
| `no-op` (default) | [`no-op/`](no-op/) | Default. No tracking, no cap. |
| `netgear-lm1200` | [`netgear-lm1200/`](netgear-lm1200/) | Reference implementation. Sierra Wireless D86 firmware (LM1200, MR1100, etc.). |
| `custom` | [`custom-template/`](custom-template/) | Skeleton for your own modem or ISP API. |

## Architecture

```
┌─────────────────────────────────┐         ┌──────────────────────────────┐
│ Provider plugin                 │ writes  │ failover-monitor             │
│ - own systemd timer             │────────▶│ - reads QUOTA_SNAPSHOT_PATH  │
│ - queries upstream API          │ JSON    │ - caps backup-iface score    │
│ - writes quota-snapshot.json    │         │ - decision: route or not    │
└─────────────────────────────────┘         └──────────────────────────────┘
                 │ same file                 ┌──────────────────────────────┐
                 └──────────────────────────▶│ quota-hard-block (opt-in)    │
                                             │ - nftables drop on BACKUP_IF │
                                             └──────────────────────────────┘
```

The contract is **a file format**, not a function-call interface. This means
your provider can be Python, Bash, Rust, a Cloud Function, anything — as
long as it produces a JSON file matching the schema.

## Snapshot schema

See [`_schema/quota-snapshot.schema.json`](_schema/quota-snapshot.schema.json).

```json
{
  "limit_pct": 87.4,
  "collected_at": "2026-04-27T12:34:56Z",
  "provider": "netgear-lm1200"
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `limit_pct` | number ≥ 0 OR `null` | yes | Percentage of monthly quota consumed. `null` = unknown / no quota configured upstream → no cap. |
| `collected_at` | string (ISO-8601 UTC) | yes | Helps operators audit the snapshot's freshness. The orchestrator itself uses file `mtime`, not this field. |
| `provider` | string | no | Free-text identifier. Useful for debugging when you switch between providers. |
| `billing_cycle_days_left` | integer ≥ 0 | no | Days until the upstream counter resets. Used by the hard block to detect a new cycle; omit if the upstream API does not expose it. |

## Caps and tiers

Once `limit_pct` reaches one of the configured tiers, the backup score is
capped. Defaults from `failover.conf.example`:

```bash
QUOTA_CAP_TIER_90=40    # ≥ 90 % → cap to 40   (DSL wins at normal scores)
QUOTA_CAP_TIER_96=10    # ≥ 96 % → cap to 10   (DSL wins even with heavy E2E penalty)
QUOTA_CAP_TIER_100=0    # ≥ 100 % → cap to 0   (no score-based failover)
```

If the snapshot file is older than `QUOTA_SNAPSHOT_MAX_STALE_SEC`
(default 1 hour), the cap is **ignored** — graceful degradation when your
provider is stuck or the modem is unreachable.

## Selecting a provider

In `/etc/linux-dual-wan-failover/failover.conf`:

```bash
QUOTA_PROVIDER=netgear-lm1200
QUOTA_SNAPSHOT_PATH=/var/lib/linux-dual-wan-failover/quota-snapshot.json
```

The provider's own systemd timer (e.g. `quota-provider-netgear-lm1200.timer`)
must be enabled separately. See each provider's `README.md` for install
instructions.

## Hard block

The caps only steer the orchestrator. To stop backup traffic outright once
the quota is used up — including the kernel's own fallback to the backup
route — enable the opt-in hard block (`QUOTA_HARD_BLOCK=true`,
`quota-hard-block.timer`). It reads the same snapshot. Providers that can
report `billing_cycle_days_left` should do so: it lets the block recognise
a new billing cycle even while the counter reads exactly 0. See
[`docs/how-to/configure-quota-tracking.md`](../../docs/how-to/configure-quota-tracking.md#hard-block-stop-all-backup-traffic-at-the-quota-opt-in).

## Writing a custom provider

```bash
cp -r plugins/quota-providers/custom-template plugins/quota-providers/my-isp
$EDITOR plugins/quota-providers/my-isp/collect-quota.sh
```

The template is a 30-line Bash skeleton that already handles atomic writes
and the JSON schema. You only need to fill in `get_limit_pct()`.
