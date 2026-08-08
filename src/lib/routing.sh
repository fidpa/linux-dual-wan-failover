#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# routing.sh — routing module for linux-dual-wan-failover
#
# This file is meant to be sourced from the failover services, not
# executed directly. See docs/reference/architecture-overview.md for
# the role of this module in the overall system.
#
set -uo pipefail

# secure-file-utils.sh provides atomic-write helpers (sfu_write_file etc.)
# from bash-production-toolkit. common.sh has already resolved the toolkit
# location into $TOOLKIT_LIB before routing.sh is sourced. We source it
# from there if available, otherwise fall back to a minimal local
# implementation so the failover services still operate.

if [[ -n "${TOOLKIT_LIB:-}" && -f "${TOOLKIT_LIB}/secure-file-utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${TOOLKIT_LIB}/secure-file-utils.sh"
fi

if ! declare -F sfu_write_file >/dev/null 2>&1; then
    # Minimal fallback: atomic write via mktemp + mv. No locking, no
    # permission preservation beyond what `install -m` provides.
    sfu_write_file() {
        local content="$1"
        local target="$2"
        local mode="${3:-644}"
        local tmp
        tmp="$(mktemp "${target}.XXXXXX")" || return 1
        printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
        install -m "$mode" "$tmp" "$target" && rm -f "$tmp"
    }
fi

# Failover Event-ID (Correlation-ID) helper — best-effort, never fatal: a
# missing helper must not block a failover (the lockfile mint falls back inline
# below). Lives next to this module in src/lib/. See event-id.sh.
_routing_self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -f "${_routing_self_dir}/event-id.sh" ]]; then
    # shellcheck source=src/lib/event-id.sh
    source "${_routing_self_dir}/event-id.sh" || true
fi
unset _routing_self_dir

# ============================================================================
# ROUTING CONFIGURATION
# ============================================================================

# Route management settings
readonly ROUTE_BACKUP_DIR="/tmp/route_backups"
# shellcheck disable=SC2034 # public library default
readonly ROUTE_VERIFICATION_TIMEOUT=10
# shellcheck disable=SC2034 # public library default
readonly MAX_ROUTE_RETRIES=3

# Route-guardian coordination. Format PID_TIMESTAMP — route-guardian pauses
# its route checks while the file exists (stale cleanup >60s plus ownership
# check prevent zombie locks, see route-guardian's _failover_lock_active).
readonly FAILOVER_LOCKFILE="/run/failover-in-progress.lock"
readonly FAILOVER_LOCKFILE_HOLD_SECONDS=30  # covers NM DHCP straggler events

# Real mutual exclusion. The marker file above is not one: route-guardian checks
# it once per cycle and keeps mutating routes afterwards, so a failover starting
# inside that window can be reverted by the guardian's own repair logic.
#
# The marker stays for what it is good at — the 30 s settle window against NM DHCP
# stragglers, and carrying the failover event id for trace-failover. flock is the
# fine-grained net underneath it.
#
# Fixed descriptor rather than {var}: under 'set -u' an unset variable after a
# failed exec would abort the daemon. 200 is a common choice in shell scripts, so
# 201 keeps this out of the way of anything the operator sources.
#
# /run rather than /tmp — the units run with PrivateTmp=yes, where a lock in /tmp
# would be three separate files in three namespaces and silently useless.
readonly ROUTE_LOCK_FILE="/run/failover-route.lock"
readonly ROUTE_LOCK_FD=201
readonly ROUTE_LOCK_WAIT=10

# Failover state tracking
current_active_interface=""
last_failover_timestamp=0
# shellcheck disable=SC2034 # used by sourcing scripts
failover_in_progress=false
_failover_lock_id=""

