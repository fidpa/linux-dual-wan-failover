#!/usr/bin/env bats

load ../helpers

@test "route guardian log path remains writable during initialization" {
    local guardian="$TEST_REPO_ROOT/src/services/route-guardian.sh"

    run grep -E \
        '^[[:space:]]*readonly LOG_FILE=' \
        "$guardian"

    [ "$status" -eq 1 ]
}
