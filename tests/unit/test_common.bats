#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Tests for the common.sh utility functions.

load '../helpers'

setup() {
    setup_test_env
    # shellcheck source=/dev/null
    source "${SRC_DIR}/lib/common.sh"
}

teardown() {
    teardown_test_env
}

@test "is_numeric: accepts integers" {
    run is_numeric "123"
    [ "$status" -eq 0 ]
}

@test "is_numeric: accepts floats" {
    run is_numeric "12.34"
    [ "$status" -eq 0 ]
}

@test "is_numeric: rejects non-numeric" {
    run is_numeric "abc"
    [ "$status" -ne 0 ]
}

@test "is_numeric: rejects empty" {
    run is_numeric ""
    [ "$status" -ne 0 ]
}

@test "get_timestamp: returns a positive integer" {
    run get_timestamp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -gt 0 ]
}

@test "get_monotonic_time: returns a non-negative number" {
    run get_monotonic_time
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9.]+$ ]]
}

@test "send_notification: returns 0 when ALERTING_BACKEND=none (default)" {
    ALERTING_BACKEND=none
    run send_notification "test message" "info"
    [ "$status" -eq 0 ]
}

@test "send_notification: returns 0 (best-effort) when alerting plugin is missing" {
    ALERTING_BACKEND=does-not-exist
    ALERTING_PLUGIN_DIR="$TMPROOT/no-such-plugin-dir"
    run send_notification "test message" "info"
    [ "$status" -eq 0 ]
}

@test "send_notification: rejects empty message" {
    run send_notification "" "info"
    [ "$status" -ne 0 ]
}
