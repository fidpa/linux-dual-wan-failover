#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Tests for src/services/quota-hard-block.sh: block, lift, fail-closed on
# stale data, new-cycle detection, reconcile, idempotency, input validation.
#
# nft is a fake that records every call and models "table exists" with a
# marker file. The script runs in its own bash with send_notification
# replaced by a spy, so alert levels can be asserted.

load '../helpers'

setup() {
    setup_test_env
    SCRIPT="${SRC_DIR}/services/quota-hard-block.sh"
    export FAILOVER_CONF="$TMPROOT/no-such-failover.conf"
    export QUOTA_PROVIDER=netgear-lm1200
    export QUOTA_HARD_BLOCK=true
    export QUOTA_HARD_BLOCK_ALLOW="192.168.0.0/24"
    export BLOCK_FILE="$QUOTA_HARD_BLOCK_STATE_DIR/quota-block.nft"

    export NFT_BIN="$TMPROOT/nft"
    export NFT_TABLE_MARKER="$TMPROOT/nft-table-present"
    export NFT_CALLS="$TMPROOT/nft-calls.log"
    export ALERTS="$TMPROOT/alerts.log"
    : > "$NFT_CALLS"
    : > "$ALERTS"
    cat > "$NFT_BIN" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$NFT_CALLS"
case "$*" in
    "list table inet ldwf_quota_block")   [[ -f "$NFT_TABLE_MARKER" ]] ;;
    "delete table inet ldwf_quota_block") rm -f "$NFT_TABLE_MARKER" ;;
    -f\ *)                                touch "$NFT_TABLE_MARKER" ;;
    *)                                    exit 1 ;;
esac
EOF
    chmod +x "$NFT_BIN"
}

teardown() {
    teardown_test_env
}

# snapshot <pct> [days_left] [age_seconds]
snapshot() {
    local pct="$1" days="${2:-}" age="${3:-0}" extra=""
    [[ -n "$days" ]] && extra=", \"billing_cycle_days_left\": ${days}"
    printf '{"limit_pct": %s, "collected_at": "2026-09-23T00:00:00Z"%s}\n' "$pct" "$extra" \
        > "$QUOTA_SNAPSHOT_PATH"
    if [[ $age -gt 0 ]]; then
        touch -d "@$(($(date +%s) - age))" "$QUOTA_SNAPSHOT_PATH"
    fi
}

enforce() {
    run bash -c 'source "$1"; send_notification() { echo "$2" >> "$ALERTS"; }; main' _ "$SCRIPT"
}

@test "script is executable" {
    [ -x "$SCRIPT" ]
}

@test ">= threshold: writes a regular state file, loads the table, one critical alert" {
    snapshot 100.65 7
    enforce
    [ "$status" -eq 0 ]
    [ -f "$BLOCK_FILE" ] && [ ! -L "$BLOCK_FILE" ]
    [ -f "$NFT_TABLE_MARKER" ]
    [ "$(cat "$ALERTS")" = "critical" ]
}

@test "generated rules: backup iface, allow list, DHCP broadcast, idempotent flush" {
    snapshot 99 7
    enforce
    grep -q 'flush table inet ldwf_quota_block' "$BLOCK_FILE"
    grep -q 'oifname "lte0" ip daddr != { 255.255.255.255, 192.168.0.0/24 } counter drop' "$BLOCK_FILE"
    grep -q 'oifname "lte0" meta nfproto ipv6 counter drop' "$BLOCK_FILE"
    grep -q 'hook forward' "$BLOCK_FILE"
}

@test "second run while blocked: no nft -f, no alert" {
    snapshot 100.65 7
    enforce
    : > "$NFT_CALLS"; : > "$ALERTS"
    enforce
    [ "$status" -eq 0 ]
    run grep -q '^-f ' "$NFT_CALLS"
    [ "$status" -ne 0 ]
    [ ! -s "$ALERTS" ]
}

@test "table vanished (ruleset reload without include): re-applied silently" {
    snapshot 100.65 7
    enforce
    rm -f "$NFT_TABLE_MARKER"; : > "$ALERTS"
    enforce
    [ -f "$NFT_TABLE_MARKER" ]
    [ ! -s "$ALERTS" ]
}

