#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# failover-monitor under an active quota hard block: the perform_failover
# gate, the carrier pre-check and the immediate failback. Sources the daemon
# in FAILOVER_MONITOR_LIB_MODE; route changes, scores and notifications are
# spies, carrier values come from a fixture instead of /sys/class/net.

load '../helpers'

setup() {
    setup_test_env
    export FAILOVER_MONITOR_LIB_MODE=1
    export PID_FILE="$RUNTIME_DIR/failover-monitor.pid"
    export SYS_CLASS_NET="$TMPROOT/sys-class-net"
    # shellcheck source=/dev/null
    source "${SRC_DIR}/services/failover-monitor.sh"

    ROUTE_CHANGES="$TMPROOT/route-changes.log"
    : > "$ROUTE_CHANGES"
    safe_route_change() { echo "$2->$1" >> "$ROUTE_CHANGES"; return 0; }
    send_notification() { :; }
    save_state() { :; }
    get_connection_score() { echo 50; }
    last_failover_mono=0
}

teardown() {
    teardown_test_env
}

block_quota()   { mkdir -p "$QUOTA_HARD_BLOCK_STATE_DIR"; : > "$QUOTA_HARD_BLOCK_STATE_DIR/quota-block.nft"; }
unblock_quota() { rm -f "$QUOTA_HARD_BLOCK_STATE_DIR/quota-block.nft"; }

set_carrier() {
    mkdir -p "$SYS_CLASS_NET/$1"
    echo "$2" > "$SYS_CLASS_NET/$1/carrier"
}

@test "gate: no switch to the backup while blocked, state untouched" {
    block_quota
    current_wan="primary"
    perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "manual_failover_force"
    [ ! -s "$ROUTE_CHANGES" ]
    [ "$current_wan" = "primary" ]
}

@test "gate: switching back to the primary is not affected" {
    block_quota
    current_wan="backup"
    perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "quota_block_failback"
    [ "$(cat "$ROUTE_CHANGES")" = "${BACKUP_IFACE}->${PRIMARY_IFACE}" ]
    [ "$current_wan" = "primary" ]
}

@test "gate: failover to the backup works when not blocked" {
    unblock_quota
    current_wan="primary"
    perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "score_based"
    [ "$(cat "$ROUTE_CHANGES")" = "${PRIMARY_IFACE}->${BACKUP_IFACE}" ]
}

@test "on the backup while blocked: immediate failback when the primary has carrier" {
    block_quota
    set_carrier "$PRIMARY_IFACE" 1
    current_wan="backup"
    check_failover_conditions
    [ "$(cat "$ROUTE_CHANGES")" = "${BACKUP_IFACE}->${PRIMARY_IFACE}" ]
}

@test "on the backup while blocked: no route change when the primary has no carrier" {
    block_quota
    set_carrier "$PRIMARY_IFACE" 0
    current_wan="backup"
    check_failover_conditions
    [ ! -s "$ROUTE_CHANGES" ]
}

@test "carrier pre-check: no failover while blocked (backup score > 0)" {
    block_quota
    set_carrier "$PRIMARY_IFACE" 0
    set_carrier "$BACKUP_IFACE" 1
    current_wan="primary"
    get_connection_score() { [[ "$1" == "$BACKUP_IFACE" ]] && echo 10 || echo 0; }
    check_failover_conditions
    [ ! -s "$ROUTE_CHANGES" ]
}

@test "carrier pre-check: still fails over when not blocked" {
    unblock_quota
    set_carrier "$PRIMARY_IFACE" 0
    set_carrier "$BACKUP_IFACE" 1
    current_wan="primary"
    get_connection_score() { [[ "$1" == "$BACKUP_IFACE" ]] && echo 10 || echo 0; }
    check_failover_conditions
    [ "$(cat "$ROUTE_CHANGES")" = "${PRIMARY_IFACE}->${BACKUP_IFACE}" ]
}

@test "last-resort path is gone" {
    run declare -F is_last_resort_failover_needed
    [ "$status" -ne 0 ]
}
