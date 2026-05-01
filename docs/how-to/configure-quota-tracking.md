# How-to: configure quota tracking

If your backup link is metered (e.g. an LTE modem on a 50 GB/month plan),
you want the failover stack to *know* when you're approaching the cap so
it doesn't merrily route traffic to LTE while a flaky-but-not-dead DSL
struggles along.

This is the optional **quota provider** plugin slot. See
[`../reference/architecture-overview.md`](../reference/architecture-overview.md)
for the architectural rationale.

## Pick a provider

| Your setup | Recommended | Notes |
|------------|-------------|-------|
| Netgear LM1200 / Sierra Wireless D86 | [`netgear-lm1200`](../../plugins/quota-providers/netgear-lm1200/) | Tested in production. |
| Other LTE modem with an HTTP admin UI | `custom-template` | Usually means scraping `/api/...` JSON. |
| ISP customer-portal scraping | `custom-template` | More fragile; expect to maintain it. |
| Unmetered backup link | `none` (default) | No need for quota tracking. |

## Quick path: Netgear LM1200

```bash
# 1. Install the collector + systemd units.
cd linux-dual-wan-failover
sudo install -d /usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/netgear-lm1200
sudo install -m 755 plugins/quota-providers/netgear-lm1200/collect-quota.py \
    /usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/netgear-lm1200/
sudo install -m 644 plugins/quota-providers/netgear-lm1200/*.service \
    plugins/quota-providers/netgear-lm1200/*.timer \
    /etc/systemd/system/

# 2. Set the password (mode 0600).
sudo install -m 600 plugins/quota-providers/netgear-lm1200/lm1200.env.example \
    /etc/linux-dual-wan-failover/lm1200.env
sudo $EDITOR /etc/linux-dual-wan-failover/lm1200.env  # set LM1200_PASSWORD

# 3. Enable the timer.
sudo systemctl daemon-reload
sudo systemctl enable --now quota-provider-netgear-lm1200.timer

# 4. Run once and verify the snapshot.
sudo systemctl start quota-provider-netgear-lm1200.service
cat /var/lib/linux-dual-wan-failover/quota-snapshot.json

# 5. Tell failover-monitor to read it.
sudo sed -i 's/^QUOTA_PROVIDER=.*/QUOTA_PROVIDER=netgear-lm1200/' \
    /etc/linux-dual-wan-failover/failover.conf
sudo systemctl restart failover-monitor.service
```

Full details: [`../../plugins/quota-providers/netgear-lm1200/README.md`](../../plugins/quota-providers/netgear-lm1200/README.md).

## Custom provider

If your modem isn't supported, copy the template and fill in the query:

```bash
cp -r plugins/quota-providers/custom-template plugins/quota-providers/my-isp
$EDITOR plugins/quota-providers/my-isp/collect-quota.sh
# Replace the body of get_limit_pct() with your modem-specific logic.
```

Walkthrough: [`../../plugins/quota-providers/custom-template/README.md`](../../plugins/quota-providers/custom-template/README.md).

## Tuning the caps

By default:

| Quota used | Cap on backup score | Effect |
|------------|---------------------|--------|
| < 90 % | none | Backup competes normally. |
| ≥ 90 % | 40 | DSL wins at normal scores. |
| ≥ 96 % | 10 | DSL wins even at heavy degradation. |
| ≥ 100 % | 0 | Backup blocked entirely. |

Adjust in `failover.conf`:

```bash
QUOTA_CAP_TIER_90=40
QUOTA_CAP_TIER_96=10
QUOTA_CAP_TIER_100=0
```

## What if the snapshot becomes stale?

Default policy: if the snapshot is older than `QUOTA_SNAPSHOT_MAX_STALE_SEC`
(1 hour), the cap is **ignored**. This is graceful degradation: when the
modem is unreachable or the collector is stuck, you'd rather fail over
than be locked to a possibly-dead primary because of a stale quota number.

Tighter or looser:

```bash
QUOTA_SNAPSHOT_MAX_STALE_SEC=3600  # default (1 h)
```

Set to `0` to never ignore the cap (not recommended — you'll lose
failover capability when the modem reboots).

## Last-resort failover (override the cap)

If you'd rather pay overage than be offline, set:

```bash
LAST_RESORT_ENABLED=true
LAST_RESORT_PRIMARY_THRESHOLD=25
```

When the primary's score drops below 25 *and* the quota cap would block
failover, the orchestrator overrides the cap and fails over anyway,
emitting a CRIT_FAILOVER alert so you can see it happened. Off by
default — most operators prefer a known outage to a surprise overage
charge.