# ============================================================================
# MODULE MAP — 15 Funktionen in 6 Gruppen
# ============================================================================
#
# 1. ROUTE BACKUP & RESTORE — Routing-Table sichern/wiederherstellen (→ Zeile 93)
#    backup_current_routes()        ip route save in Backup-File
#    restore_routes_from_backup()   ip route restore aus Backup-File
#
# 2. ROUTE EXECUTION — Route-Wechsel durchführen (→ Zeile 145)
#    safe_route_change()            Route-Change mit Lockfile + Backup + Rollback
#    execute_route_change()         ip route del/add mit korrekter Metrik
#    _create_failover_lockfile()    Route-Guardian-Pause (PID_TIMESTAMP)
#    _release_failover_lockfile()   Lock-Freigabe sofort/verzögert mit Ownership-Check
#
# 3. ROUTE VERIFICATION — Erfolg prüfen (→ Zeile 259)
#    verify_route_change()          5 Attempts Connectivity-Test nach Change
#    test_connectivity_via_interface() Ping zu 8.8.8.8/1.1.1.1 via Interface
#
# 4. ROUTE RECOVERY — Rollback und Notfall (→ Zeile 302)
#    rollback_route_change()        Backup-Restore mit Emergency-Fallback
#    emergency_restore_any_route()  DSL oder LTE Route wiederherstellen (v3.5)
#
# 5. GATEWAY MANAGEMENT — Gateway-IP ermitteln (→ Zeile 362)
#    get_gateway_for_interface()    ip route + NetworkManager Fallback
#    get_gateway_from_nm()          nmcli IP4.GATEWAY abfragen
#
# 6. STATE & LOGGING — Zustand und Protokollierung
#    init_routing_state()           Active-WAN + Last-Failover laden
#    update_wan_state()             State-Files + interne Variable aktualisieren
#    get_current_wan_state()        Aktives Interface zurückgeben
#    is_backup_mode()               true wenn Backup-Interface aktiv
#
# ============================================================================

# ============================================================================
# ROUTE BACKUP & RESTORE
# ============================================================================

# Create backup of current routing table
backup_current_routes() {
    local backup_file
    backup_file="$ROUTE_BACKUP_DIR/routes_backup_$(get_timestamp)_$$"

    # Create backup directory if it doesn't exist
    mkdir -p "$ROUTE_BACKUP_DIR" 2>/dev/null || {
        log "ERROR" "Failed to create route backup directory"
        return 1
    }

    # Save current routes
    if ip route save > "$backup_file" 2>/dev/null; then
        log "DEBUG" "Routes backed up to: $backup_file"
        echo "$backup_file"
        return 0
    else
        log "ERROR" "Failed to backup current routes"
        return 1
    fi
}

# Restore routes from backup file
restore_routes_from_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi

    log "WARNING" "Restoring routes from backup: $backup_file"

    # Only remove default routes — never `ip route flush all`. The latter
    # also drops link-scope LAN and out-of-band management routes, which
    # has caused SSH lockouts in the past.
    # Remove ALL default routes: a single `ip route del default` left the
    # second WAN route in place, making the subsequent `ip route restore`
    # fail with "File exists" (rollback failure → emergency-recovery path).
    while ip route del default 2>/dev/null; do
        :
    done

    # Restore from backup
    if ip route restore < "$backup_file" 2>/dev/null; then
        log "INFO" "Routes restored successfully from backup"
        rm -f "$backup_file"
        return 0
    else
        log "ERROR" "Failed to restore routes from backup"
        return 1
    fi
}

# ============================================================================
# ROUTE EXECUTION
# ============================================================================

# Take the exclusive route lock. Returns 1 if it could not be had; the caller
# aborts the transaction rather than racing the guardian.
#
# RULE for every region between acquire and release: do not fork. flock lives on
# the open file description, not the descriptor — a child started with '&' inherits
# it and keeps holding the lock after the region ends.
# shellcheck disable=SC2120  # wait time is optional, defaults to ROUTE_LOCK_WAIT
_acquire_route_lock() {
    local wait_s="${1:-$ROUTE_LOCK_WAIT}"

    if ! eval "exec ${ROUTE_LOCK_FD}>\"\$ROUTE_LOCK_FILE\""; then
        log "ERROR" "Cannot open route lock ($ROUTE_LOCK_FILE)"
        return 1
    fi

    if ! flock -w "$wait_s" -x "$ROUTE_LOCK_FD"; then
        log "ERROR" "Route lock not acquired (waited ${wait_s}s)"
        eval "exec ${ROUTE_LOCK_FD}>&-"
        return 1
    fi

    return 0
}

