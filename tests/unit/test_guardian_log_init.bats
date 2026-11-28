#!/usr/bin/env bats

load ../helpers

@test "route guardian log path remains writable during initialization" {
    local guardian="$TEST_REPO_ROOT/src/services/route-guardian.sh"

    run grep -E \
        '^[[:space:]]*readonly LOG_FILE=' \
        "$guardian"

    [ "$status" -eq 1 ]
}


@test "guardian default LOG_FILE remains assignable" {
    run bash -c '
        unset LOG_FILE

        block=$(sed -n \
            "/^if \[\[ -z .*LOG_FILE/,/^fi$/p" "$1")

        [[ -n "$block" ]] || exit 1

        eval "$block"

        [[ -n "${LOG_FILE:-}" ]] || exit 1

        LOG_FILE="/tmp/guardian-test.log"
        [[ "$LOG_FILE" == "/tmp/guardian-test.log" ]]
    ' _ "$TEST_REPO_ROOT/src/services/route-guardian.sh"

    [ "$status" -eq 0 ]
}

@test "guardian preserves caller supplied LOG_FILE" {
    run bash -c '
        LOG_FILE="/tmp/custom-guardian.log"

        block=$(sed -n \
            "/^if \[\[ -z .*LOG_FILE/,/^fi$/p" "$1")

        [[ -n "$block" ]] || exit 1

        eval "$block"

        [[ "$LOG_FILE" == "/tmp/custom-guardian.log" ]]
    ' _ "$TEST_REPO_ROOT/src/services/route-guardian.sh"

    [ "$status" -eq 0 ]
}
