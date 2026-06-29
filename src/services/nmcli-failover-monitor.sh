#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# nmcli-failover-monitor — event-driven detection daemon
#
# Watches NetworkManager state via `nmcli monitor` and signals the
# failover-monitor orchestrator (SIGUSR1) when the primary uplink goes
# down. Sub-second reaction compared to the polling-based monitor alone.
#
# Configured via /etc/linux-dual-wan-failover/failover.conf.
#
set -uo pipefail
export LANG=C  # Consistent locale for nmcli parsing

# ---- Configuration ----------------------------------------------------------

FAILOVER_SCRIPT="${FAILOVER_SCRIPT:-/usr/local/lib/linux-dual-wan-failover/services/failover-monitor.sh}"
PRIMARY_IFACE="${PRIMARY_IFACE:-eth0}"
BACKUP_IFACE="${BACKUP_IFACE:-lte0}"
BACKUP_GATEWAY="${BACKUP_GATEWAY:-192.0.2.10}"

# ---- Paths ------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
export SCRIPT_NAME

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR

LIB_DIR="${LIB_DIR:-${SCRIPT_DIR}/../lib}"
readonly LIB_DIR

# ---- Library imports --------------------------------------------------------

# common.sh handles toolkit-aware logging.sh resolution and provides a
# minimal fallback logger if the toolkit is not installed.
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh" || {
    echo "FATAL: failed to source common.sh from ${LIB_DIR}" >&2
    exit 1
}

# Optional: detect code changes and trigger a clean restart.
# shellcheck source=../lib/script-watch.sh
source "${LIB_DIR}/script-watch.sh" 2>/dev/null || \
    log_warning "script-watch.sh not loaded — automatic restart on code update disabled"

# Optional: smart-alerts.sh from bash-production-toolkit for event aggregation.
if [[ -n "${TOOLKIT_LIB:-}" && -f "${TOOLKIT_LIB}/../monitoring/smart-alerts.sh" ]]; then
    # shellcheck source=/dev/null
    source "${TOOLKIT_LIB}/../monitoring/smart-alerts.sh" 2>/dev/null || true
fi

export LOG_FILE="${LOG_FILE:-/var/log/linux-dual-wan-failover/nmcli-monitor.log}"
export LOG_TO_JOURNAL="${LOG_TO_JOURNAL:-false}"
export LOG_TO_STDOUT="${LOG_TO_STDOUT:-false}"

# Ensure log directory exists (systemd `LogsDirectory=` covers this in production).
mkdir -p "$(dirname "$LOG_FILE")"

# Failover Event-ID (Correlation-ID) helper — best-effort, never fatal. Mints
# the ID at the earliest detection point and hands it to failover-monitor via
# pending_failover_id (handoff model: see event-id.sh).
# shellcheck source=../lib/event-id.sh
source "${LIB_DIR}/event-id.sh" 2>/dev/null || true

# ============================================================================
# INSTANT FAILOVER FUNCTIONS
# ============================================================================

wait_for_link_down() {
    local interface="$1"
    local timeout="${2:-5}"  # Default 5s timeout
    local start_time
    start_time=$(date +%s)

    log_debug "Waiting for physical link down on $interface (timeout: ${timeout}s)"

    while true; do
        # Prüfen ob Link physisch down ist (nicht nur carrier off)
        if ! ip link show "$interface" 2>/dev/null | grep -q "state UP"; then
            local elapsed=$(($(date +%s) - start_time))
            log_info "Link confirmed down on $interface after ${elapsed}s"
            return 0  # Link is down
        fi

        # Timeout prüfen
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warning "Timeout beim Warten auf Link-Down auf $interface - Link wieder aktiv (Fehlalarm)"
            return 1  # Timeout - Link noch aktiv
        fi

        sleep 0.5  # Alle 500ms pollen
    done
}

