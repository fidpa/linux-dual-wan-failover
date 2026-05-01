#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Sanity tests for the quota provider plugins shipped with the repo.

load '../helpers'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "custom-template: produces a valid snapshot" {
    local template="${TEST_REPO_ROOT}/plugins/quota-providers/custom-template/collect-quota.sh"
    [ -x "$template" ] || skip "custom-template/collect-quota.sh not executable"

    QUOTA_SNAPSHOT_PATH="$STATE_DIR/snap.json"
    run "$template"
    [ "$status" -eq 0 ]
    [ -f "$QUOTA_SNAPSHOT_PATH" ]

    # Required fields present
    run grep -q '"limit_pct"' "$QUOTA_SNAPSHOT_PATH"
    [ "$status" -eq 0 ]
    run grep -q '"collected_at"' "$QUOTA_SNAPSHOT_PATH"
    [ "$status" -eq 0 ]
    run grep -q '"provider"' "$QUOTA_SNAPSHOT_PATH"
    [ "$status" -eq 0 ]

    # Default get_limit_pct() returns nothing → limit_pct must be null
    run grep -q '"limit_pct": null' "$QUOTA_SNAPSHOT_PATH"
    [ "$status" -eq 0 ]
}

@test "schema file is valid JSON" {
    local schema="${TEST_REPO_ROOT}/plugins/quota-providers/_schema/quota-snapshot.schema.json"
    [ -f "$schema" ]
    if command -v python3 >/dev/null 2>&1; then
        run python3 -c "import json; json.load(open('$schema'))"
        [ "$status" -eq 0 ]
    else
        skip "python3 not available for schema validation"
    fi
}
