#!/usr/bin/env bats

load ../helpers

@test "config defaults are compatible with systemd EnvironmentFile" {
    local config="$TEST_REPO_ROOT/config/failover.conf.example"

    grep -Fx 'DNS_TEST_METHOD=doh' "$config"
    grep -Fx 'LOG_DIR=/var/log/linux-dual-wan-failover' "$config"
    grep -Fx 'STATE_DIR=/var/lib/linux-dual-wan-failover' "$config"
    grep -Fx 'RUNTIME_DIR=/run/linux-dual-wan-failover' "$config"
}

@test "config contains no shell substitutions in default paths" {
    local config="$TEST_REPO_ROOT/config/failover.conf.example"

    run grep -E '^(DNS_TEST_METHOD|LOG_DIR|STATE_DIR|RUNTIME_DIR)=.*\$\{' "$config"

    [ "$status" -eq 1 ]
}


@test "numeric and boolean defaults contain no inline comments" {
    run grep -E \
        '^[A-Z_][A-Z0-9_]*=([0-9]+|true|false)[[:space:]]+#' \
        "$TEST_REPO_ROOT/config/failover.conf.example"

    [ "$status" -eq 1 ]
}
