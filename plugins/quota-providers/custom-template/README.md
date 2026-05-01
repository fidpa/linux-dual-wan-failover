# custom-template

A 50-line Bash skeleton for writing your own quota provider.

## Steps

1. Copy the template to a sibling directory:
   ```bash
   cp -r plugins/quota-providers/custom-template plugins/quota-providers/my-isp
   ```

2. Edit `my-isp/collect-quota.sh`. Replace the body of `get_limit_pct()`
   with whatever query reaches your modem or ISP API. The function should
   print a percentage (0–100) on stdout, or print nothing if the value is
   unknown.

3. Wrap it in a systemd timer. A bare-minimum pair:

   `/etc/systemd/system/quota-provider-my-isp.service`:
   ```ini
   [Unit]
   Description=Quota collector for my ISP
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   EnvironmentFile=-/etc/linux-dual-wan-failover/failover.conf
   ExecStart=/usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/my-isp/collect-quota.sh
   ```

   `/etc/systemd/system/quota-provider-my-isp.timer`:
   ```ini
   [Unit]
   Description=Periodic quota collection for my ISP

   [Timer]
   OnBootSec=2min
   OnUnitActiveSec=15min
   AccuracySec=1min
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

4. Enable and verify:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now quota-provider-my-isp.timer
   sudo systemctl start quota-provider-my-isp.service
   cat /var/lib/linux-dual-wan-failover/quota-snapshot.json
   ```

5. Switch the failover-monitor over:
   ```bash
   sudo sed -i 's/^QUOTA_PROVIDER=.*/QUOTA_PROVIDER=my-isp/' /etc/linux-dual-wan-failover/failover.conf
   sudo systemctl restart failover-monitor.service
   ```

## What "good" looks like

- Your `get_limit_pct()` returns within `QUOTA_SNAPSHOT_MAX_STALE_SEC`
  (default 1 hour) on a normal run. If it can't, the snapshot becomes
  stale and the cap is correctly ignored.
- Failures (modem unreachable, auth expired, JSON malformed) cause the
  script to exit non-zero. The previous snapshot stays in place; once it
  ages past the staleness window, the cap is automatically disabled.
- Don't print debug logs to stdout — that confuses the snapshot writer.
  Use stderr or the systemd journal.
- Don't store credentials in `failover.conf`. Use a separate
  `EnvironmentFile=` (`mode 0600`) or systemd's `LoadCredential=`.
