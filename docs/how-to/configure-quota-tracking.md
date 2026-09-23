# How-to: configure quota tracking

If your backup link is metered (e.g. an LTE modem on a 50 GB/month plan),
you want the failover stack to _know_ when you're approaching the cap so
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
| ≥ 100 % | 0 | Backup scores 0 — no score-based failover. The kernel can still route over it; see the hard block below. |

Adjust in `failover.conf`:

```bash
QUOTA_CAP_TIER_90=40
QUOTA_CAP_TIER_96=10
QUOTA_CAP_TIER_100=0
```

## What if the snapshot becomes stale?

Default policy: if the snapshot is older than `QUOTA_SNAPSHOT_MAX_STALE_SEC`
(1 hour), the cap is **ignored** (an active hard block is not — it stays
until a fresh reading lifts it). This is graceful degradation: when the
modem is unreachable or the collector is stuck, you'd rather fail over
than be locked to a possibly-dead primary because of a stale quota number.

Tighter or looser:

```bash
QUOTA_SNAPSHOT_MAX_STALE_SEC=3600  # default (1 h)
```

Set to `0` to never ignore the cap (not recommended — you'll lose
failover capability when the modem reboots).

## Hard block: stop all backup traffic at the quota (opt-in)

The caps above only steer the orchestrator. The kernel still holds the
backup default route, and when the primary loses carrier (unplugged cable,
dead modem) it falls back to that route on its own — no failover decision
involved. On a metered link that is exactly the traffic you wanted to
avoid. The hard block closes that gap at packet level:

```bash
QUOTA_HARD_BLOCK=true
QUOTA_HARD_BLOCK_PCT=99                     # integer 1-100
QUOTA_HARD_BLOCK_ALLOW="192.168.0.0/24"     # still reachable via the backup (modem API)
```

```bash
sudo systemctl enable --now quota-hard-block.timer
```

Once the snapshot reports `QUOTA_HARD_BLOCK_PCT` or more,
`quota-hard-block.sh` (run by the timer as root) loads an nftables table
`inet ldwf_quota_block` that drops every packet leaving via `BACKUP_IFACE`,
except to `QUOTA_HARD_BLOCK_ALLOW` and the DHCP broadcast. From then on:

- `failover-monitor` refuses every switch to the backup (score-based,
  carrier pre-check, instant event, manual force) and, if it is on the
  backup, switches back to the primary at once.
- `nmcli-failover-monitor` skips its emergency route switch.
- The web UI shows a banner and answers `POST /api/force-failover` with
  `409 quota_hard_block`.
- If the primary dies, **you are offline** until the quota resets. That is
  the point: no overage charges.

**Surviving reboots and ruleset reloads.** The state is the file
`/var/lib/linux-dual-wan-failover-quota-block/quota-block.nft`, a
self-contained nftables script. Add this line to `/etc/nftables.conf` so
the block is part of every ruleset load:

```nft
include "/var/lib/linux-dual-wan-failover-quota-block/*.nft"
```

The glob matches nothing while no block is active. Without the include,
the timer re-applies the table within five minutes of a reload. Keep the
include pointing at `/var/lib`, not at a checkout under `/home`: Debian's
`nftables.service` runs with `ProtectHome=true`, and an include it cannot
read makes the **whole** ruleset fail to load.

**Lifting.** The block stays until a fresh snapshot (younger than
`QUOTA_SNAPSHOT_MAX_STALE_SEC`) shows less than the threshold *and* looks
like a new billing cycle: `limit_pct > 0`, or `billing_cycle_days_left` went
up, or the provider does not report `billing_cycle_days_left` at all. A
stale or missing snapshot never lifts it (fail-closed). If a new cycle
starts but the counter still reads above the threshold, you get a warning.

**Lifting by hand** (you accept the overage):

```bash
sudo systemctl stop quota-hard-block.timer     # otherwise the next run re-blocks
sudo nft delete table inet ldwf_quota_block
sudo rm -f /var/lib/linux-dual-wan-failover-quota-block/quota-block.nft
```

**Check the state:**

```bash
sudo nft list table inet ldwf_quota_block      # present = blocked, with drop counters
journalctl -u quota-hard-block.service -n 20
```