# Release the route lock. Must run on EVERY exit path of the region — a leaked
# descriptor in a long-running daemon holds the lock until the next acquire and
# starves every guardian repair in between.
_release_route_lock() {
    flock -u "$ROUTE_LOCK_FD" 2>/dev/null || true
    eval "exec ${ROUTE_LOCK_FD}>&-" 2>/dev/null || true
    return 0
}

# Create the route-guardian pause lockfile (PID_TIMESTAMP ownership).
# Non-fatal on failure — the failover must proceed even if /run is unwritable.
_create_failover_lockfile() {
    # The lockfile ID IS the failover Event-ID (Correlation-ID). perform_failover()
    # or the nmcli emergency path usually set FAILOVER_EVENT_ID already; if not (a
    # defensive direct call), mint inline — same PID_TIMESTAMP format so the
    # lockfile content stays parseable for route-guardian's stale detection.
    if [[ -z "${FAILOVER_EVENT_ID:-}" ]]; then
        if declare -F failover_event_id_generate >/dev/null 2>&1; then
            FAILOVER_EVENT_ID="$(failover_event_id_generate)"
        else
            FAILOVER_EVENT_ID="$$_$(date +%s)"
        fi
        export FAILOVER_EVENT_ID
    fi
    _failover_lock_id="$FAILOVER_EVENT_ID"

    # Note: last_failover_id (for the collector) is NOT published here but
    # canonically in perform_failover() AFTER the active_wan change — the
    # collector only reads last_failover_id once it detects the active_wan change.
    if echo "$_failover_lock_id" > "$FAILOVER_LOCKFILE" 2>/dev/null; then
        log "DEBUG" "Failover lockfile created: $_failover_lock_id"
    else
        log "WARNING" "Failed to create failover lockfile - route-guardian may interfere during route change"
        _failover_lock_id=""
    fi
}

# Release the lockfile — immediately (delay=0, error path) or after a
# stabilization window (delay>0, success path, backgrounded). The ownership
# check prevents deleting a lockfile created by a newer failover or by the
# nmcli emergency path.
_release_failover_lockfile() {
    local delay="${1:-0}"
    local lock_id="$_failover_lock_id"
    [[ -n "$lock_id" ]] || return 0
    _failover_lock_id=""

    if [[ "$delay" -gt 0 ]]; then
        (
            sleep "$delay"
            if [[ "$(cat "$FAILOVER_LOCKFILE" 2>/dev/null)" == "$lock_id" ]]; then
                rm -f "$FAILOVER_LOCKFILE" 2>/dev/null
            fi
        ) &
    else
        if [[ "$(cat "$FAILOVER_LOCKFILE" 2>/dev/null)" == "$lock_id" ]]; then
            rm -f "$FAILOVER_LOCKFILE" 2>/dev/null
        fi
    fi
    return 0
}