trigger_instant_failover() {
    local interface=$1
    local event=$2

    # Mint the failover Event-ID (Correlation-ID) at the earliest point and hand
    # it to failover-monitor via pending_failover_id — BEFORE the signal is sent
    # (signal-safe: the receiver's USR1 trap does no I/O). The same ID is reused
    # for the emergency lockfile below → one failover == one ID across all paths.
    local _event_id=""
    if declare -F failover_event_id_mint >/dev/null 2>&1; then
        _event_id="$(failover_event_id_mint)"
        failover_event_id_write_pending "$_event_id"
    else
        _event_id="$$_$(date +%s)"
    fi

    # Event 5: critical failover trigger
    log_critical_structured "INSTANT failover triggered" \
        "FAILOVER_EVENT_ID=${_event_id}" \
        "INTERFACE=${interface}" \
        "EVENT_TYPE=${event}" \
        "TRIGGER_SOURCE=nmcli_monitor" \
        "ACTION=failover"

    # First try: Signal via PID file (most reliable)
    local pid_file="/var/run/failover-monitor.pid"
    if [[ -f "$pid_file" ]]; then
        # Pattern 2: PID file read with fallback
        local failover_pid=""
        if ! failover_pid=$(cat "$pid_file"); then
            log_warning "Failed to read PID file - using fallback method"
        elif [[ ! "$failover_pid" =~ ^[0-9]+$ ]]; then
            log_warning "PID file contains non-numeric data - using fallback method"
        elif [[ -n "$failover_pid" ]] && kill -0 "$failover_pid" 2>/dev/null; then
            # v3.8.1 FIX H3: Verify process identity before sending USR1 (prevents PID reuse after crash)
            if ! grep -q "failover-monitor" /proc/"$failover_pid"/cmdline 2>/dev/null; then
                log_warning "PID $failover_pid is not failover-monitor - stale PID file, using fallback"
            elif kill -USR1 "$failover_pid" 2>/dev/null; then
                # Event 6: USR1 signal sent successfully
                log_info_structured "USR1 signal sent to failover monitor" \
                    "FAILOVER_EVENT_ID=${_event_id}" \
                    "SIGNAL=USR1" \
                    "TARGET_PID=${failover_pid}" \
                    "METHOD=pid_file" \
                    "STATUS=success"
                return 0
            fi
        fi
        log_warning "PID file exists but process not responding, trying fallback"
    fi

    # Fallback: Signal via Prozessname (präzises Matching um False Positives zu vermeiden)
    local signaled=0
    while read -r pid; do
        if kill -USR1 "$pid" 2>/dev/null; then
            signaled=1
        fi
    done < <(pgrep -f "$FAILOVER_SCRIPT")

    if [[ $signaled -eq 1 ]]; then
        # Event 7: USR1 signal via pgrep fallback
        log_info_structured "USR1 signal sent via pgrep fallback" \
            "FAILOVER_EVENT_ID=${_event_id}" \
            "SIGNAL=USR1" \
            "METHOD=pgrep" \
            "TARGET_SCRIPT=${FAILOVER_SCRIPT}" \
            "STATUS=success"
        return 0
    fi

    # Fallback: Direkte Route-Manipulation (Emergency Failover)
    log_warning "Haupt-Failover-Script nicht gefunden - führe Emergency Failover aus"

    if [[ "$interface" == "$PRIMARY_IFACE" ]]; then
        # Emergency path reuses the same failover Event-ID minted above — one
        # failover == one ID across all paths. Lockfile content stays in the
        # PID_TIMESTAMP format (route-guardian stale detection).
        local emergency_id="${_event_id}"
        if ! echo "$emergency_id" > /run/failover-in-progress.lock 2>/dev/null; then
            log_warning "Failed to create Route Guardian pause lockfile - emergency failover may be reverted"
        else
            # Persist for the metrics collector (pivot to the event-DB row).
            if declare -F failover_event_id_publish >/dev/null 2>&1; then
                failover_event_id_publish "$emergency_id"
            fi
            log_info "Created Route Guardian pause lockfile: $emergency_id"
        fi

        # Event 8a: Emergency failover started
        log_warning_structured "Emergency failover execution started" \
            "FAILOVER_EVENT_ID=${emergency_id}" \
            "FROM_INTERFACE=${interface}" \
            "TO_INTERFACE=${BACKUP_IFACE}" \
            "METHOD=emergency" \
            "REASON=signal_failed" \
            "LOCKFILE_ID=${emergency_id}"

        # Remove the primary default route (interface-specific for safety).
        # The NM-managed backup route (metric 200) usually already exists and
        # takes over as soon as the primary route is gone.
        if ip route del default dev "$PRIMARY_IFACE" 2>/dev/null; then
            log_info "Removed default route for $PRIMARY_IFACE"
        fi

        # Only add the backup route if it is missing — and with metric 200
        # (consistent with the metric-demotion strategy; the previous
        # metric-100 add created a duplicate that route-guardian then had
        # to clean up again).
        local emergency_route_ok=0
        if ip route show | grep -q "^default via .* dev $BACKUP_IFACE"; then
            log_info "Backup route via $BACKUP_IFACE already present - no route add needed"
            emergency_route_ok=1
        elif ip route add default via "$BACKUP_GATEWAY" dev "$BACKUP_IFACE" metric 200 2>/dev/null; then
            emergency_route_ok=1
        fi

        if [[ $emergency_route_ok -eq 1 ]]; then
            # Event 8b: Emergency failover success
            log_info_structured "Emergency failover completed successfully" \
                "FAILOVER_EVENT_ID=${emergency_id}" \
                "TO_INTERFACE=${BACKUP_IFACE}" \
                "GATEWAY=${BACKUP_GATEWAY}" \
                "METRIC=200" \
                "STATUS=success"

            # v3.6.0: Lockfile-Cleanup nach 30s Stabilisierung planen (wie routing.sh)
            (
                sleep 30
                if [[ -f /run/failover-in-progress.lock ]]; then
                    local current_lockfile_id
                    current_lockfile_id=$(cat /run/failover-in-progress.lock 2>/dev/null)
                    if [[ "$current_lockfile_id" == "$emergency_id" ]]; then
                        rm -f /run/failover-in-progress.lock
                        logger -t nmcli-monitor "Released lockfile for $emergency_id"
                    else
                        logger -t nmcli-monitor "Lockfile owned by different failover ($current_lockfile_id) - skipping cleanup"
                    fi
                fi
            ) &
        else
            # Event 8c: Emergency failover failure - release lockfile immediately
            log_error_structured "Emergency failover failed" \
                "FAILOVER_EVENT_ID=${emergency_id}" \
                "TO_INTERFACE=${BACKUP_IFACE}" \
                "GATEWAY=${BACKUP_GATEWAY}" \
                "STATUS=failed" \
                "ACTION_REQUIRED=manual"

            rm -f /run/failover-in-progress.lock 2>/dev/null || true
        fi
    fi
    return 0
}

