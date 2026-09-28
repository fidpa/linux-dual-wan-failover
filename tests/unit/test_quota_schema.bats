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
    # Run through bash rather than requiring +x: the template ships 0644 on
    # purpose (users copy it before scheduling it), so an executable check
    # skipped this test on every run, CI included.
    local template="${TEST_REPO_ROOT}/plugins/quota-providers/custom-template/collect-quota.sh"
    [ -f "$template" ]

    QUOTA_SNAPSHOT_PATH="$STATE_DIR/snap.json"
    run bash "$template"
    [ "$status" -eq 0 ]
    [ -f "$QUOTA_SNAPSHOT_PATH" ]
    # Written via mktemp + mv: no temp file may be left beside the snapshot.
    [ "$(find "$STATE_DIR" -name 'snap.json.*' | wc -l)" -eq 0 ]

    # Parse it as JSON rather than grepping: the daemon and quota-hard-block.sh
    # read it with a JSON parser, so a syntax error would slip past grep.
    # Default get_limit_pct() returns nothing → limit_pct must be null.
    python3 - "$QUOTA_SNAPSHOT_PATH" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d["limit_pct"] is None, d["limit_pct"]
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["collected_at"]), d["collected_at"]
assert d["provider"] == "custom", d["provider"]
PY
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