# Perform route change with automatic rollback on failure.
#
# No ERR trap here (by design): it fired IN ADDITION to the explicit
# rollback calls (e.g. on an empty get_gateway_for_interface result),
# producing a double rollback against an already-deleted backup file and a
# false-positive "manual intervention required" cascade. The explicit error
# paths below cover every failure mode.
safe_route_change() {
    local new_interface="$1"
    local old_interface="$2"
    local backup_file

    # Stamp the route-change "span" with the Event-ID (lands as
    # [FAILOVER_EVENT_ID=…] in the file log → greppable across services).
    log_info_structured "Starting safe route change: $old_interface -> $new_interface" \
        "FAILOVER_EVENT_ID=${FAILOVER_EVENT_ID:-unknown}" \
        "FROM_INTERFACE=$old_interface" "TO_INTERFACE=$new_interface"

    # From here until the release below, nothing forks (see _acquire_route_lock).
    if ! _acquire_route_lock; then
        log "ERROR" "Route change aborted: route lock not acquired (guardian or emergency path active)"
        return 1
    fi

    # Create backup of current routes
    if ! backup_file=$(backup_current_routes); then
        log "ERROR" "Failed to backup routes - aborting route change"
        _release_route_lock
        return 1
    fi

    # Pause route-guardian for the duration of the orchestration. Without
    # this, the guardian (10s loop) can revert a fresh metric swap in the
    # window before active_wan is persisted.
    _create_failover_lockfile

    # Get gateway for new interface
    local new_gateway
    new_gateway=$(get_gateway_for_interface "$new_interface") || true

    if [[ -z "$new_gateway" ]]; then
        log "ERROR" "No gateway found for interface: $new_interface"
        rollback_route_change "$backup_file"
        _release_route_lock
        _release_failover_lockfile 0
        return 1
    fi

    # Perform the route change
    if execute_route_change "$new_interface" "$new_gateway"; then
        # Verify the change worked
        if verify_route_change "$new_interface" "$new_gateway"; then
            log_info_structured "Route change successful and verified" \
                "FAILOVER_EVENT_ID=${FAILOVER_EVENT_ID:-unknown}" \
                "TO_INTERFACE=$new_interface"
            rm -f "$backup_file"
            # Release the route lock BEFORE _release_failover_lockfile: that one
            # backgrounds a 'sleep &' child which would inherit the descriptor and
            # keep the lock for the full 30 s settle window.
            _release_route_lock
            # Hold the lock through the stabilization window (NM may re-add
            # routes up to ~1s after link events; 30s = 3 guardian cycles).
            _release_failover_lockfile "$FAILOVER_LOCKFILE_HOLD_SECONDS"
            return 0
        else
            log "ERROR" "Route change verification failed"
            rollback_route_change "$backup_file"
            _release_route_lock
            _release_failover_lockfile 0
            return 1
        fi
    else
        log "ERROR" "Route change execution failed"
        rollback_route_change "$backup_file"
        _release_route_lock
        _release_failover_lockfile 0
        return 1
    fi
}

