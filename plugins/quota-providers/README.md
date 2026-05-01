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

## Caps and tiers

Once `limit_pct` reaches one of the configured tiers, the backup score is
capped. Defaults from `failover.conf.example`:

```bash
QUOTA_CAP_TIER_90=40    # ≥ 90 % → cap to 40   (DSL wins at normal scores)
QUOTA_CAP_TIER_96=10    # ≥ 96 % → cap to 10   (DSL wins even with heavy E2E penalty)
QUOTA_CAP_TIER_100=0    # ≥ 100 % → cap to 0   (effectively blocks failover)
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

## Last-resort failover

Even with `QUOTA_CAP_TIER_100=0` (which normally blocks failover), the
orchestrator can be instructed to fail over anyway when the primary is
catastrophically dead:

```bash
LAST_RESORT_ENABLED=true
```

This is **off by default**. Enabling it means: when your primary is dead
AND your quota is exhausted, you choose "stay online and pay overage" over
"go offline until quota resets". Only operators who would otherwise be
woken up at 3 a.m. should enable this.

## Writing a custom provider

```bash
cp -r plugins/quota-providers/custom-template plugins/quota-providers/my-isp
$EDITOR plugins/quota-providers/my-isp/collect-quota.sh
```

The template is a 30-line Bash skeleton that already handles atomic writes
and the JSON schema. You only need to fill in `get_limit_pct()`.
