#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Custom quota-provider template.
#
# Replace the body of get_limit_pct() with your modem/ISP-specific query.
# Output: a percentage as integer or float on stdout, or empty if the upstream
# value is unknown.
#
# Schedule via your own systemd timer; failover-monitor only reads the
# snapshot file at QUOTA_SNAPSHOT_PATH.

set -euo pipefail

QUOTA_SNAPSHOT_PATH="${QUOTA_SNAPSHOT_PATH:-/var/lib/linux-dual-wan-failover/quota-snapshot.json}"
QUOTA_PROVIDER_NAME="${QUOTA_PROVIDER_NAME:-custom}"

# ----------------------------------------------------------------------------
# Replace the body of this function with your upstream query.
# Print a percentage (0–100, integer or float) on stdout. Print nothing if
# the value is unknown — failover-monitor will treat that as "no cap".
#
# Examples:
#   curl -s http://my-modem.local/api/quota | jq -r '.usage_percent'
#   curl -s -u admin:secret https://isp.example/api | jq -r '.data_used_pct'  # gitleaks:allow (placeholder creds)
#   awk '/limit/ {print $2}' /tmp/my-collector-output
# ----------------------------------------------------------------------------
get_limit_pct() {
    # TODO: replace this stub
    echo ""
}

write_snapshot() {
    local pct="$1"
    local pct_field
    if [[ -z "$pct" ]]; then
        pct_field='null'
    else
        pct_field="$pct"
    fi
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    mkdir -p "$(dirname "$QUOTA_SNAPSHOT_PATH")"
    local tmp
    tmp="$(mktemp "${QUOTA_SNAPSHOT_PATH}.XXXXXX")"
    cat > "$tmp" <<EOF
{
  "limit_pct": ${pct_field},
  "collected_at": "${now}",
  "provider": "${QUOTA_PROVIDER_NAME}"
}
EOF
    mv "$tmp" "$QUOTA_SNAPSHOT_PATH"
}

main() {
    local pct
    pct=$(get_limit_pct)
    write_snapshot "$pct"
}

main "$@"