# Swap eth0 kernel route metric between normal (50) and demoted (500)
# This is the core mechanism that makes failover actually work at routing level.
# On failover to LTE: demote eth0 50->500, kernel prefers lte0 (200)
# On failback to DSL: restore eth0 500->50, kernel prefers eth0 again
_swap_primary_metric() {
    local from_metric="$1"  # Expected current metric (for logging/validation)
    local to_metric="$2"
    local gateway="${DSL_GATEWAY:-192.0.2.1}"
    local iface="${PRIMARY_IFACE:-eth0}"
    local nm_conn="${NM_PRIMARY_CONNECTION:-eth0}"

    # Validate: log if actual metric differs from expected from_metric
    local actual_metric
    actual_metric=$(ip route show default dev "$iface" 2>/dev/null | head -1 | grep -o "metric [0-9]*" | awk '{print $2}')
    if [[ -n "$actual_metric" && "$actual_metric" != "$from_metric" ]]; then
        log "WARNING" "Expected metric $from_metric but found $actual_metric on $iface (proceeding anyway)"
    fi

    # Step 1: Persist new metric in NetworkManager (survives DHCP renewals).
    # Independent of kernel routing state and important for the reconnect path.
    if ! nmcli connection modify "$nm_conn" ipv4.route-metric "$to_metric" 2>/dev/null; then
        log "WARNING" "Failed to persist metric $to_metric in NetworkManager (non-fatal, route-guardian backstop)"
    fi

    # Step 2: Carrier-aware short-circuit (anti-stall fix).
    # If primary has no carrier, the kernel will refuse `ip route add default
    # ... dev <iface>` with "Network is unreachable", which then trips
    # safe_route_change() → rollback → emergency recovery, all of which also
    # fail. Since the NM metric is already persisted in Step 1 (applied on
    # the next DHCP cycle), and since the backup is automatically preferred
    # by the kernel when there is no competing primary route, we can safely
    # return here.
    local primary_carrier
    primary_carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo "0")
    if [[ "$primary_carrier" != "1" ]]; then
        # Defensive: clean up any stale routes for the dead interface (idempotent)
        while ip route del default dev "$iface" 2>/dev/null; do
            :
        done
        log "INFO" "Primary $iface has no carrier — skipping kernel route swap (NM metric $to_metric persisted for reconnect)"
        return 0
    fi

    # Step 3: Swap kernel route (del all for this interface, add with target metric)
    # Get current gateway from routing table (may differ from config after DHCP)
    local current_gw
    current_gw=$(ip route show default dev "$iface" 2>/dev/null | head -1 | awk '{print $3}')
    [[ -z "$current_gw" ]] && current_gw="$gateway"

    # Delete ALL existing default routes for this interface (any metric)
    while ip route del default dev "$iface" 2>/dev/null; do
        :
    done

    # Add with target metric
    if ip route add default via "$current_gw" dev "$iface" metric "$to_metric" 2>/dev/null; then
        log "INFO" "Primary metric swapped: ${actual_metric:-none} -> $to_metric (kernel + NM persisted)"
        return 0
    else
        # Emergency: restore with original metric to avoid total connectivity loss
        log "ERROR" "Failed to add route with metric $to_metric, restoring metric $from_metric"
        ip route add default via "$current_gw" dev "$iface" metric "$from_metric" 2>/dev/null || true
        return 1
    fi
}

# Execute the actual route change via metric demotion/promotion
execute_route_change() {
    local interface="$1"
    local gateway="$2"

    log "DEBUG" "Executing route change: interface=$interface, gateway=$gateway"

    local primary_metric_normal="${PRIMARY_METRIC_NORMAL:-50}"
    local primary_metric_demoted="${PRIMARY_METRIC_DEMOTED:-500}"

    if [[ "$interface" == "${BACKUP_IFACE:-lte0}" ]]; then
        # FAILOVER to LTE: demote eth0 metric 50 -> 500 (lte0 at 200 becomes preferred)
        _swap_primary_metric "$primary_metric_normal" "$primary_metric_demoted"
    else
        # FAILBACK to DSL: restore eth0 metric 500 -> 50 (eth0 becomes preferred again)
        _swap_primary_metric "$primary_metric_demoted" "$primary_metric_normal"
    fi
}

# restore_missing_backup_route() removed: monitoring-only since route-guardian
# took over default-route management, no callers, and its inverted log logic
# ("route managed by guardian" when the route was MISSING) was misleading.

# ============================================================================
# ROUTE VERIFICATION
# ============================================================================

# Verify that the route change was successful
# Uses ip route get (kernel routing decision) as primary check,
# then interface-bound ping as connectivity confirmation
verify_route_change() {
    local interface="$1"
    local gateway="$2"
    local max_attempts=5

    log "DEBUG" "Verifying route change for $interface"

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        # PRIMARY CHECK: Verify kernel actually routes through the target interface
        local actual_dev
        actual_dev=$(ip route get 8.8.8.8 2>/dev/null | grep -o "dev [^ ]*" | awk '{print $2}')

        if [[ "$actual_dev" == "$interface" ]]; then
            log "DEBUG" "Kernel routing verification: 8.8.8.8 -> $actual_dev (correct)"

            # SECONDARY CHECK: Verify actual connectivity via that interface
            if test_connectivity_via_interface "$interface"; then
                log "DEBUG" "Route verification successful on attempt $attempt"
                return 0
            fi
        else
            log "DEBUG" "Kernel routes via ${actual_dev:-none}, expected $interface (attempt $attempt/$max_attempts)"
        fi

        [[ $attempt -lt $max_attempts ]] && sleep 1
    done

    log "ERROR" "Route verification failed after $max_attempts attempts"
    return 1
}

