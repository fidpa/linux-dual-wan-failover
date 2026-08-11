#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# route-guardian — route enforcement and cleanup daemon
#
# Watches the routing table every CHECK_INTERVAL seconds, removes duplicate
# default routes, and ensures the metric of the primary/backup interfaces
# matches the current `active_wan` ground truth written by failover-monitor.
#
# Configured via /etc/linux-dual-wan-failover/failover.conf (overridable
# via FAILOVER_CONF_PATH).
#
set -uo pipefail

# shellcheck disable=SC2034 # consumed by sourced lib/common.sh logging
SCRIPT_NAME="route-guardian"

# ---- Configuration ----------------------------------------------------------
# All interface/gateway names default to the values from failover.conf or
# the environment. Hardcoded fallbacks below are the example-config defaults.

DSL_INTERFACE="${PRIMARY_IFACE:-eth0}"
LTE_INTERFACE="${BACKUP_IFACE:-lte0}"

# Optional secondary interfaces. The guardian only enforces metric correctness
# for these; leave empty to disable the corresponding checks.
LAN_INTERFACE="${LAN_INTERFACE:-}"
MGMT_INTERFACE="${MGMT_INTERFACE:-}"

DSL_GATEWAY="${PRIMARY_GATEWAY:-192.0.2.1}"
LTE_GATEWAY="${BACKUP_GATEWAY:-192.0.2.10}"
readonly CHECK_INTERVAL="${ROUTE_GUARDIAN_CHECK_INTERVAL:-10}"

# v3.3.0: LTE Availability State (Dynamic Detection)
# Set during pre-flight, updated by periodic recovery checks
LTE_AVAILABLE=false  # Assume unavailable until proven otherwise

# Best Practice 2025: Conditional readonly prevents conflicts when common.sh tries to restore caller's LOG_FILE
# Allows parent scripts to override LOG_FILE via environment, falls back to default if not set
if [[ -z "${LOG_FILE:-}" ]]; then
    readonly LOG_FILE="/var/log/linux-dual-wan-failover/route-guardian.log"
fi

readonly STATE_DIR="/var/lib/linux-dual-wan-failover/route-guardian"

# Rate-limit marker per interface. A single shared marker meant that if both
# default routes went missing at once — a NetworkManager restart does this — the
# guardian repaired the primary and then locked itself out of repairing the
# backup for 60 s, which is exactly the window where the backup path is needed.
readonly REPAIR_LOCKFILE_PREFIX="${STATE_DIR}/route-guardian-repair"
readonly REPAIR_RATE_LIMIT_SECONDS=60

# Real mutual exclusion against the orchestrator (routing.sh). The marker file
# /run/failover-in-progress.lock only pauses whole cycles and is checked once at
# the top — a failover fits entirely between that check and the mutation below.
#
# RULE: do not fork between acquire and release. flock lives on the open file
# description; a child started with '&' (the Mattermost curl in send_alert and
# send_recovery_alert, for instance) inherits it and keeps holding the lock.
# The regions are therefore deliberately narrow and contain no 'sleep'.
readonly ROUTE_LOCK_FILE="/run/failover-route.lock"
readonly ROUTE_LOCK_FD=201
readonly ROUTE_LOCK_WAIT=5
readonly LTE_AVAILABLE_STATE="${STATE_DIR}/backup_available.state"

# Optional secondary subnets / source IPs (only used for diagnostic output and
# the local-route repair fallback; leave empty to disable).
LAN_SUBNET="${LAN_SUBNET:-}"
readonly LAN_SUBNET
LAN_SOURCE_IP="${LAN_SOURCE_IP:-}"
readonly LAN_SOURCE_IP
MGMT_SUBNET="${MGMT_SUBNET:-}"
readonly MGMT_SUBNET
MGMT_SOURCE_IP="${MGMT_SOURCE_IP:-}"
readonly MGMT_SOURCE_IP

WAN_PRIMARY_CONNECTION="${PRIMARY_NM_CONNECTION:-${PRIMARY_IFACE:-eth0}}"
readonly WAN_PRIMARY_CONNECTION
LTE_CONNECTION="${BACKUP_NM_CONNECTION:-${BACKUP_IFACE:-lte0}}"
readonly LTE_CONNECTION
readonly REPAIR_SUCCESS_COUNTER="${STATE_DIR}/route-guardian-success.count"
readonly REPAIR_FAILURE_COUNTER="${STATE_DIR}/route-guardian-failure.count"

# Alert configuration
readonly ALERT_STATE_DIR="${STATE_DIR}/alerts"
readonly PREVENTIVE_ALERT_COOLDOWN=1800  # 30 minutes between preventive alerts

# ============================================================================
# FAILOVER STATE AWARENESS
# ============================================================================

# Determine expected DSL metric based on failover state (active_wan).
# Returns 500 during failover (eth0 demoted), 50 during normal operation.
# This makes Route Guardian an ally of the failover system instead of fighting it.
get_expected_primary_metric() {
    local active_wan
    active_wan=$(cat /run/linux-dual-wan-failover/wan-state/active_wan 2>/dev/null || echo "$DSL_INTERFACE")
    if [[ "$active_wan" == "$LTE_INTERFACE" ]]; then
        echo 500  # Demoted during failover (lte0 metric 200 must win)
    else
        echo 50   # Normal operation (eth0 is preferred WAN)
    fi
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$STATE_DIR"
mkdir -p "${STATE_DIR}/alerts"

# Create log file with readable permissions (allows troubleshooting without sudo)
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Optional secrets file (used by alerting plugins that need webhook URLs etc.).
# Default: empty — set FAILOVER_SECRETS_FILE to enable.
# shellcheck disable=SC2034 # exported via env for sourced alerting plugins
readonly SECRETS_FILE="${FAILOVER_SECRETS_FILE:-}"

# ---- Library imports --------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
LIB_DIR="${LIB_DIR:-${SCRIPT_DIR}/../lib}"
readonly LIB_DIR

# common.sh handles toolkit-aware logging.sh resolution and provides a
# minimal fallback logger if the toolkit is not installed. It also resolves
# secure-file-utils.sh from the toolkit (used by routing.sh and below).
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh" || {
    echo "FATAL: failed to source common.sh from ${LIB_DIR}" >&2
    exit 1
}

# Optional: smart-alerts.sh from bash-production-toolkit for event aggregation.
if [[ -n "${TOOLKIT_LIB:-}" && -f "${TOOLKIT_LIB}/../monitoring/smart-alerts.sh" ]]; then
    # shellcheck source=/dev/null
    source "${TOOLKIT_LIB}/../monitoring/smart-alerts.sh" 2>/dev/null || true
fi

# Optional: code-change detection for clean restart on git-pull deployments.
# shellcheck source=../lib/script-watch.sh
source "${LIB_DIR}/script-watch.sh" 2>/dev/null || \
    log_warning "script-watch.sh not loaded — automatic restart on code update disabled"

# Backwards-compat shim: a few legacy code paths in this file still call
# `send_mattermost_alert_lib` directly. Provide a stub that delegates to the
# generic plugin-based send_alert (or no-ops if no plugin is configured),
# so route-guardian doesn't hard-fail when the toolkit isn't installed.
if ! declare -f send_mattermost_alert_lib >/dev/null 2>&1; then
    send_mattermost_alert_lib() {
        local alert_type="${1:-INFO_FAILOVER}"
        local message="${2:-}"
        if declare -f send_notification >/dev/null 2>&1; then
            send_notification "$message" "${alert_type#*_}" || true
        fi
        return 0
    }
fi

# Optional toolkit hook: configures Mattermost credentials if available.
if declare -f load_mattermost_config >/dev/null 2>&1; then
    load_mattermost_config || \
        log_warning "Mattermost config not loaded — alerts will use the generic plugin path"
fi

# Logging behaviour. Override via env / failover.conf if needed.
export LOG_TO_JOURNAL="${LOG_TO_JOURNAL:-false}"
export LOG_TO_STDOUT="${LOG_TO_STDOUT:-false}"

# Configure alerts.sh library (no-op if toolkit not loaded).
export RATE_LIMIT_SECONDS="${ALERT_RATE_LIMIT_SECONDS:-300}"
export ALERTS_PREFIX="${ALERTS_PREFIX:-Route Guardian}"