# ============================================================================
# STARTUP STATE DETECTION (v3.4.0)
# ============================================================================

# Prüfen ob PRIMARY_IFACE beim Service-Start bereits down ist
# nmcli monitor erkennt nur STATUSÄNDERUNGEN, nicht aktuellen Status
# Diese Funktion schließt die Lücke für Service-Neustarts mit Down-Interface
check_initial_state() {
    local current_state

    # nmcli nach aktuellem PRIMARY_IFACE Status abfragen
    # Fail-safe: Bei Query-Fehler Service-Start nicht blockieren
    if ! current_state=$(nmcli -t -f GENERAL.STATE device show "$PRIMARY_IFACE" 2>&1); then
        log_warning "Failed to query initial state of $PRIMARY_IFACE: $current_state"
        return 0  # Don't block service start on query errors
    fi

    # Status parsen (nmcli Output-Format: "GENERAL.STATE:100 (connected)" oder "GENERAL.STATE:30 (disconnected)")
    # Auf disconnected/unavailable Status prüfen
    if [[ "$current_state" =~ disconnected|unavailable|unmanaged ]]; then
        log_critical "STARTUP: $PRIMARY_IFACE is DOWN at service start (state: $current_state) - triggering instant failover"

        # Instant Failover über existierende Infrastruktur triggern
        trigger_instant_failover "$PRIMARY_IFACE" "startup-down"
    else
        log_info "STARTUP: $PRIMARY_IFACE is UP at service start - normal monitoring"
    fi

    return 0
}

# ============================================================================
# NETWORK EVENT PARSING
# ============================================================================