# Test connectivity via specific interface
# Performance optimized: timeout 2s, -W 1s (was 3s/2s) - saves 1-2s per failed test
test_connectivity_via_interface() {
    local interface="$1"
    local test_targets=("8.8.8.8" "1.1.1.1")

    for target in "${test_targets[@]}"; do
        if timeout 2 ping -c 1 -W 1 -I "$interface" "$target" &>/dev/null; then
            log "DEBUG" "Connectivity test successful: $interface -> $target"
            return 0
        fi
    done

    log "DEBUG" "All connectivity tests failed for $interface"
    return 1
}

# ============================================================================
# ROUTE RECOVERY
# ============================================================================

# Rollback route change
rollback_route_change() {
    local backup_file="$1"

    log "WARNING" "Rolling back route change"

    if restore_routes_from_backup "$backup_file"; then
        log "INFO" "Route rollback completed successfully"
    else
        log "CRITICAL" "Route rollback failed - attempting emergency recovery"

        # v3.5: Emergency Recovery - restore ANY working route to prevent total connectivity loss
        if emergency_restore_any_route; then
            log "WARNING" "Emergency recovery successful - system has basic connectivity"
        else
            log "CRITICAL" "Emergency recovery FAILED - manual intervention required"
        fi
    fi
}

# Local link check — UP state + carrier via sysfs.
# emergency_restore_any_route() previously called check_interface_status(),
# which is defined ONLY in route-guardian.sh (a separate process). Inside the
# failover-monitor process that meant `command not found` → both restore
# attempts were silently skipped → the emergency net never worked.
_interface_link_up() {
    local interface="$1"
    [[ -n "$interface" ]] || return 1
    ip link show "$interface" 2>/dev/null | grep -q "state UP" || return 1
    local carrier_file="/sys/class/net/${interface}/carrier"
    if [[ -r "$carrier_file" ]]; then
        [[ "$(cat "$carrier_file" 2>/dev/null)" == "1" ]] || return 1
    fi
    return 0
}

# v3.5: Emergency Recovery - restore at least one default route
# Called when backup restoration fails to prevent total connectivity loss
emergency_restore_any_route() {
    log "WARNING" "EMERGENCY RECOVERY: Attempting to restore any available route"

    # Define known routes (from config)
    local dsl_gateway="${DSL_GATEWAY:-192.0.2.1}"
    local lte_gateway="${LTE_GATEWAY:-192.0.2.10}"
    local primary_iface="${PRIMARY_IFACE:-eth0}"
    local backup_iface="${BACKUP_IFACE:-lte0}"

    # Try DSL first (preferred) — always use normal metric (clean state in emergency)
    local primary_metric="${PRIMARY_METRIC_NORMAL:-50}"
    if _interface_link_up "$primary_iface"; then
        log "INFO" "EMERGENCY: Attempting DSL route restoration"
        if ip route add default via "$dsl_gateway" dev "$primary_iface" metric "$primary_metric" 2>/dev/null; then
            log "WARNING" "EMERGENCY: DSL route restored (metric $primary_metric)"
            # Send critical notification
            send_notification "⚠️ EMERGENCY RECOVERY: DSL route restored after rollback failure" || true
            return 0
        fi
    fi

    # Fallback to LTE
    if _interface_link_up "$backup_iface"; then
        log "INFO" "EMERGENCY: Attempting LTE route restoration"
        if ip route add default via "$lte_gateway" dev "$backup_iface" metric 200 2>/dev/null; then
            log "WARNING" "EMERGENCY: LTE route restored (metric 200)"
            # Send critical notification
            send_notification "⚠️ EMERGENCY RECOVERY: LTE route restored after rollback failure" || true
            return 0
        fi
    fi

    # Complete failure - system has no routes
    log "CRITICAL" "EMERGENCY: Could not restore any route - system has NO connectivity"
    send_notification "🔴 CRITICAL: Emergency recovery FAILED - manual reboot required" || true
    return 1
}

