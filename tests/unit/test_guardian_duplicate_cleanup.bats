#!/usr/bin/env bats

load ../helpers

@test "guardian retains WAN-state-aware default route metrics" {
    run bash \
        "$TEST_REPO_ROOT/tests/unit/guardian_duplicate_cleanup_check.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"9/9 tests passed"* ]]
}