# ============================================================================
# MODULE MAP — 30 Funktionen in 9 Gruppen
# ============================================================================
#
# 1. ALERT DELIVERY — Mattermost, Smart Alerts, Präventiv-Alerts, Logging (→ Zeile 257)
#    _send_alert_direct()                Direkte Mattermost-Zustellung via alerts.sh
#    send_alert()                        Smart Alert Wrapper mit Grace Period
#    send_recovery_alert()               Recovery-Alerts mit Downtime-Suppression
#    send_preventive_alert()             Präventive Alerts mit 30min Cooldown
#    log_message()                       logging.sh Wrapper mit Component-basiertem Alert-Routing
#
# 2. INTERFACE VALIDATION — Zustand, Carrier, Route-Existenz, Gateway-Ping (→ Zeile 446)
#    check_interface_status()            UP-State + Carrier-Signal prüfen
#    check_route_exists()                Default-Route via Interface + Gateway vorhanden
#    test_gateway_reachable()            Ping-Test gegen Gateway via Interface
#
# 3. ROUTE REPAIR — Fehlende Routen wiederherstellen mit Rate Limiting (→ Zeile 534)
#    increment_success_count()           Repair-Erfolgs-Zähler (StateDirectory-persistent)
#    increment_failure_count()           Repair-Fehler-Zähler (StateDirectory-persistent)
#    repair_local_route()                Subnet-Route mit 4-Methoden IP-Detection + 3 Retries
#    add_missing_route()                 Default-Route mit Gateway-Reachability-Check
#
# 4. NETWORKMANAGER INTEGRATION — Konfiguration, Metriken, Backup (→ Zeile 669)
#    backup_networkmanager_connection()  Connection-Snapshot vor Auto-Repair (max 5 Backups)
#    check_networkmanager_configuration() never-default + Route-Metriken prüfen/reparieren
#    check_networkmanager_never_default() Legacy-Wrapper für Abwärtskompatibilität
#
# 5. CONFLICT RESOLUTION — Metric-Konflikte, Duplikate, Präventive Checks (→ Zeile 799)
#    detect_metric_conflicts()           Mehrfache Routen mit gleicher Metrik erkennen
#    cleanup_conflicting_routes()        Konflikte nach configured metric standards bereinigen
#    cleanup_interface_duplicate_routes() Duplikate pro Interface (niedrigste Metrik behalten)
#    check_preventive_issues()           Proaktive Warnungen (Route-Count, Metrik-Drift)
#
# 6. LTE RECOVERY & STATE — Modem-Erkennung, Persistent State, Pre-Flight (→ Zeile 1008)
#    write_lte_state()                   LTE-Verfügbarkeit in StateDirectory schreiben
#    read_lte_state()                    LTE-State lesen (Default: false)
#    check_lte_recovery()                Periodische LTE-Erkennung (60s Intervall)
#    enhanced_preflight_checks()         Boot-Checks: DSL (kritisch) + LTE (30s Timeout, Fallback)
#
# 7. ROUTE MONITORING — Default-Routes, Subnets, Health Check Orchestration (→ Zeile 1222)
#    check_local_subnet_routes()         LAN/MGMT Subnet-Routen prüfen
#    monitor_default_routes()            DSL/LTE Default-Route Loop mit Stale-Lockfile-Detection
#    _failover_lock_active()             Failover-Lockfile-Check mit Stale-Detection
#    comprehensive_route_health_check()  Lockfile-Gate, dann: Duplikate, Routes, Subnets, NM, Konflikte
#
# 8. STATUS REPORTING — CLI-Ausgabe und Dashboard-JSON (→ Zeile 1386)
#    show_status()                       Human-readable Status mit Interface/Route/Counter-Info
#    generate_json_status()              JSON für Dashboard-Integration (v2.0 Schema)
#
# 9. SIGNAL HANDLING — Graceful Shutdown und Log-Rotation (→ Zeile 1528)
#    cleanup()                           SIGTERM/SIGINT Handler (kein exit, Best Practice 2025)
#    handle_sighup()                     Log-Rotation via logrotate (fd reopen)
#
# ============================================================================

# ============================================================================
# ALERT DELIVERY
# ============================================================================

# "Dumb" send function — no rate-limiting or grace-period logic, just delivery.
# Called directly and as the callback for the smart-alert grace queue. The
# actual delivery target is whatever the configured ALERTING_BACKEND plugin
# decides (mattermost / webhook / none / custom). The helper name is kept for
# legacy compatibility with the optional smart-alerts toolkit module.
_send_alert_direct() {
    local alert_type="$1"
    local message="$2"
    local details="${3:-}"

    # Build enriched message with Route Guardian context
    local enriched="$message"
    [[ -n "$details" ]] && enriched+=$'\n'"$details"
    enriched+=$'\n\n'"_$(date '+%Y-%m-%d %H:%M:%S') | $(hostname)_"

    # Delegate to the alert plugin loaded by common.sh / the toolkit.
    send_mattermost_alert_lib "$alert_type" "$enriched"
}

# Smart-alert wrapper — applies grace-period logic before delivery and then
# calls _send_alert_direct() for the actual send.
send_alert() {
    local alert_type="$1"
    local message="$2"
    local details="${3:-}"

    # Determine severity based on alert type
    local severity="NORMAL"
    # v3.5.0: original_alert_type removed (dedup handled by smart-alerts)

    # Critical events that bypass grace period
    case "$alert_type" in
        NETWORKMANAGER_CRITICAL)
            severity="CRITICAL"
            ;;
        DSL_ROUTE_MISSING)
            # Check if LTE is also down (both WANs down = critical)
            if [[ ! -f "${SA_EVENTS_DIR}/LTE_ROUTE_MISSING.event" ]] && ! check_route_exists "$LTE_INTERFACE" "$LTE_GATEWAY"; then
                # Both WANs down - critical!
                severity="CRITICAL"
                alert_type="BOTH_WANS_DOWN"
                message="CRITICAL: Both WAN connections down! DSL and LTE routes missing."
            fi
            ;;
        LTE_ROUTE_MISSING)
            # v3.1.1: Prevent BOTH_WANS_DOWN duplication
            # If BOTH_WANS_DOWN already tracked/alerted, skip this event
            if [[ -f "${SA_EVENTS_DIR}/BOTH_WANS_DOWN.event" ]] || [[ -f "${SA_PENDING_DIR}/BOTH_WANS_DOWN.pending" ]]; then
                log_message "DEBUG" "SMART_ALERT" "BOTH_WANS_DOWN already tracked, skipping duplicate LTE_ROUTE_MISSING check"
                # Continue with normal LTE_ROUTE_MISSING handling
            elif [[ ! -f "${SA_EVENTS_DIR}/DSL_ROUTE_MISSING.event" ]] && ! check_route_exists "$DSL_INTERFACE" "$DSL_GATEWAY"; then
                # Both WANs down - critical!
                severity="CRITICAL"
                alert_type="BOTH_WANS_DOWN"
                message="CRITICAL: Both WAN connections down! DSL and LTE routes missing."
            fi
            ;;
    esac

    # Track event with smart alerts (v3.1.1: logging done in sa_track_event)
    if sa_track_event "$alert_type" "$severity" "$message" "$details"; then
        # Event entered grace period - no immediate alert (logged by sa_track_event)
        return 0
    else
        # Critical event or grace period bypassed - send immediately (logged by sa_track_event)
        _send_alert_direct "$alert_type" "$message" "$details" &
        return 0
    fi
}

# Smart recovery wrapper (v3.1.0: Suppress recovery alerts for short downtimes)
send_recovery_alert() {
    local event_type="$1"
    local message="$2"
    local details="${3:-}"

    # Resolve event and check if recovery alert should be sent
    if sa_resolve_event "$event_type" "$message"; then
        # Downtime was long enough - send recovery alert
        local downtime
        downtime=$(sa_get_downtime "$event_type")
        log_message "INFO" "SMART_ALERT" "Sending recovery alert for $event_type (downtime: ${downtime}s)"
        _send_alert_direct "RECOVERY_${event_type}" "$message" "$details" &
    else
        # Short downtime - suppress recovery alert
        log_message "INFO" "SMART_ALERT" "Recovery alert suppressed for $event_type (downtime < threshold)"
    fi

    return 0
}

# Send preventive alerts with longer cooldown (30 minutes)
send_preventive_alert() {
    local alert_type="$1"
    local message="$2"
    local details="$3"

    local alert_file="${ALERT_STATE_DIR}/${alert_type}.preventive_alert"

    # Check cooldown for preventive alerts (longer than regular alerts)
    if [[ -f "$alert_file" ]]; then
        local last_alert_time
        last_alert_time=$(cat "$alert_file")
        local current_time
        current_time=$(date +%s)
        local time_diff
        time_diff=$((current_time - last_alert_time))

        if [[ $time_diff -lt $PREVENTIVE_ALERT_COOLDOWN ]]; then
            log_message "DEBUG" "PREVENTIVE" "Preventive alert $alert_type still in cooldown (${time_diff}s < ${PREVENTIVE_ALERT_COOLDOWN}s)"
            return
        fi
    fi

    # v3.4.0: Send directly (bypass smart alert grace period - preventive alerts have own cooldown)
    _send_alert_direct "$alert_type" "$message" "$details" &

    # Update preventive alert timestamp
    sfu_write_file "$(date +%s)" "$alert_file"
    log_message "INFO" "PREVENTIVE" "Preventive alert sent: $alert_type"
    return 0
}

# Enhanced logging function (v2.5 - logging.sh wrapper)
# This wrapper maintains backward compatibility while using logging.sh v2.1.0 internally
# Preserves alert integration and alerts.log functionality
log_message() {
    local level="$1"
    local component="${2:-CORE}"
    local message="$3"

    # Format message with component prefix for structured logging
    local formatted_message="[$component] $message"

    # Route to appropriate logging.sh function
    case "$level" in
        "INFO")
            log_info "$formatted_message"
            ;;
        "WARNING"|"WARN")
            log_warning "$formatted_message"
            ;;
        "ERROR")
            log_error "$formatted_message"
            ;;
        "CRITICAL")
            log_critical "$formatted_message"
            ;;
        "DEBUG")
            log_debug "$formatted_message"
            ;;
        "SUCCESS")
            # logging.sh has no log_info(), map to log_info with SUCCESS marker
            log_info "[SUCCESS] $formatted_message"
            ;;
        *)
            log_info "$formatted_message"
            ;;
    esac

    # Maintain legacy alerts.log for critical events
    if [[ "$level" == "CRITICAL" || "$level" == "ERROR" ]]; then
        echo "[ALERT] $component: $message" >> "${LOG_FILE%.log}-alerts.log"

        # Send alert for critical issues (component-based routing)
        case "$component" in
            "DSL"|"LTE")
                send_alert "ROUTE_FAILURE" "$component: $message" "Interface: ${component,,}" &
                ;;
            "NETMGR")
                send_alert "NETWORKMANAGER_ERROR" "$message" "Component: NetworkManager Configuration" &
                ;;
            "SUBNET")
                send_alert "SUBNET_ROUTE_MISSING" "$message" "Local network connectivity affected" &
                ;;
            *)
                send_alert "SYSTEM_ERROR" "$message" "Component: $component" &
                ;;
        esac
    fi
    return 0
}