# ============================================================================
# GATEWAY MANAGEMENT
# ============================================================================

# Get gateway for specific interface
get_gateway_for_interface() {
    local interface="$1"

    # Try to get gateway from routing table
    local gateway
    gateway=$(ip route show dev "$interface" | grep default | awk '{print $3}' | head -1)

    if [[ -n "$gateway" ]]; then
        log "DEBUG" "Gateway for $interface: $gateway"
        echo "$gateway"
        return 0
    fi

    # If no default route, ask NetworkManager (was: dhclient lease files,
    # which never exist on NM systems using the internal DHCP client —
    # the fallback was dead code on every supported target)
    gateway=$(get_gateway_from_nm "$interface")

    if [[ -n "$gateway" ]]; then
        log "DEBUG" "Gateway from NetworkManager for $interface: $gateway"
        echo "$gateway"
        return 0
    fi

    log "WARNING" "No gateway found for interface: $interface"
    return 1
}

# Get gateway from NetworkManager device state (DHCP-lease-derived)
get_gateway_from_nm() {
    local interface="$1"
    nmcli -g IP4.GATEWAY device show "$interface" 2>/dev/null | head -1
}

# ============================================================================
# STATE & LOGGING
# ============================================================================

# Initialize routing state
init_routing_state() {
    # Load current state
    current_active_interface=$(load_state "active_wan" "$PRIMARY_IFACE")
    last_failover_timestamp=$(load_state "last_failover" "0")

    # Boot-time safety: If a crashed session left eth0 demoted but active_wan=eth0 (anomaly), restore.
    # Only reset if active_wan=eth0 AND metric is demoted — this means the session crashed mid-failover.
    # Do NOT reset if active_wan=lte0: metric 500 is correct and intentional in that case.
    local primary_metric_normal="${PRIMARY_METRIC_NORMAL:-50}"
    local nm_conn="${NM_PRIMARY_CONNECTION:-eth0}"
    local current_nm_metric
    current_nm_metric=$(nmcli -t -f ipv4.route-metric connection show "$nm_conn" 2>/dev/null | cut -d: -f2)

    if [[ -n "$current_nm_metric" && "$current_nm_metric" != "$primary_metric_normal" ]]; then
        if [[ "$current_active_interface" != "${BACKUP_IFACE:-lte0}" ]]; then
            # active_wan=eth0 but metric is demoted → anomaly from crashed session, restore
            log "WARNING" "Boot-time metric reset: NM metric is $current_nm_metric (active_wan=$current_active_interface), restoring to $primary_metric_normal"
            nmcli connection modify "$nm_conn" ipv4.route-metric "$primary_metric_normal" 2>/dev/null || true
            current_active_interface="$PRIMARY_IFACE"
            save_state "active_wan" "$PRIMARY_IFACE"
        else
            # active_wan=lte0 and metric is demoted → correct failover state, do NOT reset
            log "INFO" "Boot-time check: metric $current_nm_metric is intentional (active_wan=$current_active_interface, failover mode active)"
        fi
    fi

    log "INFO" "Routing state initialized: active=$current_active_interface, last_failover=$(get_human_time "$last_failover_timestamp")"
}

# Update current WAN state
update_wan_state() {
    local interface="$1"
    local score="$2"
    local timestamp="${3:-$(get_timestamp)}"

    # Update state file
    save_state "active_wan" "$interface"
    save_state "wan_score" "$score"
    save_state "last_update" "$timestamp"

    # Update internal state
    current_active_interface="$interface"
}

# Get current WAN state
get_current_wan_state() {
    echo "$current_active_interface"
}

# Check if we're in backup mode
is_backup_mode() {
    [[ "$current_active_interface" == "$BACKUP_IFACE" ]]
}

# Export functions for use by main script
export -f safe_route_change
export -f get_gateway_for_interface init_routing_state update_wan_state
export -f get_current_wan_state is_backup_mode