@test "below threshold, fresh, counter > 0: lifted with info alert" {
    snapshot 100.65 7
    enforce
    : > "$ALERTS"
    snapshot 0.1 30
    enforce
    [ ! -f "$BLOCK_FILE" ]
    [ ! -f "$NFT_TABLE_MARKER" ]
    [ "$(cat "$ALERTS")" = "info" ]
}

@test "below threshold but stale snapshot: block stays (fail-closed)" {
    snapshot 100.65 7
    enforce
    snapshot 0.1 30 7200
    enforce
    [ -f "$BLOCK_FILE" ]
}

@test "counter 0 without new cycle (modem glitch): block stays" {
    snapshot 100.65 7
    enforce
    snapshot 0 7
    enforce
    [ -f "$BLOCK_FILE" ]
}

@test "counter 0 with rising days-left (reset, no keepalive traffic): lifted" {
    snapshot 100.65 1
    enforce
    snapshot 0 31
    enforce
    [ ! -f "$BLOCK_FILE" ]
}

@test "counter 0 from a provider without days-left: lifted on a fresh reading" {
    snapshot 100.65
    enforce
    snapshot 0
    enforce
    [ ! -f "$BLOCK_FILE" ]
}

@test "new cycle but counter still over threshold: stays blocked, warning" {
    snapshot 100.65 1
    enforce
    : > "$ALERTS"
    snapshot 100.7 31
    enforce
    [ -f "$BLOCK_FILE" ]
    [ "$(cat "$ALERTS")" = "warning" ]
}

@test "missing snapshot or limit_pct=null: state unchanged" {
    snapshot 100.65 7
    enforce
    rm -f "$QUOTA_SNAPSHOT_PATH"
    enforce
    [ -f "$BLOCK_FILE" ]
    snapshot null 7
    enforce
    [ -f "$BLOCK_FILE" ]
}

@test "QUOTA_HARD_BLOCK=false: lifts a leftover block, never blocks" {
    snapshot 100.65 7
    enforce
    export QUOTA_HARD_BLOCK=false
    enforce
    [ ! -f "$BLOCK_FILE" ]
    [ ! -f "$NFT_TABLE_MARKER" ]
    : > "$NFT_CALLS"
    enforce
    run grep -q '^-f ' "$NFT_CALLS"
    [ "$status" -ne 0 ]
}

@test "QUOTA_PROVIDER=none: nothing to base a block on, no nft mutation" {
    export QUOTA_PROVIDER=none
    snapshot 100.65 7
    enforce
    [ ! -f "$BLOCK_FILE" ]
    run grep -qE '^(-f |delete)' "$NFT_CALLS"
    [ "$status" -ne 0 ]
}

@test "threshold comes from QUOTA_HARD_BLOCK_PCT; invalid value falls back to 99" {
    export QUOTA_HARD_BLOCK_PCT=90
    snapshot 95 7
    enforce
    [ -f "$BLOCK_FILE" ]

    rm -rf "$QUOTA_HARD_BLOCK_STATE_DIR" "$NFT_TABLE_MARKER"
    export QUOTA_HARD_BLOCK_PCT=abc
    snapshot 98.9 7
    enforce
    [ ! -f "$BLOCK_FILE" ]
    snapshot 99 7
    enforce
    [ -f "$BLOCK_FILE" ]
}

@test "invalid allow entry is rejected before anything reaches nft" {
    export QUOTA_HARD_BLOCK_ALLOW="192.168.0.0/24 }; flush ruleset; {"
    snapshot 100.65 7
    enforce
    [ "$status" -eq 0 ]
    run grep -q '^-f ' "$NFT_CALLS"
    [ "$status" -ne 0 ]
    [ "$(cat "$ALERTS")" = "critical" ]
}

@test "invalid BACKUP_IFACE is rejected" {
    export BACKUP_IFACE='lte0" drop; #'
    snapshot 100.65 7
    enforce
    run grep -q '^-f ' "$NFT_CALLS"
    [ "$status" -ne 0 ]
}
