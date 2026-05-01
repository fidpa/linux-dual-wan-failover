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

# ============================================================================
# ROUTING CONFIGURATION
# ============================================================================

# Route management settings
readonly ROUTE_BACKUP_DIR="/tmp/route_backups"
readonly ROUTE_VERIFICATION_TIMEOUT=10
readonly MAX_ROUTE_RETRIES=3

# Failover state tracking
current_active_interface=""
last_failover_timestamp=0
failover_in_progress=false

# ============================================================================
# MODULE MAP — 15 Funktionen in 6 Gruppen
# ============================================================================
#
# 1. ROUTE BACKUP & RESTORE — Routing-Table sichern/wiederherstellen (→ Zeile 93)
#    backup_current_routes()        ip route save in Backup-File
#    restore_routes_from_backup()   ip route restore aus Backup-File
#
# 2. ROUTE EXECUTION — Route-Wechsel durchführen (→ Zeile 145)
#    safe_route_change()            Route-Change mit Backup + Rollback
#    execute_route_change()         ip route del/add mit korrekter Metrik
#    restore_missing_backup_route() Monitoring-only (Route Guardian v2.0 managed)
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
#    get_gateway_for_interface()    ip route + DHCP Fallback
#    get_gateway_from_dhcp()        DHCP-Lease-File parsen
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
    local backup_file="$ROUTE_BACKUP_DIR/routes_backup_$(get_timestamp)_$$"
    
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
    ip route del default 2>/dev/null || true
    
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

# Perform route change with automatic rollback on failure
safe_route_change() {
    local new_interface="$1"
    local old_interface="$2"
    local backup_file
    
    log "INFO" "Starting safe route change: $old_interface -> $new_interface"
    
    # Create backup of current routes
    backup_file=$(backup_current_routes)
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to backup routes - aborting route change"
        return 1
    fi
    
    # Setup rollback trap
    trap "rollback_route_change '$backup_file'" ERR
    
    # Get gateway for new interface
    local new_gateway
    new_gateway=$(get_gateway_for_interface "$new_interface")
    
    if [[ -z "$new_gateway" ]]; then
        log "ERROR" "No gateway found for interface: $new_interface"
        rollback_route_change "$backup_file"
        return 1
    fi
    
    # Perform the route change
    if execute_route_change "$new_interface" "$new_gateway"; then
        # Verify the change worked
        if verify_route_change "$new_interface" "$new_gateway"; then
            log "INFO" "Route change successful and verified"
            rm -f "$backup_file"
            trap - ERR
            return 0
        else
            log "ERROR" "Route change verification failed"
            rollback_route_change "$backup_file"
            return 1
        fi
    else
        log "ERROR" "Route change execution failed"
        rollback_route_change "$backup_file"
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

    # Step 1: Persist new metric in NetworkManager (survives DHCP renewals)
    if ! nmcli connection modify "$nm_conn" ipv4.route-metric "$to_metric" 2>/dev/null; then
        log "WARNING" "Failed to persist metric $to_metric in NetworkManager (non-fatal, route-guardian backstop)"
    fi

    # Step 2: Swap kernel route (del all for this interface, add with target metric)
    # Get current gateway from routing table (may differ from config after DHCP)
    local current_gw
    current_gw=$(ip route show default dev "$iface" 2>/dev/null | head -1 | awk '{print $3}')
    [[ -z "$current_gw" ]] && current_gw="$gateway"

    # Delete ALL existing default routes for this interface (any metric)
    while ip route del default dev "$iface" 2>/dev/null; do true; done

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

# Restore missing backup route after failover change
restore_missing_backup_route() {
    local changed_interface="$1"
    
    # Define expected routes
    local dsl_gateway="192.0.2.1"
    local lte_gateway="192.0.2.10"  # Netgear LM1200 Bridge-Mode Management IP
    local primary_iface="${PRIMARY_IFACE:-eth0}"
    local backup_iface="${BACKUP_IFACE:-lte0}"
    
    # DISABLED: Route addition now managed by Route Guardian v2.0
    # Architecture Fix (03.09.2025): WAN-Monitor focuses on Interface-Scoring only
    # Route Guardian v2.0 handles all Default-Route management for consistency
    
    # Check if DSL route exists (including DHCP variants) - MONITORING ONLY
    if ! ip route show | grep -qE "^default via $dsl_gateway dev $primary_iface.*(metric 50|proto dhcp.*metric 50)"; then
        log "INFO" "DSL route managed by Route Guardian v2.0 (metric 50)"
        # DISABLED: ip route add default via "$dsl_gateway" dev "$primary_iface" metric 100 2>/dev/null || true
    fi
    
    # Check if LTE route exists (including DHCP variants) - MONITORING ONLY  
    if ! ip route show | grep -qE "^default via $lte_gateway dev $backup_iface.*(metric 200|proto dhcp.*metric 200)"; then
        log "INFO" "LTE route managed by Route Guardian v2.0 + NetworkManager (metric 200)"
        # DISABLED: ip route add default via "$lte_gateway" dev "$backup_iface" metric 200 2>/dev/null || true
    fi
    
    log "DEBUG" "Backup route restoration completed"
}

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
    trap - ERR

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
    if check_interface_status "$primary_iface" 2>/dev/null; then
        log "INFO" "EMERGENCY: Attempting DSL route restoration"
        if ip route add default via "$dsl_gateway" dev "$primary_iface" metric "$primary_metric" 2>/dev/null; then
            log "WARNING" "EMERGENCY: DSL route restored (metric $primary_metric)"
            # Send critical notification
            send_notification "⚠️ EMERGENCY RECOVERY: DSL route restored after rollback failure" || true
            return 0
        fi
    fi

    # Fallback to LTE
    if check_interface_status "$backup_iface" 2>/dev/null; then
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
    
    # If no default route, try to get from DHCP lease
    gateway=$(get_gateway_from_dhcp "$interface")
    
    if [[ -n "$gateway" ]]; then
        log "DEBUG" "Gateway from DHCP for $interface: $gateway"
        echo "$gateway"
        return 0
    fi
    
    log "WARNING" "No gateway found for interface: $interface"
    return 1
}

# Get gateway from DHCP lease information
get_gateway_from_dhcp() {
    local interface="$1"
    local lease_file="/var/lib/dhcp/dhclient.${interface}.leases"
    
    if [[ -f "$lease_file" ]]; then
        local gateway
        gateway=$(grep "option routers" "$lease_file" | tail -1 | awk '{print $3}' | tr -d ';')
        echo "$gateway"
    fi
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
