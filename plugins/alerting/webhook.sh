#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# webhook.sh — generic JSON-webhook alerting plugin
#
# Required environment variables:
#
#   ALERT_WEBHOOK_URL — full URL to POST alert payloads to
#
# Optional:
#   ALERT_WEBHOOK_AUTH_HEADER — extra header (e.g. "Authorization: Bearer XXX")
#   ALERT_WEBHOOK_TIMEOUT     — curl timeout in seconds (default: 5)
#
# Payload format (JSON):
#   {
#     "alert_type": "CRIT_FAILOVER" | "WARN_FAILOVER" | "INFO_FAILOVER",
#     "message":    "...",
#     "host":       "$(hostname)",
#     "service":    "linux-dual-wan-failover",
#     "timestamp":  "ISO-8601 UTC"
#   }

ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_WEBHOOK_AUTH_HEADER="${ALERT_WEBHOOK_AUTH_HEADER:-}"
ALERT_WEBHOOK_TIMEOUT="${ALERT_WEBHOOK_TIMEOUT:-5}"

send_alert() {
    local alert_type="$1"
    local message="$2"

    if [[ -z "$ALERT_WEBHOOK_URL" ]]; then
        return 0
    fi

    local now host
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    host=$(hostname)

    # Build JSON via Python to get correct escaping for backslashes,
    # control characters, and Unicode (Bash printf cannot do this safely).
    local payload
    if ! payload=$(
        ALERT_WH_TYPE="$alert_type" \
        ALERT_WH_MESSAGE="$message" \
        ALERT_WH_HOST="$host" \
        ALERT_WH_TIMESTAMP="$now" \
        python3 -c '
import json, os
print(json.dumps({
    "alert_type": os.environ.get("ALERT_WH_TYPE", ""),
    "message":    os.environ.get("ALERT_WH_MESSAGE", ""),
    "host":       os.environ.get("ALERT_WH_HOST", ""),
    "service":    "linux-dual-wan-failover",
    "timestamp":  os.environ.get("ALERT_WH_TIMESTAMP", ""),
}))
        ' 2>/dev/null
    ); then
        return 0  # python3 unavailable → silent best-effort drop
    fi

    local curl_args=(-fsS --max-time "$ALERT_WEBHOOK_TIMEOUT" -H 'Content-Type: application/json')
    if [[ -n "$ALERT_WEBHOOK_AUTH_HEADER" ]]; then
        curl_args+=(-H "$ALERT_WEBHOOK_AUTH_HEADER")
    fi
    curl_args+=(-d "$payload" "$ALERT_WEBHOOK_URL")

    curl "${curl_args[@]}" >/dev/null 2>&1 || true
}
