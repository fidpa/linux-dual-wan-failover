# How-to: configure Mattermost alerting

## Prerequisites

- A Mattermost server with an [incoming webhook](https://docs.mattermost.com/developer/webhooks-incoming.html)
  enabled.
- The webhook URL (looks like `https://your-mattermost/hooks/abc123...`).
- A channel where alerts should land (or trust the webhook's default
  channel).

## Set the webhook URL

The plugin reads `ALERT_MATTERMOST_WEBHOOK_URL` from the environment.
Best practice: store it in a separate, mode-0600 file so it doesn't end
up in `failover.conf` (which is mode 0644 because systemd reads it).

```bash
sudo tee /etc/linux-dual-wan-failover/mattermost.env >/dev/null <<'EOF'
ALERT_MATTERMOST_WEBHOOK_URL=https://your-mattermost/hooks/REPLACE-ME
ALERT_MATTERMOST_USERNAME=linux-dual-wan-failover
ALERT_MATTERMOST_ICON_EMOJI=:rotating_light:
EOF

sudo chmod 600 /etc/linux-dual-wan-failover/mattermost.env
sudo chown root:root /etc/linux-dual-wan-failover/mattermost.env
```

## Wire it into the services

Two services send alerts: `failover-monitor` (failovers, failbacks) and
`route-guardian` (missing or duplicate routes, both WANs down). Add the env
file to both, or the one without it drops its alerts silently:

```bash
sudo systemctl edit failover-monitor.service
sudo systemctl edit route-guardian.service
```

In each, add:

```ini
[Service]
EnvironmentFile=-/etc/linux-dual-wan-failover/mattermost.env
```

Then in `/etc/linux-dual-wan-failover/failover.conf`:

```bash
ALERTING_BACKEND=mattermost
```

Restart and verify:

```bash
sudo systemctl daemon-reload
sudo systemctl restart failover-monitor.service
sudo systemctl restart route-guardian.service
```

## Test

Either trigger a real failover ([safe testing](safe-failover-testing.md)),
or send a test alert via the running orchestrator:

```bash
# Smoke test the plugin without a real failover:
sudo -u root bash -c '
  source /etc/linux-dual-wan-failover/failover.conf
  source /etc/linux-dual-wan-failover/mattermost.env
  source /usr/local/lib/linux-dual-wan-failover/lib/common.sh
  send_notification "Test alert from linux-dual-wan-failover" "info"
'
```

You should see the message in your Mattermost channel within a few
seconds. If not:

- `journalctl -u failover-monitor` (look for `[NOTIFICATION]` and
  the plugin source line).
- `curl -i $ALERT_MATTERMOST_WEBHOOK_URL -d 'payload={"text":"hi"}'`
  (raw test of the webhook, bypasses the plugin).

## How often route-guardian alerts

`route-guardian` checks every 10 s, so a route that stays missing would alert
on every check. It sends an alert type at most once per
`ALERT_RATE_LIMIT_SECONDS` (default 300) and logs the repeats instead. When the
route is back, it sends one recovery message with the downtime, counted from
the first alert. Losing both default routes at once is reported as one
`BOTH_WANS_DOWN` alert at critical level. There is no grace period: the first
occurrence is alerted at once.