process_network_event() {
    local full_line="$1"

    log_debug "Raw event: $full_line"

    # Überspringen wenn nicht Primary Interface
    if [[ "$full_line" != *"$PRIMARY_IFACE"* ]]; then
        return 0
    fi

    # Multi-Language Pattern Matching für kritische Events
    case "$full_line" in
        # Konnektivitäts-Pattern (EN/DE)
        *"connectivity"*"none"*|*"Konnektivität"*"keine"*)
            log_warning "Connectivity lost on $PRIMARY_IFACE"
            trigger_instant_failover "$PRIMARY_IFACE" "connectivity-lost"
            ;;

        # Status-Änderungs-Pattern (EN/DE) - MUSS vor generischen Disconnection-Pattern kommen
        *"state"*"unavailable"*|*"Status"*"nicht verfügbar"*)
            log_critical "Interface $PRIMARY_IFACE became unavailable - waiting for link down confirmation"

            # Wait for actual link down (prevents premature failover)
            if wait_for_link_down "$PRIMARY_IFACE" 5; then
                log_info "Link down confirmed - proceeding with failover"
                trigger_instant_failover "$PRIMARY_IFACE" "unavailable-confirmed"
            else
                log_info "Link recovered on $PRIMARY_IFACE - unavailable was transient, no failover needed"
            fi
            ;;

        *"state"*"disconnected"*|*"Status"*"getrennt"*)
            log_warning "Interface $PRIMARY_IFACE state changed to disconnected - waiting for link down confirmation"

            # Wait for actual link down (prevents premature failover)
            if wait_for_link_down "$PRIMARY_IFACE" 5; then
                log_info "Link down confirmed - proceeding with failover"
                trigger_instant_failover "$PRIMARY_IFACE" "state-disconnected-confirmed"
            else
                log_info "Link recovered on $PRIMARY_IFACE - disconnection was transient, no failover needed"
            fi
            ;;

        # Generische Disconnection-Pattern (EN/DE) - Nach spezifischen Status-Pattern
        *"disconnected"*|*"getrennt"*|*"nicht verbunden"*)
            log_warning "Interface $PRIMARY_IFACE disconnected - waiting for link down confirmation"

            # Wait for actual link down (prevents premature failover)
            if wait_for_link_down "$PRIMARY_IFACE" 5; then
                log_info "Link down confirmed - proceeding with failover"
                trigger_instant_failover "$PRIMARY_IFACE" "disconnected-confirmed"
            else
                log_info "Link recovered on $PRIMARY_IFACE - disconnection was transient, no failover needed"
            fi
            ;;

        # Carrier-Pattern (EN/DE) - Auf Link-Down-Bestätigung warten
        *"carrier"*"off"*|*"Träger"*"aus"*|*"carrier"*"down"*)
            log_critical "Carrier lost on $PRIMARY_IFACE - waiting for link down confirmation"

            # Auf tatsächlichen Link-Down warten (verhindert verfrühten Failover)
            if wait_for_link_down "$PRIMARY_IFACE" 5; then
                # Link-Down bestätigt - mit Failover fortfahren
                log_info "Link down confirmed - proceeding with failover"
                trigger_instant_failover "$PRIMARY_IFACE" "carrier-lost-confirmed"
            else
                # Link wieder aktiv - Fehlalarm, kein Failover nötig
                log_info "Link recovered on $PRIMARY_IFACE - carrier flicker detected, no failover needed"
            fi
            ;;

        # IP-Config-Pattern (EN/DE)
        *"ip4-config"*"removed"*|*"IPv4-Konfiguration"*"entfernt"*)
            log_warning "IPv4 config removed from $PRIMARY_IFACE"
            trigger_instant_failover "$PRIMARY_IFACE" "ip4-lost"
            ;;

        # Physische Link-Down-Pattern
        *"link"*"down"*|*"Link"*"unten"*)
            log_critical "Physical link down on $PRIMARY_IFACE"
            trigger_instant_failover "$PRIMARY_IFACE" "link-down"
            ;;

        *)
            # Andere Events für Debugging loggen
            log_debug "Non-critical event: $full_line"
            ;;
    esac
    return 0
}

# ============================================================================
# MAIN EVENT LOOP
# ============================================================================