# ============================================================================
# INTERFACE VALIDATION
# ============================================================================

# Check if interface is UP and has carrier (v2.7: Defensive error handling)
check_interface_status() {
    local interface="$1"

    # Defensive: Validate input parameter
    if [[ -z "$interface" ]]; then
        log_message "WARNING" "INTERFACE" "check_interface_status called with empty interface name"
        return 1
    fi

    # Check if interface exists (defensive: suppress errors)
    if ! ip link show "$interface" &>/dev/null; then
        log_message "WARNING" "INTERFACE" "Interface $interface does not exist"
        return 1
    fi

    # Check if interface is UP (defensive: default to empty string if grep fails)
    local link_status=""
    link_status=$(ip link show "$interface" 2>/dev/null | grep -o "state [A-Z]*" || echo "")

    if [[ ! "$link_status" =~ "state UP" ]]; then
        log_message "WARNING" "INTERFACE" "Interface $interface is DOWN - skipping route check (status: $link_status)"
        return 1
    fi

    # Check carrier status (for physical interfaces) (defensive: default to "0")
    local carrier_file="/sys/class/net/$interface/carrier"
    if [[ -f "$carrier_file" ]] && [[ -r "$carrier_file" ]]; then
        local carrier="0"
        carrier=$(cat "$carrier_file" 2>/dev/null || echo "0")
        if [[ "$carrier" != "1" ]]; then
            log_message "WARNING" "INTERFACE" "Interface $interface has no carrier signal (carrier: $carrier)"
            return 1
        fi
    fi

    return 0
}

# Check if specific route exists (v2.7: Defensive error handling)
check_route_exists() {
    local interface="$1"
    local gateway="$2"

    # Defensive: Validate input parameters
    if [[ -z "$interface" ]] || [[ -z "$gateway" ]]; then
        log_message "WARNING" "ROUTE" "check_route_exists called with empty parameters (interface: $interface, gateway: $gateway)"
        return 1
    fi

    # Defensive: Check if route exists with error suppression
    if ip route show 2>/dev/null | grep -q "^default via $gateway dev $interface"; then
        return 0
    else
        return 1
    fi
}

# Optional: Simple gateway ping test (v2.7: Defensive error handling)
test_gateway_reachable() {
    local gateway="$1"
    local interface="$2"

    # Defensive: Validate input parameters
    if [[ -z "$gateway" ]] || [[ -z "$interface" ]]; then
        log_message "WARNING" "PING" "test_gateway_reachable called with empty parameters (gateway: $gateway, interface: $interface)"
        return 1
    fi

    # Defensive: Check if ping command exists
    if ! command -v ping &>/dev/null; then
        log_message "WARNING" "PING" "ping command not available"
        return 1
    fi

    # Defensive: Ping with error suppression
    if ping -c 1 -W 2 -I "$interface" "$gateway" &>/dev/null; then
        return 0
    else
        log_message "WARNING" "PING" "Gateway $gateway not reachable via $interface"
        return 1
    fi
}

# ============================================================================
# ROUTE REPAIR
# ============================================================================

# v2.0 NEW: Counter functions
increment_success_count() {
    local count
    count=$(cat "$REPAIR_SUCCESS_COUNTER" 2>/dev/null || echo "0")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    sfu_write_file "$((count + 1))" "$REPAIR_SUCCESS_COUNTER"
    return 0
}

increment_failure_count() {
    local count
    count=$(cat "$REPAIR_FAILURE_COUNTER" 2>/dev/null || echo "0")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    sfu_write_file "$((count + 1))" "$REPAIR_FAILURE_COUNTER"
    return 0
}

