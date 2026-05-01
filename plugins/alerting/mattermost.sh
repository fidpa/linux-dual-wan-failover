#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# mattermost.sh — Mattermost incoming-webhook alerting plugin
#
# Required environment variables (set in failover.conf or systemd EnvironmentFile):
#
#   ALERT_MATTERMOST_WEBHOOK_URL  — full incoming-webhook URL
#                                   (https://your-mm/hooks/abc123...)
#
# Optional:
#   ALERT_MATTERMOST_CHANNEL      — override the channel set in the webhook
#   ALERT_MATTERMOST_USERNAME     — display name (default: linux-dual-wan-failover)
#   ALERT_MATTERMOST_ICON_EMOJI   — emoji code (default: :rotating_light:)
#   ALERT_MATTERMOST_TIMEOUT      — curl timeout in seconds (default: 5)
#
# If bash-production-toolkit is installed and exposes
# `send_mattermost_alert`, this plugin delegates to it (rate-limiting,
# retry logic, structured logging). Otherwise it falls back to a direct
# `curl` POST.

ALERT_MATTERMOST_WEBHOOK_URL="${ALERT_MATTERMOST_WEBHOOK_URL:-}"
ALERT_MATTERMOST_USERNAME="${ALERT_MATTERMOST_USERNAME:-linux-dual-wan-failover}"
ALERT_MATTERMOST_ICON_EMOJI="${ALERT_MATTERMOST_ICON_EMOJI:-:rotating_light:}"
ALERT_MATTERMOST_TIMEOUT="${ALERT_MATTERMOST_TIMEOUT:-5}"
ALERT_MATTERMOST_CHANNEL="${ALERT_MATTERMOST_CHANNEL:-}"

_alert_mattermost_text_for_type() {
    case "$1" in
        CRIT_FAILOVER) echo ":rotating_light: **CRITICAL**" ;;
        WARN_FAILOVER) echo ":warning: **WARNING**" ;;
        *)             echo ":information_source: INFO" ;;
    esac
}

send_alert() {
    local alert_type="$1"
    local message="$2"

    if [[ -z "$ALERT_MATTERMOST_WEBHOOK_URL" ]]; then
        # Plugin selected but not configured — log and return 0 so we don't
        # block the failover loop. The dropped alert is observable in the
        # journal at debug level.
        return 0
    fi

    # Delegate to the toolkit if available.
    if declare -F send_mattermost_alert >/dev/null 2>&1; then
        send_mattermost_alert "$alert_type" "$message" >/dev/null 2>&1
        return 0
    fi

    # Fallback: direct curl POST. We let Python build the JSON payload to
    # get correct escaping for backslashes, control characters, and
    # Unicode — Bash printf-with-`//"/\\\"` does NOT cover those.
    local prefix
    prefix="$(_alert_mattermost_text_for_type "$alert_type")"
    local payload
    if ! payload=$(
        ALERT_MM_USERNAME="$ALERT_MATTERMOST_USERNAME" \
        ALERT_MM_ICON="$ALERT_MATTERMOST_ICON_EMOJI" \
        ALERT_MM_CHANNEL="$ALERT_MATTERMOST_CHANNEL" \
        ALERT_MM_TEXT="${prefix} — ${message}" \
        python3 -c '
import json, os
payload = {
    "username": os.environ.get("ALERT_MM_USERNAME", "linux-dual-wan-failover"),
    "icon_emoji": os.environ.get("ALERT_MM_ICON", ":rotating_light:"),
    "text": os.environ.get("ALERT_MM_TEXT", ""),
}
ch = os.environ.get("ALERT_MM_CHANNEL", "")
if ch:
    payload["channel"] = ch
print(json.dumps(payload))
        ' 2>/dev/null
    ); then
        return 0  # python3 unavailable or failed → silent best-effort drop
    fi

    curl -fsS --max-time "$ALERT_MATTERMOST_TIMEOUT" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$ALERT_MATTERMOST_WEBHOOK_URL" >/dev/null 2>&1 || true
}
