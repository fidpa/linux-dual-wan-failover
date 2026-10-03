#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Tests for route-guardian's alert path: delivery through the alerting plugin,
# per-type rate limit, BOTH_WANS_DOWN, and recovery with downtime. Until
# v0.11.0 route-guardian defined its own send_alert, which shadowed the plugin
# contract: with ALERTING_BACKEND set, one alert became an endless chain of
# calls that delivered nothing, and the route-missing alerts died on an unset
# variable of a private library.

load '../helpers'

setup() {
    setup_test_env
    export ROUTE_GUARDIAN_LIB_MODE=1
    export ROUTE_GUARDIAN_STATE_DIR="$STATE_DIR/route-guardian"
    export DELIVERED="$TMPROOT/delivered"
    # A plugin that records each delivery as "<alert_type>|<first line>".
    cat > "$TMPROOT/record.sh" <<'EOF'
send_alert() {
    printf '%s|%s\n' "$1" "${2%%$'\n'*}" >> "$DELIVERED"
}
EOF
    export ALERTING_BACKEND=record
    export ALERTING_PLUGIN_PATH="$TMPROOT/record.sh"
    # shellcheck source=/dev/null
    source "${SRC_DIR}/services/route-guardian.sh" 2>/dev/null
    # Both default routes present unless a test says otherwise.
    check_route_exists() { return 0; }
}

teardown() {
    teardown_test_env
}

# Call after `wait` in the test itself: `run` is a subshell and could not wait
# for the background deliveries of this shell.
_deliveries() {
    if [[ -f "$DELIVERED" ]]; then
        cat "$DELIVERED"
    fi
}

@test "route-guardian: does not shadow the plugin contract (send_alert)" {
    run bash -c 'export ROUTE_GUARDIAN_LIB_MODE=1; source "$1" 2>/dev/null; declare -F send_alert send_recovery_alert' \
        _ "${SRC_DIR}/services/route-guardian.sh"
    [ -z "$output" ]
}

@test "route-guardian: has sfu_write_file without the toolkit" {
    declare -F sfu_write_file
}

@test "rg_alert: delivers once through the plugin" {
    rg_alert ROUTE_FAILURE "eth0: route add failed" "x"
    wait
    run _deliveries
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "WARN_FAILOVER|Route Guardian ROUTE_FAILURE: eth0: route add failed" ]
}

@test "rg_alert: the same type is not repeated within ALERT_RATE_LIMIT_SECONDS" {
    rg_alert SYSTEM_ERROR "first" "x"
    rg_alert SYSTEM_ERROR "second" "x"
    rg_alert ROUTE_FAILURE "other type" "x"
    wait
    run _deliveries
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[*]}" == *"first"* ]]
    [[ "${lines[*]}" != *"second"* ]]
}

@test "rg_alert: DSL_ROUTE_MISSING is delivered (died on an unset variable before)" {
    rg_alert DSL_ROUTE_MISSING "DSL route needs repair" "x"
    wait
    run _deliveries
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "WARN_FAILOVER|Route Guardian DSL_ROUTE_MISSING:"* ]]
}

@test "rg_alert: both routes missing becomes one critical BOTH_WANS_DOWN" {
    check_route_exists() { return 1; }
    rg_alert DSL_ROUTE_MISSING "DSL route needs repair" "x"
    rg_alert LTE_ROUTE_MISSING "LTE route lost" "x"
    wait
    run _deliveries
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "CRIT_FAILOVER|Route Guardian BOTH_WANS_DOWN:"* ]]
}

@test "rg_recovery_alert: reports the downtime of an open event, once" {
    rg_alert DSL_ROUTE_MISSING "DSL route needs repair" "x"
    rg_recovery_alert DSL_ROUTE_MISSING "DSL route restored" "x"
    rg_recovery_alert DSL_ROUTE_MISSING "DSL route restored" "x"
    wait
    run _deliveries
    [ "${#lines[@]}" -eq 2 ]
    # Both deliveries run in the background; their order is not fixed.
    [[ "$output" == *"INFO_FAILOVER|Route Guardian RECOVERY_DSL_ROUTE_MISSING: DSL route restored"* ]]
}

@test "rg_recovery_alert: a returning route also ends BOTH_WANS_DOWN" {
    check_route_exists() { return 1; }
    rg_alert DSL_ROUTE_MISSING "DSL route needs repair" "x"
    rg_recovery_alert LTE_ROUTE_MISSING "LTE route present again" "x"
    wait
    run _deliveries
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" == *"RECOVERY_BOTH_WANS_DOWN"* ]]
    [ ! -e "$ROUTE_GUARDIAN_STATE_DIR/alerts/events/BOTH_WANS_DOWN.event" ]
}

@test "rg_recovery_alert: nothing is reported without an open event" {
    rg_recovery_alert LTE_ROUTE_MISSING "LTE route present again" "x"
    wait
    run _deliveries
    [ "${#lines[@]}" -eq 0 ]
}