# v2.0 NEW: Repair local subnet route (Enhanced 16.10.2025 - Robust Source-IP Detection)
repair_local_route() {
    local subnet="$1"
    local interface="$2"

    # Enhanced Debug-Logging: Interface state before repair
    log_message "DEBUG" "SUBNET" "Interface $interface state: $(ip link show "$interface" 2>&1 | grep -o 'state [A-Z]*' || echo 'UNKNOWN')"
    local iface_addr_debug
    iface_addr_debug=$(ip addr show "$interface" 2>&1 | head -3 | tail -2 || true)
    log_message "DEBUG" "SUBNET" "Interface $interface ip addr: ${iface_addr_debug:-N/A}"

    # Get source IP for this interface (Multi-Method Fallback for Robustness)
    local source_ip=""
    local detection_method=""

    # Method 1: ip addr show (default)
    source_ip=$(ip addr show "$interface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -1 || true)
    [[ -n "$source_ip" ]] && detection_method="ip-addr-show"

    # Method 2: Fallback via ip -4 addr show (explicit IPv4)
    if [[ -z "$source_ip" ]]; then
        source_ip=$(ip -4 addr show "$interface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1 || true)
        [[ -n "$source_ip" ]] && detection_method="ip-4-addr-show"
    fi

    # Method 3: Fallback via NetworkManager
    if [[ -z "$source_ip" ]]; then
        source_ip=$(nmcli -g IP4.ADDRESS device show "$interface" 2>/dev/null | cut -d/ -f1 || true)
        [[ -n "$source_ip" ]] && detection_method="nmcli-device-show"
    fi

    # Method 4: Last-resort fallback to operator-provided source IPs
    # (only used when the interface is up but Methods 1-3 cannot read its
    # address — e.g. mid-DHCP or a kernel race during boot).
    if [[ -z "$source_ip" ]]; then
        if [[ "$interface" == "${LAN_INTERFACE:-}" && -n "${LAN_SOURCE_IP:-}" ]]; then
            source_ip="$LAN_SOURCE_IP"
        elif [[ "$interface" == "${MGMT_INTERFACE:-}" && -n "${MGMT_SOURCE_IP:-}" ]]; then
            source_ip="$MGMT_SOURCE_IP"
        fi
        [[ -n "$source_ip" ]] && detection_method="config-fallback"
    fi

    if [[ -n "$source_ip" ]]; then
        log_message "INFO" "SUBNET" "Adding missing local route: $subnet dev $interface src $source_ip (method: $detection_method)"

        # Enhanced Retry-Logik: 3 attempts with 500ms delay
        local retry=0
        local max_retries=3
        while [[ $retry -lt $max_retries ]]; do
            if ip route add "$subnet" dev "$interface" scope link src "$source_ip" metric 100 2>/dev/null; then
                log_message "SUCCESS" "SUBNET" "Local route repaired successfully: $subnet (attempt $((retry+1)), method: $detection_method)"
                increment_success_count
                return 0
            fi
            retry=$((retry+1))
            if [[ $retry -lt $max_retries ]]; then
                log_message "DEBUG" "SUBNET" "Route add failed, retrying in 500ms (attempt $((retry+1))/$max_retries)"
                sleep 0.5
            fi
        done

        log_message "ERROR" "SUBNET" "Failed to repair local route after $max_retries attempts: $subnet"
        increment_failure_count
    else
        log_message "ERROR" "SUBNET" "Cannot determine source IP for interface $interface (all 4 methods failed)"
        increment_failure_count
    fi
    return 0
}

# Add missing route with rate limiting
# Take the exclusive route lock against the orchestrator. Returns 1 if it could
# not be had; the caller then skips the mutation entirely.
# shellcheck disable=SC2120  # wait time is optional, defaults to ROUTE_LOCK_WAIT
_acquire_route_lock() {
    local wait_s="${1:-$ROUTE_LOCK_WAIT}"

    if ! eval "exec ${ROUTE_LOCK_FD}>\"\$ROUTE_LOCK_FILE\""; then
        log_message "ERROR" "LOCK" "Cannot open route lock ($ROUTE_LOCK_FILE)"
        return 1
    fi

    if ! flock -w "$wait_s" -x "$ROUTE_LOCK_FD"; then
        eval "exec ${ROUTE_LOCK_FD}>&-"
        return 1
    fi

    return 0
}

# Must run on EVERY exit path of the region — a leaked descriptor holds the lock
# until the next acquire and blocks the orchestrator in the meantime.
_release_route_lock() {
    flock -u "$ROUTE_LOCK_FD" 2>/dev/null || true
    eval "exec ${ROUTE_LOCK_FD}>&-" 2>/dev/null || true
    return 0
}

# Rate-limit marker path for one interface
_repair_marker() {
    echo "${REPAIR_LOCKFILE_PREFIX}-${1}.lock"
}

# Returns 0 when the interface is still rate-limited.
_repair_rate_limited() {
    local interface="$1"
    local marker
    marker="$(_repair_marker "$interface")"

    [[ -f "$marker" ]] || return 1

    local lock_time lock_age
    lock_time=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
    lock_age=$(( $(date +%s) - ${lock_time:-0} ))

    if [[ $lock_age -lt $REPAIR_RATE_LIMIT_SECONDS ]]; then
        log_message "INFO" "REPAIR" "Rate limit active for $interface - skipping repair (${lock_age}s since last repair)"
        return 0
    fi
    return 1
}

# Add a missing default route, rate limited per interface.
#
# $4 = "true" when the caller already holds the route lock. Callers that delete
# routes themselves before repairing must hold it across both steps — otherwise
# the lock could change hands in between and leave the interface with no default
# route at all.
add_missing_route() {
    local interface="$1"
    local gateway="$2"
    local metric="$3"
    local lock_held="${4:-false}"

    if _repair_rate_limited "$interface"; then
        return 1
    fi

    # Verify the gateway is reachable before installing the route. Skipped when
    # the caller holds the lock: it has already run this check, and the ping
    # would stretch the lock region by seconds.
    if [[ "$lock_held" != "true" ]]; then
        if ! test_gateway_reachable "$gateway" "$interface"; then
            log_message "ERROR" "REPAIR" "Skipping route addition - gateway $gateway unreachable via $interface"
            increment_failure_count
            return 1
        fi

        if ! _acquire_route_lock; then
            log_message "INFO" "REPAIR" "Route lock busy (failover in progress) - skipping repair of $interface"
            return 1
        fi
    fi

    # Try to add the route
    log_message "INFO" "REPAIR" "Adding missing route: default via $gateway dev $interface metric $metric"
    local add_ok=1
    if ip route add default via "$gateway" dev "$interface" metric "$metric" 2>/dev/null; then
        add_ok=0
    fi

    # Release here in ALL cases, including when the caller took the lock:
    # everything below forks (send_recovery_alert starts the Mattermost curl with
    # '&') and would otherwise carry the descriptor out of the region. The
    # caller's own release afterwards is a no-op.
    _release_route_lock

    if [[ $add_ok -eq 0 ]]; then
        log_message "SUCCESS" "REPAIR" "Successfully added route for $interface"

        # v3.1.0: Use smart recovery alert (suppresses short downtimes)
        local event_type="${interface^^}_ROUTE_MISSING"  # DSL → DSL_ROUTE_MISSING
        send_recovery_alert "$event_type" "✅ Route successfully restored" "Interface: $interface, Gateway: $gateway, Metric: $metric"

        touch "$(_repair_marker "$interface")"
        increment_success_count
        return 0
    fi

    log_message "WARNING" "REPAIR" "Failed to add route for $interface - may already exist"
    increment_failure_count
    return 1
}

# ============================================================================
# NETWORKMANAGER INTEGRATION
# ============================================================================

# Snapshot a NetworkManager connection profile before any change so the route
# can be restored if the change goes wrong.
backup_networkmanager_connection() {
    local connection_name="$1"
    local backup_dir="${STATE_DIR}/networkmanager-backups"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/${connection_name}_${timestamp}.backup"

    # Create backup directory if it doesn't exist
    mkdir -p "$backup_dir"

    log_message "INFO" "NETMGR" "Creating backup of connection: $connection_name"

    if nmcli connection show "$connection_name" > "$backup_file" 2>/dev/null; then
        log_message "SUCCESS" "NETMGR" "Connection backup created: $backup_file"

        # Keep only last 5 backups for this connection
        ls -t "${backup_dir}/${connection_name}_"*.backup 2>/dev/null | tail -n +6 | xargs -r rm

        return 0
    else
        log_message "ERROR" "NETMGR" "Failed to create connection backup"
        return 1
    fi
}

# v2.0 NEW: Check NetworkManager configuration (never-default + route metrics)
check_networkmanager_configuration() {
    log_message "INFO" "NETMGR" "Checking NetworkManager configuration (never-default + route metrics)"

    if ! command -v nmcli &>/dev/null; then
        log_message "WARNING" "NETMGR" "NetworkManager CLI not available - skipping checks"
        return 1
    fi

    # Define expected metrics per connection type (active_wan-aware)
    local expected_primary_metric
    expected_primary_metric=$(get_expected_primary_metric)
    local -A expected_metrics=(
        ["$WAN_PRIMARY_CONNECTION"]="$expected_primary_metric"  # 50 normal, 500 during failover
        ["$LTE_CONNECTION"]="200"                               # LTE always backup
    )

    # Check each WAN connection
    for connection in "$WAN_PRIMARY_CONNECTION" "$LTE_CONNECTION"; do
        log_message "DEBUG" "NETMGR" "Checking connection: $connection"

        # Get connection settings
        local never_default
        never_default=$(nmcli -t -f ipv4.never-default connection show "$connection" 2>/dev/null | cut -d: -f2)
        local route_metric
        route_metric=$(nmcli -t -f ipv4.route-metric connection show "$connection" 2>/dev/null | cut -d: -f2)
        local expected_metric="${expected_metrics[$connection]}"

        # Check never-default setting
        case "$connection" in
            "$WAN_PRIMARY_CONNECTION")
                if [[ "$never_default" == "yes" ]]; then
                    log_message "CRITICAL" "NETMGR" "$connection has never-default=yes - blocks internet access!"
                    send_alert "NETWORKMANAGER_CRITICAL" "WAN-Primary misconfigured!" "Connection needs never-default=no" &

                    # Auto-repair never-default issue
                    log_message "INFO" "NETMGR" "Auto-repairing never-default configuration..."
                    backup_networkmanager_connection "$connection"

                    if nmcli connection modify "$connection" ipv4.never-default no 2>/dev/null; then
                        log_message "SUCCESS" "NETMGR" "Auto-repair successful: never-default=no"

                        # Reactivate connection
                        if nmcli connection down "$connection" 2>/dev/null && sleep 2 && nmcli connection up "$connection" 2>/dev/null; then
                            log_message "SUCCESS" "NETMGR" "Connection reactivated successfully"
                            increment_success_count
                        else
                            log_message "WARNING" "NETMGR" "Connection reactivation failed"
                            increment_failure_count
                        fi
                    else
                        log_message "ERROR" "NETMGR" "Auto-repair failed - manual intervention required"
                        increment_failure_count
                    fi
                else
                    log_message "DEBUG" "NETMGR" "$connection never-default configuration OK: $never_default"
                fi
                ;;

            "$LTE_CONNECTION")
                if [[ "$never_default" != "yes" ]]; then
                    log_message "WARNING" "NETMGR" "$connection should have never-default=yes to prevent auto-routes"
                    send_alert "NETWORKMANAGER_WARNING" "LTE connection config issue" "Should have never-default=yes" &

                    # Auto-repair LTE never-default
                    log_message "INFO" "NETMGR" "Auto-repairing LTE never-default configuration..."
                    backup_networkmanager_connection "$connection"

                    if nmcli connection modify "$connection" ipv4.never-default yes 2>/dev/null; then
                        log_message "SUCCESS" "NETMGR" "LTE auto-repair successful: never-default=yes"
                        increment_success_count
                    else
                        log_message "ERROR" "NETMGR" "LTE auto-repair failed"
                        increment_failure_count
                    fi
                else
                    log_message "DEBUG" "NETMGR" "$connection never-default configuration OK: $never_default"
                fi
                ;;
        esac

            # Check route metric settings
        if [[ -n "$route_metric" && "$route_metric" != "$expected_metric" ]]; then
            log_message "WARNING" "NETMGR" "$connection metric mismatch: $route_metric (expected: $expected_metric, active_wan: $(cat /run/linux-dual-wan-failover/wan-state/active_wan 2>/dev/null))"
            # Auto-repair NM metric to match active_wan state (v3.6.0: was warning-only)
            if nmcli connection modify "$connection" ipv4.route-metric "$expected_metric" 2>/dev/null; then
                log_message "SUCCESS" "NETMGR" "Auto-repaired $connection metric: $route_metric -> $expected_metric"
                send_alert "ROUTE_METRIC_REPAIRED" "NM metric corrected" "Connection: $connection, Was: $route_metric, Now: $expected_metric" &
                increment_success_count
            else
                log_message "ERROR" "NETMGR" "Failed to auto-repair $connection metric"
                send_alert "ROUTE_METRIC_WARNING" "NM metric repair failed" "Connection: $connection, Got: $route_metric, Expected: $expected_metric" &
                increment_failure_count
            fi
        else
            log_message "DEBUG" "NETMGR" "$connection route-metric OK: $route_metric"
        fi
    done

    return 0
}

# Legacy function name for backward compatibility
check_networkmanager_never_default() {
    check_networkmanager_configuration
    return 0
}

# ============================================================================
# CONFLICT RESOLUTION
# ============================================================================

# v2.0 NEW: Detect metric conflicts with automatic cleanup
detect_metric_conflicts() {
    log_message "INFO" "CONFLICT" "Checking for route metric conflicts"

    # Get all default routes with their details
    local routes_raw
    routes_raw=$(ip route show | grep "^default via")
    local -A metric_routes
    local conflict_found=false

    # Parse routes and group by metric
    while IFS= read -r route; do
        [[ -n "$route" ]] || continue
        local metric
        metric=$(grep -o "metric [0-9]*" <<< "$route" | awk '{print $2}')
        [[ -n "$metric" ]] || continue

        if [[ -n "${metric_routes[$metric]:-}" ]]; then
            log_message "ERROR" "CONFLICT" "Metric conflict detected: Multiple routes with metric $metric"
            log_message "INFO" "CONFLICT" "Conflicting routes: ${metric_routes[$metric]} AND $route"
            conflict_found=true

            # Auto-cleanup logic for known conflicts
            cleanup_conflicting_routes "$metric" "${metric_routes[$metric]}" "$route"
        else
            metric_routes[$metric]="$route"
        fi
    done <<< "$routes_raw"

    if [[ "$conflict_found" == "false" ]]; then
        log_message "DEBUG" "CONFLICT" "No metric conflicts detected"
    fi

    # v2.1 NEW: Preventive monitoring for potential issues
    check_preventive_issues
    return 0
}

