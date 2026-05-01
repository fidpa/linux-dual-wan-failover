# Alerting plugins

Selectable backends for `failover-monitor`'s `send_notification()` hook.
Set `ALERTING_BACKEND` in `failover.conf` to choose one.

## Built-in plugins

| Backend | File | Purpose |
|---------|------|---------|
| `none` (default) | (no file — early return in core) | Silent. The orchestrator only logs. |
| `mattermost` | [`mattermost.sh`](mattermost.sh) | POST to a Mattermost incoming-webhook URL. |
| `webhook` | [`webhook.sh`](webhook.sh) | Generic JSON POST to any URL. |

## Plugin contract

A plugin is a single Bash file sourced lazily by `common.sh` on the first
call to `send_notification()`. It must define one function:

```bash
# Send an alert. Plugins should swallow errors and return 0 on best-effort
# failures (rate-limited webhook, transient network error, etc.) so the
# failover logic is never blocked on alerting.
#
# Args:
#   $1  alert_type  — one of INFO_FAILOVER, WARN_FAILOVER, CRIT_FAILOVER
#   $2  message     — human-readable message
send_alert() {
    local alert_type="$1"
    local message="$2"
    # ... do the thing ...
}
```

### Configuration variables

The plugin reads its own config from environment variables. Convention is
to prefix them with `ALERT_<BACKEND>_` (e.g. `ALERT_MATTERMOST_WEBHOOK_URL`,
`ALERT_WEBHOOK_URL`). Document them in your plugin's header comment.

### Selection mechanism

`failover.conf` sets:

```bash
ALERTING_BACKEND=mattermost
ALERTING_PLUGIN_DIR=/usr/local/lib/linux-dual-wan-failover/plugins/alerting
# Optional: full path override for custom plugins outside ALERTING_PLUGIN_DIR.
ALERTING_PLUGIN_PATH=
```

`common.sh` resolves the plugin file in this order:

1. `${ALERTING_PLUGIN_PATH}` if set (custom plugins).
2. `${ALERTING_PLUGIN_DIR}/${ALERTING_BACKEND}.sh`.
3. `<repo>/plugins/alerting/${ALERTING_BACKEND}.sh` (dev / tests).

If no file resolves, alerting silently degrades to log-only.

## Writing a custom plugin

```bash
# /etc/linux-dual-wan-failover/plugins/alerting/my-pager.sh
ALERT_PAGER_URL="${ALERT_PAGER_URL:?ALERT_PAGER_URL must be set}"

send_alert() {
    local alert_type="$1"
    local message="$2"
    curl -fsS --max-time 5 \
        -H 'Content-Type: application/json' \
        -d "{\"type\":\"${alert_type}\",\"text\":\"${message}\"}" \
        "$ALERT_PAGER_URL" >/dev/null 2>&1 || true
}
```

Then in `failover.conf`:
```bash
ALERTING_BACKEND=my-pager
ALERTING_PLUGIN_PATH=/etc/linux-dual-wan-failover/plugins/alerting/my-pager.sh
```