main() {
    # Strikte Fehlerbehandlung temporär deaktivieren für logging.sh structured Calls
    # (logging.sh v2.3.0 structured Funktionen nicht vollständig strict-safe mit set -e)
    set +e

    # Event 1: Monitor started with configuration
    log_info_structured "NetworkManager event monitor started" \
        "PRIMARY_IFACE=${PRIMARY_IFACE}" \
        "BACKUP_IFACE=${BACKUP_IFACE}" \
        "FAILOVER_SCRIPT=${FAILOVER_SCRIPT}" \
        "MONITOR_TYPE=event-driven" \
        "DETECTION_METHOD=nmcli_monitor"

    # Registriere Script für Änderungs-Erkennung
    script_watch_init "${BASH_SOURCE[0]}"

    # Event 2: nmcli availability check
    if ! command -v nmcli &>/dev/null; then
        log_error_structured "nmcli command not available" \
            "COMMAND=nmcli" \
            "STATUS=missing" \
            "EXIT_CODE=1"
        exit 1
    fi

    log_info_structured "nmcli command available" \
        "COMMAND=nmcli" \
        "STATUS=found" \
        "VERSION=$(nmcli --version | head -1)"

    # Event 3: Failover script availability check
    if [[ ! -f "$FAILOVER_SCRIPT" ]]; then
        log_warning_structured "Failover script not found - using emergency mode" \
            "FAILOVER_SCRIPT=${FAILOVER_SCRIPT}" \
            "FILE_EXISTS=false" \
            "FALLBACK_MODE=emergency"
    else
        log_info_structured "Failover script available" \
            "FAILOVER_SCRIPT=${FAILOVER_SCRIPT}" \
            "FILE_EXISTS=true" \
            "MODE=signal-based"
    fi

    # v3.5.0 ARCHITECTURE REVIEW FIX #3: Initialen Status mit Debounce vor Monitor-Loop prüfen
    # nmcli monitor erkennt nur ÄNDERUNGEN, nicht aktuellen Status beim Start
    check_initial_state

    # v3.5.0 FIX #3: Auf gepufferte nmcli Events warten (verhindert doppelte USR1 Signale)
    # check_initial_state() kann USR1 Signal senden, dann emittiert nmcli monitor gepufferte Events
    # für denselben Disconnect (z.B. "eth0: disconnected", "ip4-config removed", "carrier off")
    # 2s Debounce verhindert schnelle doppelte Signale an failover-monitor
    log_info_structured "Waiting 2s for buffered events to clear before starting monitor" \
        "DEBOUNCE_DELAY=2s" \
        "RATIONALE=prevent_duplicate_signals"
    sleep 2

    # Event 4: Monitor loop started
    log_info_structured "nmcli monitor loop started" \
        "LANG=C" \
        "PARSE_MODE=language-agnostic" \
        "EVENT_PROCESSING=enabled" \
        "AUTO_RESTART=true"

    # Produktionssicher: Auto-Restart-Loop für nmcli monitor
    # (nmcli monitor kann bei DBus-Reconnect, NetworkManager-Restart, etc. beenden)
    while true; do
        # pipefail für diese Pipe deaktivieren (nmcli monitor Exit sollte Daemon nicht killen)
        set +o pipefail

        LANG=C nmcli monitor 2>&1 | while read -r line; do
            # Leere Zeilen überspringen
            [[ -n "$line" ]] || continue

            # Vollständige Event-Zeile verarbeiten
            process_network_event "$line"
        done

        # pipefail nach Pipe-Completion wieder aktivieren
        set -o pipefail

        # nmcli monitor unerwartet beendet - loggen und neu starten
        log_warning_structured "nmcli monitor exited unexpectedly - auto-restarting" \
            "RESTART_DELAY=3s" \
            "AUTO_RECOVERY=true"

        # Prüfe bei jedem nmcli-Neustart ob Script geändert wurde
        # (event-driven Script hat keinen Iterations-Zähler — zeitbasierte Variante verwenden)
        script_watch_check_timed

        sleep 3
    done
    return 0
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

# shellcheck disable=SC2317  # Cleanup function called via trap
cleanup() {
    # Event 9: Monitor shutdown
    log_info_structured "NetworkManager event monitor shutting down" \
        "SHUTDOWN_REASON=signal" \
        "EXIT_CODE=0" \
        "CLEAN_SHUTDOWN=true"

    exit 0
}

# Register signal handlers (SIGTERM/SIGINT only - EXIT conflicts with logging.sh performance trap)
trap cleanup SIGTERM SIGINT

# ============================================================================
# LIBRARY MODE (for BATS testing)
# ============================================================================

# Library Mode für BATS-Tests: Nur Funktionen laden, kein Script ausführen
# Aktivieren mit: NMCLI_FAILOVER_MONITOR_LIB_MODE=1 source script.sh
if [[ "${NMCLI_FAILOVER_MONITOR_LIB_MODE:-0}" == "1" ]]; then
    # Funktionen sind geladen, main() nicht ausführen
    return 0 2>/dev/null || exit 0
fi

# ============================================================================
# STARTUP
# ============================================================================

# Note: PID file management removed - systemd handles duplicate detection via Type=simple
# Previous manual PID file logic caused permission issues (/var/run/ requires root)
# systemd is more reliable for service management and restart handling

# Start main loop
main
