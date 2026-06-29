#!/bin/bash
# event-id.sh — Failover Event-ID (Correlation-ID) helper
#
# A single ID per failover event that travels through all four services
# (nmcli-failover-monitor -> failover-monitor -> routing.sh -> route-guardian)
# and the metrics collector's event database. This lets you reconstruct one
# failover end-to-end — analogous to a distributed-tracing trace ID — instead
# of manually correlating per-service logs by timestamp.
#
# Format: PID_TIMESTAMP, identical to the lockfile format in routing.sh, so the
# lockfile content IS the event ID and route-guardian's stale-detection still
# parses it.
#
# Handoff model:
#   - nmcli-failover-monitor mints the ID on link-down and writes it to
#     pending_failover_id BEFORE sending kill -USR1 (signal-safe: no I/O in the
#     receiver's USR1 trap).
#   - failover-monitor adopts a fresh pending_failover_id in its main loop
#     (failover_event_id_adopt_pending), or mints its own for health-check /
#     failback / manual failovers; passes it to routing.sh.
#   - routing.sh / failover-monitor publish the ID to last_failover_id (survives
#     the lockfile release window so the 5s collector poll can still read it).
#
# The structured logs carry it as FAILOVER_EVENT_ID=<id>; the collector writes it
# to the failover_events.event_id column. Reconstruct a failover with:
#   tools/trace-failover.sh <id>
#
# This file is meant to be sourced, not executed. All operations are best-effort
# (|| true): a missing /run path or write error must NEVER block a failover.
# Deliberately has no dependency on logging.sh (usable close to signal paths).

# State directory (caller may set STATE_DIR; default matches common.sh).
: "${FAILOVER_EVENT_STATE_DIR:=${STATE_DIR:-/run/wan-state}}"

# Global, NOT readonly (changes per event).
FAILOVER_EVENT_ID="${FAILOVER_EVENT_ID:-}"

# Max age (seconds) of a pending_failover_id before it is treated as orphaned
# and ignored (nmcli detection -> failover-monitor processing is sub-second in
# practice; a generous window covers USR1 re-checks).
#
# IMPORTANT — must stay < ANTI_FLAPPING_DELAY_INSTANT (60s in failover.conf):
# when an instant_event is suppressed by anti-flapping (return 0 BEFORE
# adopt_pending), its pending file lingers. The 60>45 margin (15s) guarantees it
# has expired before the instant cooldown allows the next failover, so a later
# score_based failover does not accidentally adopt the ID of an instant_event
# that never ran. Preserve this invariant when tuning either value.
#
# Guard against double-sourcing (a readonly re-assignment would be an error).
if [[ -z "${FAILOVER_EVENT_ID_PENDING_MAX_AGE:-}" ]]; then
    readonly FAILOVER_EVENT_ID_PENDING_MAX_AGE=45
fi

# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

# Best-effort atomic write: secure-file-utils if available, else a tempfile+mv
# fallback. $1=content $2=target. Permissions 644 (world-readable so a collector
# running as a non-root user can read the published ID).
_failover_event_id_write() {
    local content="$1"
    local target="$2"
    local dir
    dir="$(dirname "$target")"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
    if declare -F sfu_write_file >/dev/null 2>&1; then
        sfu_write_file "$content" "$target" "644" 2>/dev/null || true
    else
        local tmp="${target}.tmp.$$"
        if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
            chmod 644 "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
        fi
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------------

# Generate a new event ID (PID_TIMESTAMP, identical to the lockfile format).
# Prints the ID on stdout without touching global state.
failover_event_id_generate() {
    echo "$$_$(date +%s 2>/dev/null)"
}

# Mint a new event ID: set + export FAILOVER_EVENT_ID and print it.
failover_event_id_mint() {
    FAILOVER_EVENT_ID="$(failover_event_id_generate)"
    export FAILOVER_EVENT_ID
    echo "$FAILOVER_EVENT_ID"
}

# Set an existing event ID (e.g. adopted from a lockfile/pending file).
failover_event_id_set() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 0
    FAILOVER_EVENT_ID="$id"
    export FAILOVER_EVENT_ID
    return 0
}

# Print the current event ID. Falls back to last_failover_id if the process
# variable is empty (e.g. route-guardian, which only knows the file).
failover_event_id_current() {
    if [[ -n "${FAILOVER_EVENT_ID:-}" ]]; then
        echo "$FAILOVER_EVENT_ID"
        return 0
    fi
    cat "${FAILOVER_EVENT_STATE_DIR}/last_failover_id" 2>/dev/null || echo ""
}

# Write the current ID as pending_failover_id (nmcli -> failover-monitor) BEFORE
# kill -USR1 is sent. Best-effort.
failover_event_id_write_pending() {
    local id="${1:-${FAILOVER_EVENT_ID:-}}"
    [[ -n "$id" ]] || return 0
    _failover_event_id_write "$id" "${FAILOVER_EVENT_STATE_DIR}/pending_failover_id"
    return 0
}

# Adopt a fresh pending_failover_id (if present and <= max-age) and consume it;
# otherwise mint a new ID. Sets FAILOVER_EVENT_ID and prints it.
# $1 = optional max age in seconds (default FAILOVER_EVENT_ID_PENDING_MAX_AGE).
failover_event_id_adopt_pending() {
    local max_age="${1:-$FAILOVER_EVENT_ID_PENDING_MAX_AGE}"
    local pending_file="${FAILOVER_EVENT_STATE_DIR}/pending_failover_id"
    local id=""

    if [[ -r "$pending_file" ]]; then
        local mtime now age
        mtime="$(stat -c %Y "$pending_file" 2>/dev/null || echo 0)"
        now="$(date +%s 2>/dev/null || echo 0)"
        age=$(( ${now:-0} - ${mtime:-0} ))
        if [[ "${age:-9999}" -le "$max_age" ]]; then
            id="$(cat "$pending_file" 2>/dev/null || echo "")"
        fi
        # Consume (clean up even if orphaned).
        rm -f "$pending_file" 2>/dev/null || true
    fi

    if [[ -n "$id" ]]; then
        failover_event_id_set "$id"
    else
        failover_event_id_mint >/dev/null
    fi
    echo "$FAILOVER_EVENT_ID"
}

# Publish the current ID as last_failover_id (read by the collector, survives the
# lockfile release window). Best-effort.
failover_event_id_publish() {
    local id="${1:-${FAILOVER_EVENT_ID:-}}"
    [[ -n "$id" ]] || return 0
    _failover_event_id_write "$id" "${FAILOVER_EVENT_STATE_DIR}/last_failover_id"
    return 0
}

# Export for child processes (daemons source this, but be safe). The internal
# writer is exported too — the public publish/pending writers call it; a real
# child process (not a $() subshell) would otherwise hit "command not found".
export -f _failover_event_id_write 2>/dev/null || true
export -f failover_event_id_generate failover_event_id_mint failover_event_id_set 2>/dev/null || true
export -f failover_event_id_current failover_event_id_write_pending 2>/dev/null || true
export -f failover_event_id_adopt_pending failover_event_id_publish 2>/dev/null || true
