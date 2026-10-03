#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# common.sh against a real bash-production-toolkit. Every other test runs the
# in-tree fallback logger (helpers.bash unsets TOOLKIT_LIB), so nothing noticed
# when toolkit v3.0.0 moved console output to stderr and stopped writing
# LOG_FILE unless LOG_TO_FILE=true. The expectations here are v3 semantics.
#
# Point TOOLKIT_TEST_LIB at a toolkit's src/foundation directory to run them;
# without it they are skipped. CI fetches a pinned release (see ci.yml):
#
#   TOOLKIT_TEST_LIB=/path/to/bash-production-toolkit-3.0.0/src/foundation \
#       bats tests/unit/test_toolkit_logging.bats

load '../helpers'

setup() {
    [[ -n "${TOOLKIT_TEST_LIB:-}" ]] \
        || skip "TOOLKIT_TEST_LIB not set (path to bash-production-toolkit/src/foundation)"
    setup_test_env
    export TOOLKIT_LIB="$TOOLKIT_TEST_LIB"
    # helpers.bash turns console output off; with v3 that alone makes a
    # terminal run write LOG_FILE, which would hide a missing LOG_TO_FILE.
    # true is also what the units see (under systemd v3 ignores it).
    export LOG_TO_STDOUT=true
    # bats' stderr is never the journal, even inside a systemd-run session.
    unset JOURNAL_STREAM
}

teardown() {
    if [[ -n "${TMPROOT:-}" ]]; then
        teardown_test_env
    fi
}

# Run a snippet in a fresh shell after sourcing common.sh; stdout and stderr
# land in separate files under TMPROOT.
_with_common() {
    bash -c 'source "$1/lib/common.sh" && eval "$2"' _ "$SRC_DIR" "$1" \
        >"$TMPROOT/stdout" 2>"$TMPROOT/stderr"
}

@test "toolkit: TOOLKIT_TEST_LIB points at a logging.sh" {
    [ -f "${TOOLKIT_TEST_LIB}/logging.sh" ]
}

@test "toolkit: common.sh loads the toolkit, not the fallback logger" {
    _with_common 'echo "$TOOLKIT_LIB"; type -t log_structured'
    [ "$(sed -n 1p "$TMPROOT/stdout")" = "$TOOLKIT_TEST_LIB" ]
    [ "$(sed -n 2p "$TMPROOT/stdout")" = "function" ]
}

@test "toolkit: log calls keep stdout clean, lines go to stderr" {
    _with_common 'log_info probe-info; log_warning probe-warn; log_error probe-err
                  log_info_structured probe-struct K=V
                  v=$(get_timestamp; log_info inside-capture); printf "%s" "${v//[0-9]/}"'
    [ ! -s "$TMPROOT/stdout" ]
    grep -q '\[INFO\] probe-info' "$TMPROOT/stderr"
    grep -q '\[WARNING\] probe-warn' "$TMPROOT/stderr"
    grep -q '\[ERROR\] probe-err' "$TMPROOT/stderr"
    grep -q '\[INFO\] inside-capture' "$TMPROOT/stderr"
}

@test "toolkit: LOG_FILE is written by default (project sets LOG_TO_FILE=true)" {
    _with_common 'log_info_structured "route changed" "FAILOVER_EVENT_ID=123_456"'
    grep -q 'route changed.*FAILOVER_EVENT_ID=123_456' "$LOG_FILE"
}

@test "toolkit: LOG_TO_FILE=false keeps the journal only" {
    LOG_TO_FILE=false _with_common 'log_info no-file'
    [ ! -e "$LOG_FILE" ]
    grep -q '\[INFO\] no-file' "$TMPROOT/stderr"
}

@test "toolkit: sourcing sets no EXIT trap" {
    _with_common 'trap -p EXIT'
    [ ! -s "$TMPROOT/stdout" ]
}

@test "toolkit: trace-failover.sh finds an Event-ID the toolkit wrote" {
    LOG_FILE="$LOG_DIR/failover.log" \
        _with_common 'log_info_structured "switching to backup" "FAILOVER_EVENT_ID=4242_1700000000"'
    # No journal in this test: a journalctl that finds nothing.
    mkdir -p "$TMPROOT/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMPROOT/bin/journalctl"
    chmod +x "$TMPROOT/bin/journalctl"
    PATH="$TMPROOT/bin:$PATH" EVENTS_DB="$TMPROOT/none.db" \
        run bash "${SRC_DIR}/tools/trace-failover.sh" 4242_1700000000
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sources: monitor=failover.log"* ]]
    [[ "$output" == *"[monitor]"*"switching to backup"* ]]
}
