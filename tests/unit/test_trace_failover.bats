#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Tests for src/tools/trace-failover.sh: journal lanes, file fallback, and the
# Event-ID match. journalctl is replaced by a stub that prints a fixture file
# per SyslogIdentifier, in `journalctl -o short-iso` format.

load '../helpers'

ID="3741608_1782676271"

setup() {
    setup_test_env
    export EVENTS_DB="$TMPROOT/none.db"
    export JOURNAL_FIXTURES="$TMPROOT/journal"
    mkdir -p "$JOURNAL_FIXTURES" "$TMPROOT/bin"
    cat > "$TMPROOT/bin/journalctl" <<'EOF'
#!/bin/bash
ident=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "-t" ]] && { ident="$2"; shift; }
    shift
done
[[ -f "$JOURNAL_FIXTURES/$ident" ]] && cat "$JOURNAL_FIXTURES/$ident"
exit 0
EOF
    chmod +x "$TMPROOT/bin/journalctl"
    export PATH="$TMPROOT/bin:$PATH"
}

teardown() {
    teardown_test_env
}

_trace() {
    run bash "${SRC_DIR}/tools/trace-failover.sh" "$@"
}

@test "trace: journal lanes are attributed by SyslogIdentifier and sorted by time" {
    cat > "$JOURNAL_FIXTURES/failover-monitor" <<EOF
2026-06-28T10:31:12+0200 router failover-monitor[812]: [INFO] switching to backup [FAILOVER_EVENT_ID=$ID]
EOF
    cat > "$JOURNAL_FIXTURES/nmcli-failover-monitor" <<EOF
2026-06-28T10:31:11+0200 router nmcli-failover-monitor[640]: [WARNING] link down on eth0 [FAILOVER_EVENT_ID=$ID]
EOF
    cat > "$JOURNAL_FIXTURES/route-guardian" <<EOF
2026-06-28T10:31:14+0200 router route-guardian[701]: [INFO] [FAILOVER] Failover in progress [FAILOVER_EVENT_ID=$ID]
EOF
    _trace "$ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sources: nmcli=journal monitor=journal guardian=journal"* ]]
    local body
    body=$(grep '^\[' <<< "$output" | grep -v '^\[.*Event-DB')
    [ "$(sed -n 1p <<< "$body")" = "[nmcli]    [2026-06-28 10:31:11] [WARNING] link down on eth0 [FAILOVER_EVENT_ID=$ID]" ]
    [[ "$(sed -n 2p <<< "$body")" == "[monitor]  [2026-06-28 10:31:12]"* ]]
    [[ "$(sed -n 3p <<< "$body")" == "[guardian] [2026-06-28 10:31:14]"* ]]
}

@test "trace: an Event-ID does not match a longer one with the same prefix" {
    cat > "$JOURNAL_FIXTURES/failover-monitor" <<EOF
2026-06-28T10:31:12+0200 router failover-monitor[812]: [INFO] other event [FAILOVER_EVENT_ID=${ID}9]
EOF
    _trace "$ID"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No log entries"* ]]
}

@test "trace: falls back to the log file when the journal has no hit" {
    cat > "$LOG_DIR/failover.log" <<EOF
[2026-06-28 10:31:12] [INFO] switching to backup [FAILOVER_EVENT_ID=$ID]
EOF
    cat > "$LOG_DIR/route-guardian.log" <<EOF
[2026-06-28 10:31:14] [INFO] [FAILOVER] Failover in progress [FAILOVER_EVENT_ID=$ID]
EOF
    _trace "$ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sources: monitor=failover.log guardian=route-guardian.log"* ]]
    [[ "$output" == *"[monitor]  [2026-06-28 10:31:12] [INFO] switching to backup"* ]]
}

@test "trace: the journal wins over the file for the same service" {
    cat > "$JOURNAL_FIXTURES/failover-monitor" <<EOF
2026-06-28T10:31:12+0200 router failover-monitor[812]: [INFO] switching to backup [FAILOVER_EVENT_ID=$ID]
EOF
    cat > "$LOG_DIR/failover.log" <<EOF
[2026-06-28 10:31:12] [INFO] switching to backup [FAILOVER_EVENT_ID=$ID]
EOF
    _trace "$ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sources: monitor=journal"* ]]
    [ "$(grep -c 'switching to backup' <<< "$output")" -eq 1 ]
}

@test "trace: rejects a malformed Event-ID" {
    _trace "1; DROP TABLE x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a valid Event-ID"* ]]
}
