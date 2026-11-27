#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# failover-monitor cooldowns in perform_failover: manual Web-UI actions wait
# MANUAL_ACTION_COOLDOWN, the automatic failback waits ANTI_FLAPPING_DELAY.
# Sources the daemon in FAILOVER_MONITOR_LIB_MODE; route changes, scores and
# notifications are spies, the monotonic clock is fixed.

load '../helpers'

setup() {
    setup_test_env
    export FAILOVER_MONITOR_LIB_MODE=1
    export PID_FILE="$RUNTIME_DIR/failover-monitor.pid"
    unset MANUAL_ACTION_COOLDOWN ANTI_FLAPPING_DELAY
    # shellcheck source=/dev/null
    source "${SRC_DIR}/services/failover-monitor.sh"
    # The daemon's defaults, before the tests below pin both values.
    DEFAULT_ANTI_FLAPPING_DELAY="$ANTI_FLAPPING_DELAY"
    DEFAULT_MANUAL_ACTION_COOLDOWN="$MANUAL_ACTION_COOLDOWN"

    ROUTE_CHANGES="$TMPROOT/route-changes.log"
    : > "$ROUTE_CHANGES"
    safe_route_change() { echo "$2->$1" >> "$ROUTE_CHANGES"; return 0; }
    send_notification() { :; }
    save_state() { :; }
    get_connection_score() { echo 100; }
    get_monotonic_time() { echo 10000; }
    ANTI_FLAPPING_DELAY=600
    MANUAL_ACTION_COOLDOWN=60
}

teardown() {
    teardown_test_env
}

# Last failover <seconds> ago on the fixed monotonic clock.
failover_ago() { last_failover_mono=$((10000 - $1)); }

@test "defaults: 600 s for the automatic failback, 60 s for manual actions" {
    [ "$DEFAULT_ANTI_FLAPPING_DELAY" -eq 600 ]
    [ "$DEFAULT_MANUAL_ACTION_COOLDOWN" -eq 60 ]
}

@test "manual_failback inside ANTI_FLAPPING_DELAY switches to the primary" {
    current_wan="backup"
    failover_ago 160
    perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "manual_failback"
    [ "$(cat "$ROUTE_CHANGES")" = "${BACKUP_IFACE}->${PRIMARY_IFACE}" ]
    [ "$current_wan" = "primary" ]
}

@test "manual_failover_force inside ANTI_FLAPPING_DELAY switches to the backup" {
    current_wan="primary"
    failover_ago 160
    perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "manual_failover_force"
    [ "$(cat "$ROUTE_CHANGES")" = "${PRIMARY_IFACE}->${BACKUP_IFACE}" ]
    [ "$current_wan" = "backup" ]
}

@test "manual_failback inside MANUAL_ACTION_COOLDOWN is suppressed" {
    current_wan="backup"
    failover_ago 20
    run perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "manual_failback"
    [ "$status" -eq 0 ]
    [ ! -s "$ROUTE_CHANGES" ]
    [[ "$output" == *"manual_failback suppressed by manual-action cooldown (40s remaining of 60s"* ]]
}

@test "manual action without a failover since daemon start is not suppressed" {
    current_wan="backup"
    last_failover_mono=0
    get_monotonic_time() { echo 30; }
    perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "manual_failback"
    [ "$(cat "$ROUTE_CHANGES")" = "${BACKUP_IFACE}->${PRIMARY_IFACE}" ]
}

@test "automatic failback inside ANTI_FLAPPING_DELAY is still suppressed" {
    current_wan="backup"
    failover_ago 160
    run perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "failback"
    [ "$status" -eq 0 ]
    [ ! -s "$ROUTE_CHANGES" ]
    [[ "$output" == *"Failback suppressed by anti-flapping (440s remaining of 600s cooldown"* ]]
}

@test "automatic failback after ANTI_FLAPPING_DELAY switches to the primary" {
    current_wan="backup"
    failover_ago 700
    perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "failback"
    [ "$(cat "$ROUTE_CHANGES")" = "${BACKUP_IFACE}->${PRIMARY_IFACE}" ]
}