# New function: Cleanup conflicting routes based on the failover host standards
cleanup_conflicting_routes() {
    local metric="$1"
    local route1="$2"
    local route2="$3"

    log_message "INFO" "CLEANUP" "Starting automatic cleanup for metric $metric conflicts"

    # the failover host metric standards (from GLOSSAR.md):
    # DSL should be metric 50, LTE should be metric 200
    # NetworkManager DHCP routes typically use metric 100

    case "$metric" in
        "100")
            # Handle metric 100 conflicts (common with NetworkManager DHCP + manual routes)
            local lte_route_found=""
            # Identify LTE route with wrong metric
            if echo "$route1" | grep -q "dev $LTE_INTERFACE.*$LTE_GATEWAY"; then
                lte_route_found="$route1"
            elif echo "$route2" | grep -q "dev $LTE_INTERFACE.*$LTE_GATEWAY"; then
                lte_route_found="$route2"
            fi

            # Remove LTE route with wrong metric 100 (should be 200)
            if [[ -n "$lte_route_found" ]]; then
                log_message "WARNING" "CLEANUP" "Removing LTE route with incorrect metric 100 (should be 200)"
                local gateway
                gateway=$(awk '{print $3}' <<< "$lte_route_found")
                local interface
                interface=$(grep -o "dev [^ ]*" <<< "$lte_route_found" | awk '{print $2}')

                # Delete and re-add belong in ONE lock region; the alerts fire
                # afterwards because they start curl with '&' and would inherit
                # the lock descriptor.
                local lock_ok=1 del_ok=1 add_ok=1 gw_reachable=1
                if _acquire_route_lock; then
                    lock_ok=0
                    if ip route del default via "$gateway" dev "$interface" metric 100 2>/dev/null; then
                        del_ok=0
                        if test_gateway_reachable "$gateway" "$interface"; then
                            gw_reachable=0
                            ip route add default via "$gateway" dev "$interface" metric 200 2>/dev/null && add_ok=0
                        fi
                    fi
                    _release_route_lock
                fi

                if [[ $lock_ok -ne 0 ]]; then
                    log_message "INFO" "CLEANUP" "Route lock busy (failover in progress) - skipping metric cleanup"
                elif [[ $del_ok -eq 0 ]]; then
                    log_message "SUCCESS" "CLEANUP" "Removed incorrect LTE route: $lte_route_found"
                    send_alert "ROUTE_CLEANUP" "✅ Metric conflict resolved" "Removed LTE ($LTE_INTERFACE) route with wrong metric 100" &
                    increment_success_count

                    if [[ $gw_reachable -eq 0 ]]; then
                        if [[ $add_ok -eq 0 ]]; then
                            log_message "SUCCESS" "CLEANUP" "Re-added LTE route with correct metric 200"
                            send_alert "ROUTE_RECOVERED" "✅ LTE ($LTE_INTERFACE) route corrected" "Metric: 100 → 200" &
                        else
                            log_message "WARNING" "CLEANUP" "Failed to re-add LTE route with metric 200"
                        fi
                    fi
                else
                    log_message "ERROR" "CLEANUP" "Failed to remove incorrect LTE route"
                    increment_failure_count
                fi
            fi
            ;;

        "50"|"200")
            # These are correct metrics - investigate why we have duplicates
            log_message "WARNING" "CLEANUP" "Conflict in expected metric range ($metric) - manual investigation needed"
            log_message "INFO" "CLEANUP" "Routes: $route1 | $route2"
            send_alert "ROUTE_CONFLICT_MANUAL" "⚠️ Manual route conflict" "Metric $metric has duplicates - check manually" &
            ;;

        *)
            # Unknown metric conflict
            log_message "WARNING" "CLEANUP" "Unknown metric conflict ($metric) - logging for analysis"
            send_alert "ROUTE_CONFLICT_UNKNOWN" "❓ Unknown metric conflict" "Metric: $metric needs investigation" &
            ;;
    esac
    return 0
}

# v2.2 NEW: Enhanced duplicate route cleanup for different metrics
cleanup_interface_duplicate_routes() {
    local interface="$1"

    # Get all default routes for this interface
    local routes
    routes=$(ip route show | grep "^default via.*dev $interface" || true)
    [[ -z "$routes" ]] && return 0  # No routes found, nothing to do

    local route_count
    route_count=$(echo "$routes" | wc -l)

    if [[ "$route_count" -gt 1 ]]; then
        log_message "WARNING" "DUPLICATE" "Found $route_count default routes for $interface - cleaning up"

        # Find the route with the lowest metric to keep
        local lowest_metric=999999
        local route_to_keep=""

        while IFS= read -r route; do
            [[ -n "$route" ]] || continue
            local metric
            metric=$(grep -o "metric [0-9]*" <<< "$route" | awk '{print $2}')
            metric=${metric:-1024}  # Default metric if not specified

            if [[ "$metric" -lt "$lowest_metric" ]]; then
                lowest_metric="$metric"
                route_to_keep="$route"
            fi
        done <<< "$routes"

        # Delete all routes except the one with lowest metric
        while IFS= read -r route; do
            [[ -n "$route" ]] || continue
            if [[ "$route" != "$route_to_keep" ]]; then
                local gateway
                gateway=$(awk '{print $3}' <<< "$route")
                local metric
                metric=$(grep -o "metric [0-9]*" <<< "$route" | awk '{print $2}')

                # Deleting default routes must not overlap the orchestrator's
                # metric swap. Region kept tight around the ip command; the alert
                # forks and therefore fires after the release.
                local del_ok=1
                if _acquire_route_lock; then
                    if [[ -n "$metric" ]]; then
                        ip route del default via "$gateway" dev "$interface" metric "$metric" 2>/dev/null && del_ok=0
                    else
                        ip route del default via "$gateway" dev "$interface" 2>/dev/null && del_ok=0
                    fi
                    _release_route_lock
                else
                    log_message "INFO" "CLEANUP" "Route lock busy (failover in progress) - skipping duplicate cleanup"
                fi

                if [[ $del_ok -eq 0 ]]; then
                    log_message "SUCCESS" "CLEANUP" "Removed duplicate route: $route"
                    if [[ -n "$metric" ]]; then
                        send_alert "ROUTE_CLEANUP" "✅ Duplicate route removed" "Interface: $interface
Removed: metric $metric" &
                    else
                        send_alert "ROUTE_CLEANUP" "✅ Duplicate route removed" "Interface: $interface" &
                    fi
                fi
            fi
        done <<< "$routes"

        log_message "INFO" "CLEANUP" "Kept primary route: $route_to_keep"
        return 0
    fi

    return 1
}

# v2.1 NEW: Preventive issue detection (warns before problems occur)
check_preventive_issues() {
    local route_count
    route_count=$(ip route show | grep -c "^default via")

    # Preventive Alert: Too many default routes
    if [[ $route_count -gt 3 ]]; then
        log_message "WARNING" "PREVENTIVE" "High default route count: $route_count routes detected"
        send_preventive_alert "HIGH_ROUTE_COUNT" "⚠️ High default route count" "Found $route_count routes - may cause conflicts"
    fi

    # Preventive Alert: NetworkManager metric drift detection
    local wan_metric
    wan_metric=$(nmcli -t -f ipv4.route-metric connection show "$WAN_PRIMARY_CONNECTION" 2>/dev/null | cut -d: -f2)
    if [[ "$wan_metric" == "100" ]]; then
        log_message "WARNING" "PREVENTIVE" "WAN-Primary using metric 100 - conflict risk with NetworkManager DHCP"
        send_preventive_alert "WAN_METRIC_RISK" "⚠️ WAN Metric conflict risk" "WAN-Primary metric=100 may cause DHCP route conflicts"
    fi

    # Preventive Alert: Multiple routes per interface
    local eth0_routes
    eth0_routes=$(ip route show | grep -c "^default via.*dev eth0")
    local lte_routes
    lte_routes=$(ip route show | grep -c "^default via.*dev $LTE_INTERFACE")

    if [[ $eth0_routes -gt 1 ]]; then
        log_message "WARNING" "PREVENTIVE" "Multiple eth0 routes detected: $eth0_routes routes"
        send_preventive_alert "ETH0_MULTIPLE" "⚠️ Multiple DSL (eth0/WAN) routes" "Found $eth0_routes routes for eth0 - potential conflict"
    fi

    if [[ $lte_routes -gt 1 ]]; then
        log_message "WARNING" "PREVENTIVE" "Multiple $LTE_INTERFACE routes detected: $lte_routes routes"
        send_preventive_alert "LTE_MULTIPLE" "⚠️ Multiple LTE ($LTE_INTERFACE) routes" "Found $lte_routes routes for $LTE_INTERFACE - potential conflict"
    fi
    return 0
}

# ============================================================================
# LTE RECOVERY & STATE
# ============================================================================

# v3.3.0: Helper Functions for LTE Availability State Management
# Write LTE availability state to persistent file (for status command access)
write_lte_state() {
    local state="$1"
    log_message "INFO" "STATE" "Writing LTE state: $state to $LTE_AVAILABLE_STATE"
    # Use secure-file-utils for atomic write (CONTENT TARGET [PERMS])
    # Permissions 644 allow status command to read without sudo
    sfu_write_file "$state" "$LTE_AVAILABLE_STATE" "644" || {
        log_message "WARNING" "STATE" "Failed to write LTE state file"
        return 1
    }
    log_message "INFO" "STATE" "LTE state file written successfully"
    return 0
}

# Read LTE availability state from persistent file
# Returns: "true" or "false" (defaults to "false" if file missing)
read_lte_state() {
    if [[ -f "$LTE_AVAILABLE_STATE" ]]; then
        cat "$LTE_AVAILABLE_STATE" 2>/dev/null || echo "false"
    else
        echo "false"
    fi
}

