#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# trace-failover.sh — trace one failover by its Event-ID (Correlation-ID)
#
# Reconstructs the full lifecycle of a SINGLE failover event across all four
# services, tied together by the shared failover Event-ID (PID_TIMESTAMP). This
# answers "why did it happen?": detection (nmcli-failover-monitor) ->
# orchestration (failover-monitor) -> route change (routing.sh) -> protection
# (route-guardian), plus the corresponding metrics-collector event-DB row.
#
# Background: a single correlation ID ties logs, metrics and events together
# across service boundaries — the same idea as a distributed-tracing trace ID.
# The ID is part of the log message text (`FAILOVER_EVENT_ID=<id>`), never a
# separate journal field. Per service, this tool greps the journal first (by the
# unit's SyslogIdentifier) and falls back to the service's log file, then shows
# all hits sorted by time as a "waterfall". The journal is complete whatever
# logger runs: bash-production-toolkit v3, or common.sh's fallback logger
# without the toolkit. The files are written by the toolkit (v2 always, v3 with
# LOG_TO_FILE=true, the project default) and reach back past journal retention.
#
# Usage:
#   trace-failover.sh <event-id>     # a specific ID, e.g. 3741608_1782676271
#   trace-failover.sh --last         # the most recently active Event-ID
#   trace-failover.sh --list [N]     # the last N Event-IDs from the event DB (default 10)
#
# Paths are device-agnostic and overridable via environment variables:
#   LOG_DIR    (default /var/log/linux-dual-wan-failover)
#   STATE_DIR  (default /run/linux-dual-wan-failover/wan-state)
#   EVENTS_DB  (default /var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db)

set -uo pipefail

# Service log files (same file format: [TS] [LEVEL] msg [FIELDS]).
# Up to v0.11.0 nmcli-failover-monitor wrote into failover.log, so its older
# file lines show up as [monitor] when the journal has none.
LOG_DIR="${LOG_DIR:-/var/log/linux-dual-wan-failover}"
STATE_DIR="${STATE_DIR:-/run/linux-dual-wan-failover/wan-state}"
EVENTS_DB="${EVENTS_DB:-/var/lib/linux-dual-wan-failover/failover-metrics-collector/failover-events.db}"

readonly LOG_NMCLI="${LOG_DIR}/nmcli-monitor.log"
readonly LOG_MONITOR="${LOG_DIR}/failover.log"
readonly LOG_GUARDIAN="${LOG_DIR}/route-guardian.log"
readonly LAST_FAILOVER_ID_FILE="${STATE_DIR}/last_failover_id"

