#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Tests for the backup-link quota cap functions in performance.sh.
# These functions are the public API consumed by `failover-monitor`'s
# scoring loop, so the contract here matters for plugin authors.

load '../helpers'

setup() {
    setup_test_env
    # shellcheck source=/dev/null
    source "${SRC_DIR}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${SRC_DIR}/lib/performance.sh"
}

teardown() {
    teardown_test_env
}

@test "quota cap: returns nothing when QUOTA_PROVIDER=none" {
    QUOTA_PROVIDER=none
    make_quota_snapshot 99
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "quota cap: returns nothing when snapshot file is missing" {
    QUOTA_PROVIDER=netgear-lm1200
    rm -f "$QUOTA_SNAPSHOT_PATH"
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "quota cap: tier 90 (87% → no cap)" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot 87
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "quota cap: tier 90 (90% → cap 40)" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot 90
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ "$output" = "40" ]
}

@test "quota cap: tier 96 (96% → cap 10)" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot 96
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

@test "quota cap: tier 100 (100% → cap 0)" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot 100
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "quota cap: tier 100 (105% → cap 0, supports overage)" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot 105
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "quota cap: limit_pct=null → no cap" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot null
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "quota cap: stale snapshot → cap is ignored" {
    QUOTA_PROVIDER=netgear-lm1200
    QUOTA_SNAPSHOT_MAX_STALE_SEC=60
    make_quota_snapshot 99 7200    # 2-hour-old snapshot
    run _backup_quota_cap
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "quota exhausted: 100% → 0 (true)" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot 100
    run _backup_quota_exhausted
    [ "$status" -eq 0 ]
}

@test "quota exhausted: 99% → 1 (false)" {
    QUOTA_PROVIDER=netgear-lm1200
    make_quota_snapshot 99
    run _backup_quota_exhausted
    [ "$status" -eq 1 ]
}

@test "quota exhausted: missing snapshot → 1 (false; conservative)" {
    QUOTA_PROVIDER=netgear-lm1200
    rm -f "$QUOTA_SNAPSHOT_PATH"
    run _backup_quota_exhausted
    [ "$status" -eq 1 ]
}
