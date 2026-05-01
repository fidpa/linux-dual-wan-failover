# Netgear LM1200 quota provider (reference implementation)

Queries a Netgear LM1200 / Sierra Wireless D86 modem via its `/api/model.json`
endpoint and writes a snapshot in the format consumed by `failover-monitor`.

## Compatibility

| Modem | Firmware | Status |
|-------|----------|--------|
| Netgear LM1200 | NTGX_LM1200_* | Tested in production for >1 year |
| Other Sierra D86 (e.g. MR1100) | similar | Likely works — please open a PR with your test results |

If your modem speaks a different API, copy
[`../custom-template/`](../custom-template/) and start there.

## Install

1. **Install the collector script:**
   ```bash
   sudo install -m 755 collect-quota.py \
       /usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/netgear-lm1200/collect-quota.py
   ```

2. **Configure credentials:**
   ```bash
   sudo cp lm1200.env.example /etc/linux-dual-wan-failover/lm1200.env
   sudo chmod 600 /etc/linux-dual-wan-failover/lm1200.env
   sudo $EDITOR /etc/linux-dual-wan-failover/lm1200.env  # set LM1200_PASSWORD
   ```

3. **Install the systemd unit + timer:**
   ```bash
   sudo install -m 644 \
       quota-provider-netgear-lm1200.service \
       quota-provider-netgear-lm1200.timer \
       /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now quota-provider-netgear-lm1200.timer
   ```

4. **Verify:**
   ```bash
   sudo systemctl start quota-provider-netgear-lm1200.service
   cat /var/lib/linux-dual-wan-failover/quota-snapshot.json
   # {
   #   "limit_pct": 23.4,
   #   "collected_at": "2026-04-27T12:34:56Z",
   #   "provider": "netgear-lm1200"
   # }
   ```

5. **Switch failover-monitor to use it:**
   ```bash
   sudo sed -i 's/^QUOTA_PROVIDER=.*/QUOTA_PROVIDER=netgear-lm1200/' \
       /etc/linux-dual-wan-failover/failover.conf
   sudo systemctl restart failover-monitor.service
   ```

## Manual usage / debugging

```bash
# Dry-run (queries the modem, prints JSON to stdout, doesn't write a file).
./collect-quota.py --dry-run --password-env-file /etc/linux-dual-wan-failover/lm1200.env

# Override the modem IP (factory default is 192.168.0.1; bridge-mode setups
# often use a different one).
./collect-quota.py --modem-ip 192.168.5.1 --debug --password-env-file ...
```

## Schema and tier configuration

The snapshot fields are documented in
[`../README.md`](../README.md) and the schema lives at
[`../_schema/quota-snapshot.schema.json`](../_schema/quota-snapshot.schema.json).

Tier defaults (in `failover.conf`):

```bash
QUOTA_CAP_TIER_90=40    # ≥ 90 % → cap to 40
QUOTA_CAP_TIER_96=10    # ≥ 96 % → cap to 10
QUOTA_CAP_TIER_100=0    # ≥ 100 % → cap to 0
```

## Caveats

- **Modem reboots reset the counter.** The LM1200's billing-cycle counter
  is firmware-tracked, not ISP-tracked. If you reboot the modem mid-billing-cycle,
  it loses count. For ISPs where this matters, prefer a portal-scrape provider.
- **No quota configured = `null`.** If your APN doesn't have a data-limit
  field set, `limit_pct` is `null` (correctly: "unknown"), no cap is applied.
- **Auth tokens expire.** The collector logs in fresh on every run, so the
  default 15-minute timer interval is fine. Don't crank the timer down to
  seconds — you'll generate a lot of noise in the modem's auth log.