usage() {
    # Print the header comment from the title line (after the SPDX block) up to
    # the first blank line following the usage block.
    awk '
        /^# trace-failover\.sh —/ { p=1 }
        p && /^[^#]/ { exit }
        p { sub(/^# ?/, ""); print }
    ' "$0"
    exit "${1:-0}"
}

# Does the event DB have the event_id column (collector with the Correlation-ID
# feature)? While an older collector runs, the column is absent — the tool stays
# usable via log grep.
db_has_event_id() {
    [[ -r "$EVENTS_DB" ]] || return 1
    sqlite3 "file:${EVENTS_DB}?mode=ro" "PRAGMA table_info(failover_events);" 2>/dev/null \
        | grep -q '|event_id|'
}

# List the last N Event-IDs from the event DB ("which ID do I want to trace?").
list_recent_ids() {
    local n="${1:-10}"
    # n is interpolated into the SQL LIMIT clause → force strictly numeric.
    [[ "$n" =~ ^[0-9]+$ ]] || n=10
    if [[ ! -r "$EVENTS_DB" ]]; then
        echo "Event DB not readable: $EVENTS_DB" >&2
        return 1
    fi
    if ! db_has_event_id; then
        echo "The event DB has no event_id column yet (collector without the" >&2
        echo "Correlation-ID feature). After upgrading, the first failover carries" >&2
        echo "an ID. Until then: trace-failover.sh <id> uses the service logs directly." >&2
        return 1
    fi
    echo "Last $n failover events (newest first):"
    echo "TIMESTAMP            | TYPE     | FROM→TO    | EVENT_ID"
    echo "---------------------+----------+------------+-------------------------"
    local query="SELECT timestamp, \
        printf('%-8s', event_type), \
        printf('%-10s', from_interface || '→' || to_interface), \
        COALESCE(event_id, '(no id)') \
        FROM failover_events ORDER BY timestamp DESC LIMIT ${n};"
    sqlite3 -separator ' | ' "file:${EVENTS_DB}?mode=ro" "$query" 2>/dev/null \
        || { echo "Query failed" >&2; return 1; }
}

# Show the DB row for an Event-ID (the "what" / symptom).
show_db_row() {
    local id="$1"
    [[ -r "$EVENTS_DB" ]] || return 0
    echo "═══ Event-DB row (symptom: active interface changed) ═══"
    if ! db_has_event_id; then
        echo "(event DB has no event_id column — older collector; log trace below only)"
        echo ""
        return 0
    fi
    local query="SELECT timestamp, event_type, from_interface, to_interface, \
        primary_score_before, backup_score_before, reason, \
        actual_failover_duration_ms, event_id \
        FROM failover_events WHERE event_id = '${id}' LIMIT 1;"
    local row
    row=$(sqlite3 -line "file:${EVENTS_DB}?mode=ro" "$query" 2>/dev/null)
    if [[ -n "$row" ]]; then
        echo "$row"
    else
        echo "(no DB row with event_id=$id — possibly a pre-feature event or not yet recorded)"
    fi
    echo ""
}

# Event-ID followed by a non-digit or the end of the line, so that 123_45 does
# not also match 123_456. The ID is validated as ^[0-9]+_[0-9]+$ in main().
id_pattern() {
    printf 'FAILOVER_EVENT_ID=%s([^0-9]|$)' "$1"
}

# Journal hits of one service, rewritten to the file format "[YYYY-MM-DD
# HH:MM:SS] msg". short-iso prints "<ISO-TS> <host> <ident>[<pid>]: msg".
# Selected by SyslogIdentifier (-t): the units set it, and -u would also match
# systemd's own messages about the unit. Without read access to the system
# journal (root, or the adm / systemd-journal group) this finds nothing and the
# file fallback takes over.
journal_hits() {
    local ident="$1" id="$2"
    command -v journalctl >/dev/null 2>&1 || return 0
    journalctl -t "$ident" -o short-iso --no-pager -q 2>/dev/null \
        | grep -E "$(id_pattern "$id")" \
        | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})[^ ]* [^ ]+ [^ ]+: /[\1 \2] /'
}

file_hits() {
    local file="$1" id="$2"
    grep -hE "$(id_pattern "$id")" "$file" 2>/dev/null
}

# Grep each service's journal (or, failing that, its log file) for the
# Event-ID, merged by time (the "waterfall").
show_log_waterfall() {
    local id="$1"
    echo "═══ Service-log waterfall (cause: what each service did) ═══"
    echo "Filter: FAILOVER_EVENT_ID=${id} across nmcli-monitor · failover-monitor · route-guardian"

    # One lane per service: tag, SyslogIdentifier, log file. Journal first, so
    # a line written to both is shown once and attributed to the right unit.
    local lanes=(
        "nmcli|nmcli-failover-monitor|${LOG_NMCLI}"
        "monitor|failover-monitor|${LOG_MONITOR}"
        "guardian|route-guardian|${LOG_GUARDIAN}"
    )
    local lane tag ident file hits all="" sources=()
    for lane in "${lanes[@]}"; do
        IFS='|' read -r tag ident file <<< "$lane"
        hits=$(journal_hits "$ident" "$id")
        if [[ -n "$hits" ]]; then
            sources+=("${tag}=journal")
        else
            hits=$(file_hits "$file" "$id")
            [[ -n "$hits" ]] && sources+=("${tag}=${file##*/}")
        fi
        [[ -n "$hits" ]] || continue
        all+="$(sed "s/^/$(printf '%-11s' "[${tag}]")/" <<< "$hits")"$'\n'
    done
    echo "Sources: ${sources[*]:-none}"
    echo ""

    if [[ -z "$all" ]]; then
        echo "No log entries for FAILOVER_EVENT_ID=${id} found."
        echo "Possible reasons: journal and log files rotated, no read access to the"
        echo "system journal (run with sudo), a pre-feature event (no ID), or a typo."
        return 1
    fi
    # Sort by the [TS] after the lane tag (b: the tags differ in padding; -s:
    # same-second lines keep lane order). The format ([YYYY-MM-DD HH:MM:SS]) is
    # the same for journal and file hits, so lexicographic == chronological.
    printf '%s' "$all" | LC_ALL=C sort -s -t']' -k2,2b
}

main() {
    local arg="${1:-}"
    case "$arg" in
        ""|-h|--help) usage 0 ;;
        --list)       list_recent_ids "${2:-10}"; exit $? ;;
        --last)
            if [[ ! -r "$LAST_FAILOVER_ID_FILE" ]]; then
                echo "No active Event-ID ($LAST_FAILOVER_ID_FILE missing — no failover since boot?)" >&2
                exit 1
            fi
            arg="$(cat "$LAST_FAILOVER_ID_FILE" 2>/dev/null)"
            echo "Using last Event-ID: $arg"
            echo ""
            ;;
        --*) echo "Unknown option: $arg" >&2; usage 1 ;;
    esac

    # Format validation (PID_TIMESTAMP). Fatal: an Event-ID always has this
    # format (== lockfile content); a different value is a typo — and would be
    # interpolated unchecked into show_db_row's SQL query.
    if [[ ! "$arg" =~ ^[0-9]+_[0-9]+$ ]]; then
        echo "Error: '$arg' is not a valid Event-ID (expected PID_TIMESTAMP, e.g. 3741608_1782676271)" >&2
        exit 1
    fi

    show_db_row "$arg"
    show_log_waterfall "$arg"
}

main "$@"