# v3.3.0: Periodic LTE Recovery Check
# Called from monitoring loop - attempts to re-detect LTE interface
# Returns 0 if recovery successful, 1 if still unavailable
check_lte_recovery() {
    # Skip if LTE is already available
    if [[ "$LTE_AVAILABLE" == "true" ]]; then
        return 0
    fi

    log_message "INFO" "LTE_RECOVERY" "Checking if LTE interface became available..."

    # 1. Check if interface exists now
    if [[ -d "/sys/class/net/$LTE_INTERFACE" ]]; then
        log_message "SUCCESS" "LTE_RECOVERY" "LTE interface $LTE_INTERFACE detected! Exiting DSL-Only mode"
        LTE_AVAILABLE=true
        write_lte_state "true"

        # Send recovery notification
        send_alert "LTE_RECOVERED" \
            "✅ Route Guardian: LTE Recovered" \
            "LTE modem ($LTE_INTERFACE) is now available

Resuming full dual-WAN monitoring.

Interface details:
\`\`\`
$(ip addr show "$LTE_INTERFACE" 2>/dev/null || echo "Interface up but no IP yet")
\`\`\`" &

        return 0
    fi

    # 2. Attempt NetworkManager connection activation
    log_message "INFO" "LTE_RECOVERY" "Interface not found - attempting NetworkManager activation"
    if nmcli connection up "$LTE_CONNECTION" >/dev/null 2>&1; then
        sleep 3  # Give interface time to appear

        if [[ -d "/sys/class/net/$LTE_INTERFACE" ]]; then
            log_message "SUCCESS" "LTE_RECOVERY" "LTE interface activated via NetworkManager!"
            LTE_AVAILABLE=true
            write_lte_state "true"

            send_alert "LTE_RECOVERED" \
                "✅ Route Guardian: LTE Activated" \
                "LTE modem activated via NetworkManager connection '$LTE_CONNECTION'

Resuming full dual-WAN monitoring." &

            return 0
        else
            log_message "INFO" "LTE_RECOVERY" "NetworkManager activation succeeded but interface not visible yet"
        fi
    else
        log_message "DEBUG" "LTE_RECOVERY" "NetworkManager activation failed - LTE still unavailable"
    fi

    return 1
}

# v3.3.0: Enhanced Pre-Flight Checks with LTE Graceful Degradation
# Handles DSL (critical) and LTE (optional) interface detection
# Returns: 0 (always - service continues even without LTE)
enhanced_preflight_checks() {
    log_message "INFO" "PREFLIGHT" "Starting enhanced pre-flight checks (30s timeout for LTE)"

    # ============================================================================
    # 1. Check DSL Interface (CRITICAL - Service fails if missing)
    # ============================================================================
    log_message "INFO" "PREFLIGHT" "Checking critical DSL interface: $DSL_INTERFACE"
    local dsl_wait=0
    while [[ $dsl_wait -lt 10 ]]; do
        if [[ -d "/sys/class/net/$DSL_INTERFACE" ]]; then
            log_message "INFO" "PREFLIGHT" "DSL interface $DSL_INTERFACE exists ✓"
            break
        fi
        log_message "WARNING" "PREFLIGHT" "DSL interface $DSL_INTERFACE not found (attempt $((dsl_wait+1))/10)"
        sleep 1
        dsl_wait=$((dsl_wait+1))
    done

    if [[ ! -d "/sys/class/net/$DSL_INTERFACE" ]]; then
        log_message "ERROR" "PREFLIGHT" "Critical DSL interface $DSL_INTERFACE missing after 10s - service cannot function"
        send_alert "PREFLIGHT_CRITICAL" "🔴 Route Guardian cannot start" \
            "DSL interface $DSL_INTERFACE missing - this is a hardware failure" &
        exit 1  # Hard exit - service cannot function without DSL
    fi

    # ============================================================================
    # 2. Check DSL IPv4 (CRITICAL - Wait up to 10s)
    # ============================================================================
    if ! ip -4 addr show "$DSL_INTERFACE" 2>/dev/null | grep -q "inet "; then
        log_message "WARNING" "PREFLIGHT" "$DSL_INTERFACE has no IPv4 yet - waiting up to 10s"
        for i in {1..10}; do
            sleep 1
            if ip -4 addr show "$DSL_INTERFACE" 2>/dev/null | grep -q "inet "; then
                local eth0_ip
                eth0_ip=$(ip -4 addr show "$DSL_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
                log_message "INFO" "PREFLIGHT" "$DSL_INTERFACE IPv4 detected after ${i}s: $eth0_ip ✓"
                break
            fi
        done

        # Final check after timeout
        if ! ip -4 addr show "$DSL_INTERFACE" 2>/dev/null | grep -q "inet "; then
            log_message "WARNING" "PREFLIGHT" "$DSL_INTERFACE still has no IPv4 after 10s - proceeding anyway (may cause route issues)"
        fi
    else
        local eth0_ip
        eth0_ip=$(ip -4 addr show "$DSL_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        log_message "INFO" "PREFLIGHT" "$DSL_INTERFACE IPv4 ready: $eth0_ip ✓"
    fi

    # ============================================================================
    # 3. Check LTE Interface (NON-CRITICAL - Enable Fallback Mode if missing)
    # ============================================================================
    log_message "INFO" "PREFLIGHT" "Checking LTE interface: $LTE_INTERFACE (30s timeout)"
    local lte_wait=0
    local lte_found=false

    while [[ $lte_wait -lt 30 ]]; do
        if [[ -d "/sys/class/net/$LTE_INTERFACE" ]]; then
            log_message "INFO" "PREFLIGHT" "LTE interface $LTE_INTERFACE exists after ${lte_wait}s ✓"
            lte_found=true
            LTE_AVAILABLE=true
            write_lte_state "true"
            break
        fi

        # Attempt NetworkManager connection activation every 10 seconds
        if [[ $((lte_wait % 10)) -eq 0 ]] && [[ $lte_wait -gt 0 ]]; then
            log_message "INFO" "PREFLIGHT" "Attempting to activate NetworkManager connection: $LTE_CONNECTION"
            if nmcli connection up "$LTE_CONNECTION" 2>&1 | tee -a "$LOG_FILE"; then
                log_message "INFO" "PREFLIGHT" "NetworkManager activation command sent - checking interface..."
                sleep 3  # Give interface time to appear
                if [[ -d "/sys/class/net/$LTE_INTERFACE" ]]; then
                    log_message "SUCCESS" "PREFLIGHT" "LTE interface $LTE_INTERFACE activated via NetworkManager ✓"
                    lte_found=true
                    LTE_AVAILABLE=true
                    write_lte_state "true"
                    break
                fi
            else
                log_message "WARNING" "PREFLIGHT" "NetworkManager activation failed - continuing wait"
            fi
        fi

        sleep 1
        lte_wait=$((lte_wait+1))
    done

    # ============================================================================
    # 4. Handle LTE Unavailability (Graceful Degradation)
    # ============================================================================
    if [[ "$lte_found" == "false" ]]; then
        log_message "WARNING" "PREFLIGHT" "LTE interface $LTE_INTERFACE not found after 30s"
        log_message "WARNING" "PREFLIGHT" "Entering DSL-Only Fallback Mode - LTE monitoring disabled"
        LTE_AVAILABLE=false
        write_lte_state "false"

        # Send one-time alert about DSL-Only mode
        send_alert "LTE_MISSING_FALLBACK" \
            "⚠️ Route Guardian: DSL-Only Mode" \
            "LTE modem ($LTE_INTERFACE) not detected after 30s

Service will continue monitoring DSL routes only.
Periodic recovery checks every 60s.

Possible causes:
- Netgear LM1200 not powered
- USB connection issue
- Driver not loaded
- NetworkManager connection '$LTE_CONNECTION' misconfigured

To diagnose:
\`\`\`
nmcli device status
nmcli connection show
dmesg | grep -i usb | tail -20
\`\`\`" &
    fi

    log_message "INFO" "PREFLIGHT" "Pre-flight checks complete - LTE_AVAILABLE=$LTE_AVAILABLE"
    return 0
}

# ============================================================================
# ROUTE MONITORING
# ============================================================================

# v2.0 NEW: Check local subnet routes
check_local_subnet_routes() {
    log_message "INFO" "SUBNET" "Checking local subnet routes"

    local subnets=(
        "$LAN_SUBNET:$LAN_INTERFACE"
        "$MGMT_SUBNET:$MGMT_INTERFACE"
    )

    for subnet_def in "${subnets[@]}"; do
        local subnet="${subnet_def%:*}"
        local interface="${subnet_def#*:}"
        # Check if route exists for this subnet
        # Fixed: More flexible pattern to match kernel-managed routes with "proto kernel scope link"
        if ! ip route show | grep -qE "^${subnet}[[:space:]]+dev[[:space:]]+${interface}"; then
            log_message "WARNING" "SUBNET" "Local subnet route missing: $subnet via $interface"
            repair_local_route "$subnet" "$interface"
        else
            log_message "DEBUG" "SUBNET" "Local subnet route OK: $subnet via $interface"
        fi
    done
    return 0
}

# Failover-orchestration pause check, extracted from monitor_default_routes()
# so comprehensive_route_health_check() can gate the ENTIRE cycle —
# duplicate-cleanup, NM-metric-repair and conflict-resolution also mutate
# routes and must not race routing.sh's metric swap.
# Returns 0 = lock active (pause this cycle), 1 = no valid lock (proceed).
_failover_lock_active() {
    [[ -f /run/failover-in-progress.lock ]] || return 1

    # Parse lockfile format: PID_TIMESTAMP (routing.sh safe_route_change /
    # nmcli-failover-monitor emergency path)
    local lockfile_content
    lockfile_content=$(cat /run/failover-in-progress.lock 2>/dev/null)

    if [[ -n "$lockfile_content" && "$lockfile_content" =~ ^[0-9]+_[0-9]+$ ]]; then
        # Extract timestamp (format: PID_TIMESTAMP)
        local lock_timestamp
        lock_timestamp=$(cut -d_ -f2 <<< "$lockfile_content")
        local lock_age
        lock_age=$(( $(date +%s) - lock_timestamp ))

        if [[ $lock_age -gt 60 ]]; then
            # Stale lockfile detected (>60s old) - likely from crashed cleanup job
            # lockfile_content IS the failover Event-ID → log it as a greppable
            # field (the guardian "span" of the trace).
            log_message "WARNING" "FAILOVER" "Stale lockfile detected (${lock_age}s old, content: $lockfile_content) - removing and resuming [FAILOVER_EVENT_ID=$lockfile_content]"
            send_alert "STALE_LOCKFILE" "⚠️ Stale failover lockfile removed" "Age: ${lock_age}s, Lockfile: $lockfile_content" &
            rm -f /run/failover-in-progress.lock 2>/dev/null || true
            return 1  # Continue with normal route checks after cleanup
        fi

        # Valid lockfile - pause route checks
        log_message "INFO" "FAILOVER" "Failover in progress - skipping route checks (lockfile age: ${lock_age}s) [FAILOVER_EVENT_ID=$lockfile_content]"
        return 0
    fi

    # Malformed lockfile (legacy format or corrupted) - log and continue
    log_message "WARNING" "FAILOVER" "Malformed lockfile detected (content: $lockfile_content) - removing"
    rm -f /run/failover-in-progress.lock 2>/dev/null || true
    return 1
}

# Main monitoring function for default routes (v1.6 compatible)
# Lockfile check lives in _failover_lock_active(), called cycle-wide from
# comprehensive_route_health_check().
monitor_default_routes() {
    local dsl_ok=false
    local lte_ok=false

    # Check DSL interface and route (active_wan-aware: metric 50 normal, 500 during failover)
    if check_interface_status "$DSL_INTERFACE"; then
        local expected_metric
        expected_metric=$(get_expected_primary_metric)

        # REGEX: use ( |$) to avoid "metric 50" matching "metric 500"
        if ip route show | grep -qE "^default via $DSL_GATEWAY dev $DSL_INTERFACE.*metric ${expected_metric}( |$)"; then
            dsl_ok=true
        else
            log_message "WARNING" "DSL" "DSL route missing or wrong metric (expected: $expected_metric, active_wan: $(cat /run/linux-dual-wan-failover/wan-state/active_wan 2>/dev/null))"
            send_alert "DSL_ROUTE_MISSING" "🔴 DSL (eth0/WAN) route needs repair" "Expected metric: $expected_metric, Interface: $DSL_INTERFACE" &
            # Only repair if gateway is reachable
            if test_gateway_reachable "$DSL_GATEWAY" "$DSL_INTERFACE"; then
                # Delete and re-add must sit in ONE lock region. Otherwise the
                # lock could pass to the orchestrator in between and the primary
                # would be left without any default route until the next cycle.
                # Hence the skip decision happens before the delete, not after.
                if _acquire_route_lock; then
                    # Remove any existing DSL default routes with wrong metric
                    while ip route del default dev "$DSL_INTERFACE" 2>/dev/null; do
                        :
                    done
                    add_missing_route "$DSL_INTERFACE" "$DSL_GATEWAY" "$expected_metric" "true"
                    _release_route_lock
                else
                    log_message "INFO" "DSL" "Route lock busy (failover in progress) - skipping primary repair"
                fi
            fi
        fi
    fi

    # v3.3.0: Check LTE interface and route (ONLY if LTE available)
    if [[ "$LTE_AVAILABLE" == "true" ]]; then
        if check_interface_status "$LTE_INTERFACE"; then
            if check_route_exists "$LTE_INTERFACE" "$LTE_GATEWAY"; then
                lte_ok=true
            else
                log_message "WARNING" "LTE" "LTE route missing"
                send_alert "LTE_ROUTE_MISSING" "🔴 LTE ($LTE_INTERFACE) backup route lost!" "Gateway: $LTE_GATEWAY, Interface: $LTE_INTERFACE" &

                # v2.4 NEW: LTE Recovery Logic
                # Try to diagnose and recover LTE connection before adding route
                if ! test_gateway_reachable "$LTE_GATEWAY" "$LTE_INTERFACE"; then
                    log_message "INFO" "LTE" "LTE Gateway unreachable - attempting recovery"

                    # Step 1: Check if NetworkManager connection is active
                    local lte_conn_state
                    lte_conn_state=$(nmcli -t -f STATE connection show "$LTE_CONNECTION" 2>/dev/null | head -1 || echo "unknown")
                    if [[ "$lte_conn_state" != "activated" ]]; then
                        log_message "INFO" "LTE" "LTE connection not activated - triggering connection restart"
                        send_alert "LTE_CONNECTION_RESTART" "🔄 LTE Connection Restart" "Connection: $LTE_CONNECTION was inactive, restarting..." &

                        # Restart LTE connection
                        nmcli connection down "$LTE_CONNECTION" 2>/dev/null || true
                        sleep 3
                        nmcli connection up "$LTE_CONNECTION" 2>/dev/null || log_message "ERROR" "LTE" "Failed to restart LTE connection"
                        sleep 5

                        # Check if gateway is now reachable
                        if test_gateway_reachable "$LTE_GATEWAY" "$LTE_INTERFACE"; then
                            log_message "SUCCESS" "LTE" "LTE Gateway recovered after connection restart"

                            # v3.1.0: Use smart recovery alert
                            send_recovery_alert "LTE_CONNECTION_RESTART" "✅ LTE Connection recovered" "Gateway: $LTE_GATEWAY now reachable"
                        fi
                    fi

                    # v3.5.0: ZTE PIN automation removed (Netgear LM1200 migration v2.10)
                    # Netgear LM1200 does not require PIN management
                fi

                # Only add route if gateway is now reachable (after recovery attempts)
                if test_gateway_reachable "$LTE_GATEWAY" "$LTE_INTERFACE"; then
                    add_missing_route "$LTE_INTERFACE" "$LTE_GATEWAY" 200  # Fixed metric for LTE
                else
                    log_message "WARNING" "LTE" "LTE Gateway still unreachable after recovery attempts"
                fi
            fi
        fi
    else
        # v3.3.0: LTE unavailable - skip all LTE checks
        log_message "DEBUG" "LTE" "LTE monitoring disabled (DSL-Only mode)"
    fi

    # Count total routes
    local total_routes
    total_routes=$(ip route show | grep -c "^default via" || echo "0")
    [[ "$total_routes" =~ ^[0-9]+$ ]] || total_routes=0

    # Default-route vacuum detection (anti-failover-stall safety net).
    # If neither primary nor backup has registered a default route, the
    # routing table is in a vacuum state — independent of active_wan or
    # score heuristics. This can happen in failover-stall edge cases when
    # the orchestrator detected the failure but failed to install the
    # backup route (e.g. _swap_primary_metric failed before the carrier
    # check was added in routing.sh). Emergency restore prefers the backup
    # (typical when primary is Layer-1 dead), with primary as fallback.
    # The lockfile coordination above still pauses this loop during
    # legitimate failover transitions, so there is no race with the
    # orchestrator.
    if [[ "$total_routes" -eq 0 ]]; then
        log_message "CRITICAL" "VACUUM" "Routing vacuum detected: no default route in main table"

        if [[ "$LTE_AVAILABLE" == "true" ]] \
           && check_interface_status "$LTE_INTERFACE" \
           && test_gateway_reachable "$LTE_GATEWAY" "$LTE_INTERFACE"; then
            log_message "WARNING" "VACUUM" "Emergency restore: default via $LTE_GATEWAY dev $LTE_INTERFACE metric 200"
            send_alert "ROUTE_VACUUM_RECOVERED" \
                "🚨 Routing vacuum recovered via backup" \
                "No default route in main table. $LTE_INTERFACE functional → default via $LTE_GATEWAY dev $LTE_INTERFACE restored." &
            add_missing_route "$LTE_INTERFACE" "$LTE_GATEWAY" 200
        elif check_interface_status "$DSL_INTERFACE" \
             && test_gateway_reachable "$DSL_GATEWAY" "$DSL_INTERFACE"; then
            log_message "WARNING" "VACUUM" "Emergency restore: default via $DSL_GATEWAY dev $DSL_INTERFACE metric 50"
            send_alert "ROUTE_VACUUM_RECOVERED" \
                "🚨 Routing vacuum recovered via primary" \
                "No default route in main table. $DSL_INTERFACE functional → default via $DSL_GATEWAY dev $DSL_INTERFACE restored." &
            add_missing_route "$DSL_INTERFACE" "$DSL_GATEWAY" 50
        else
            log_message "CRITICAL" "VACUUM" "Routing vacuum + no functional WAN — manual intervention required"
            send_alert "ROUTE_VACUUM_CRITICAL" \
                "🚨 Routing vacuum + no functional WAN" \
                "No default route, neither $DSL_INTERFACE nor $LTE_INTERFACE reachable — manual intervention required!" &
        fi
    fi

    log_message "INFO" "STATUS" "Route status: DSL=$dsl_ok, LTE=${LTE_AVAILABLE}:${lte_ok}, Total routes=$total_routes"
    return 0
}

# v2.0 NEW: Comprehensive route health check
comprehensive_route_health_check() {
    # Gate the WHOLE cycle on the failover lockfile — every step below
    # mutates routes or NM metrics and must not race the orchestrator.
    # (Previously only monitor_default_routes() honored the lockfile;
    # duplicate-cleanup, NM-metric-repair and conflict-resolution kept
    # running during an in-flight failover.)
    if _failover_lock_active; then
        return 0
    fi

    log_message "INFO" "HEALTH" "Starting comprehensive route health check"

    # 1. Check default routes (v1.6 compatibility)
    # v2.2 NEW: Check for duplicate routes on same interface
    cleanup_interface_duplicate_routes "$DSL_INTERFACE" || true
    cleanup_interface_duplicate_routes "$LTE_INTERFACE" || true

    monitor_default_routes

    # 2. NEW: Check local subnet routes
    check_local_subnet_routes

    # 3. NEW: Check NetworkManager configuration
    check_networkmanager_configuration

    # 4. NEW: Detect metric conflicts
    detect_metric_conflicts

    log_message "INFO" "HEALTH" "Comprehensive route health check completed"
    return 0
}

# ============================================================================
# STATUS REPORTING
# ============================================================================

# Print one local-subnet status line.
# Args: $1 = label (e.g. "LAN ", "MGMT"), $2 = subnet, $3 = interface
_print_local_subnet_status() {
    local label="$1"
    local subnet="$2"
    local interface="$3"

    if [[ -z "$subnet" || -z "$interface" ]]; then
        echo "  $label: not configured"
        return
    fi

    local match
    match=$(ip route show 2>/dev/null \
        | grep -E "^${subnet}[[:space:]]+dev[[:space:]]+${interface}" \
        | head -1 || true)

    if [[ -n "$match" ]]; then
        echo "  $label ($subnet via $interface): $match"
    else
        echo "  $label ($subnet via $interface): MISSING"
    fi
}

# Status command with JSON support
show_status() {
    local output_format="${1:-human}"

    if [[ "$output_format" == "json" ]]; then
        generate_json_status
        return
    fi

    # Human-readable format
    echo "Route Guardian Status Report"
    echo "================================="
    echo "Timestamp: $(date)"
    # v3.3.0: Read LTE state from persistent file (for cross-process visibility)
    local lte_state
    lte_state=$(read_lte_state)
    echo "Mode: $([ "$lte_state" == "true" ] && echo "Dual-WAN" || echo "DSL-Only ⚠️")"
    echo ""

    echo "Interfaces:"
    for iface in "$DSL_INTERFACE" "$LTE_INTERFACE" "$LAN_INTERFACE" "$MGMT_INTERFACE"; do
        if check_interface_status "$iface"; then
            echo "  $iface: UP ✓"
        else
            echo "  $iface: DOWN ✗"
        fi
    done

    echo ""
    echo "Default Routes:"
    ip route show | grep "^default via" | while read -r route; do
        echo "  $route"
    done

    echo ""
    echo "Local Subnet Routes:"
    _print_local_subnet_status "LAN " "$LAN_SUBNET" "$LAN_INTERFACE"
    _print_local_subnet_status "MGMT" "$MGMT_SUBNET" "$MGMT_INTERFACE"

    echo ""
    if [[ -f "$REPAIR_SUCCESS_COUNTER" ]]; then
        echo "Repair Success Count: $(cat "$REPAIR_SUCCESS_COUNTER")"
    fi
    if [[ -f "$REPAIR_FAILURE_COUNTER" ]]; then
        echo "Repair Failure Count: $(cat "$REPAIR_FAILURE_COUNTER")"
    fi
    return 0
}

# Emit machine-readable JSON status for dashboard / monitoring integration.
generate_json_status() {
    local timestamp
    timestamp=$(date -Iseconds)
    local success_count=0
    local failure_count=0

    [[ -f "$REPAIR_SUCCESS_COUNTER" ]] && success_count=$(cat "$REPAIR_SUCCESS_COUNTER")
    [[ -f "$REPAIR_FAILURE_COUNTER" ]] && failure_count=$(cat "$REPAIR_FAILURE_COUNTER")

    # Interface status
    local dsl_status="false"
    local lte_status="false"
    local lan_status="false"
    local mgmt_status="false"

    check_interface_status "$DSL_INTERFACE" && dsl_status="true" || dsl_status="false"
    check_interface_status "$LTE_INTERFACE" && lte_status="true" || lte_status="false"
    check_interface_status "$LAN_INTERFACE" && lan_status="true" || lan_status="false"
    check_interface_status "$MGMT_INTERFACE" && mgmt_status="true" || mgmt_status="false"

    # Route counts
    local default_routes
    default_routes=$(ip route show | grep -c "^default via")
    local lan_route_status="false"
    local mgmt_route_status="false"

    ip route show | grep -q "^$LAN_SUBNET dev $LAN_INTERFACE" && lan_route_status="true" || lan_route_status="false"
    ip route show | grep -q "^$MGMT_SUBNET dev $MGMT_INTERFACE" && mgmt_route_status="true" || mgmt_route_status="false"

    # NetworkManager status
    local wan_never_default="unknown"
    if command -v nmcli &>/dev/null; then
        wan_never_default=$(nmcli -t -f ipv4.never-default connection show "$WAN_PRIMARY_CONNECTION" 2>/dev/null | cut -d: -f2)
        [[ -z "$wan_never_default" ]] && wan_never_default="unknown"
    fi

    # v3.3.0: Read LTE state from persistent file (for cross-process visibility)
    local lte_state
    lte_state=$(read_lte_state)
    local lte_mode="dual-wan"
    [[ "$lte_state" == "false" ]] && lte_mode="dsl-only-fallback"

    cat << EOF
{
  "timestamp": "$timestamp",
  "version": "2.0",
  "mode": "$lte_mode",
  "interfaces": {
    "dsl": {
      "name": "$DSL_INTERFACE",
      "status": $dsl_status
    },
    "lte": {
      "name": "$LTE_INTERFACE",
      "status": $lte_status
    },
    "lan": {
      "name": "$LAN_INTERFACE",
      "status": $lan_status
    },
    "management": {
      "name": "$MGMT_INTERFACE",
      "status": $mgmt_status
    }
  },
  "routes": {
    "default_count": $default_routes,
    "lan_subnet_ok": $lan_route_status,
    "mgmt_subnet_ok": $mgmt_route_status
  },
  "networkmanager": {
    "wan_never_default": "$wan_never_default"
  },
  "statistics": {
    "repair_success": $success_count,
    "repair_failure": $failure_count
  },
  "health": {
    "overall": $(if [[ "$lan_route_status" == "true" && "$mgmt_route_status" == "true" && "$default_routes" -gt 0 ]]; then echo "true"; else echo "false"; fi)
  }
}
EOF
}

# ============================================================================
# SIGNAL HANDLING
# ============================================================================

# Signal handlers (Best Practice 2025: No exit in cleanup)
# Note: logging.sh already sets trap 'log_performance' EXIT
# We only need SIGTERM/SIGINT handlers
# Trap-return alone did NOT stop the daemon: after the trap, bash resumed
# the while-loop (wait returns, loop continues) and systemctl stop ran into
# TimeoutStopSec (90s) + SIGKILL. The shutdown flag ends the loop at the
# top of the next iteration instead.
_rg_shutdown=0
cleanup() {
    log_message "INFO" "SYSTEM" "Route Guardian shutting down (PID: $$)"
    _rg_shutdown=1
    # NO exit here - let signal handler return naturally
    # The EXIT trap from logging.sh will run log_performance automatically
    return 0
}

# Signal handler for log rotation (Best Practice 2025)
# Triggered by logrotate via systemctl kill -s HUP
handle_sighup() {
    # Reopen log files after rotation
    exec 1>>"$LOG_FILE" 2>&1
    log_message "INFO" "SIGNAL" "Log file reopened after rotation (SIGHUP received)"
    return 0
}

# Register signal handlers
trap cleanup SIGTERM SIGINT
trap 'handle_sighup' HUP  # v2.8: Zero-downtime log rotation support

# ============================================================================
# Library Mode Support for Testing (Best Practice 2025)
# ============================================================================
# When sourced with ROUTE_GUARDIAN_LIB_MODE=1, only define functions without running main
# This allows BATS tests to import functions without executing the monitoring loop
# Usage in tests: export ROUTE_GUARDIAN_LIB_MODE=1; source route-guardian.sh
if [[ "${ROUTE_GUARDIAN_LIB_MODE:-0}" == "1" ]]; then
    return 0  # Exit sourcing here, all functions are defined above
fi

# Main execution
case "${1:-monitor}" in
    "status")
        show_status "${2:-human}"
        exit 0
        ;;
    "status-json")
        show_status "json"
        exit 0
        ;;
    "repair")
        log_message "INFO" "MANUAL" "Manual repair triggered"
        comprehensive_route_health_check
        exit 0
        ;;
    "monitor"|*)
        log_message "INFO" "SYSTEM" "Route Guardian starting (PID: $$)"
        log_message "INFO" "SYSTEM" "Monitoring interfaces: DSL=$DSL_INTERFACE, LTE=$LTE_INTERFACE, LAN=$LAN_INTERFACE, MGMT=$MGMT_INTERFACE"

        # Registriere Script für Änderungs-Erkennung
        script_watch_init "${BASH_SOURCE[0]}"

        # v3.3.0: Enhanced pre-flight checks with LTE graceful degradation
        enhanced_preflight_checks

        _rg_iteration=0
        # Flag-driven instead of `while true` — SIGTERM/SIGINT set
        # _rg_shutdown in the trap, the loop ends at the iteration top.
        while [[ $_rg_shutdown -eq 0 ]]; do
            (( _rg_iteration++ )) || true

            # v3.3.0: Check if LTE recovered (only if currently unavailable)
            if [[ "$LTE_AVAILABLE" == "false" ]]; then
                check_lte_recovery || true  # Don't fail loop if recovery unsuccessful
            fi

            comprehensive_route_health_check

            # v3.1.0: Check pending smart alerts (process grace period events)
            sa_check_pending_events "_send_alert_direct"

            # Prüfe ob Script geändert wurde — exit 0 triggert systemd Restart
            script_watch_check "$_rg_iteration"

            # Best Practice 2025: Interruptible sleep that continues after SIGHUP
            # sleep would exit on SIGHUP, causing service failure
            sleep "$CHECK_INTERVAL" &
            wait $! || true  # Continue even if interrupted by signal
            # v3.5.0: Reap zombie processes from backgrounded alert calls
            wait 2>/dev/null || true
        done
        # Reached only via the _rg_shutdown flag (SIGTERM/SIGINT trap)
        log_message "INFO" "SYSTEM" "Route Guardian monitor loop ended (clean shutdown)"
        exit 0
        ;;
esac
