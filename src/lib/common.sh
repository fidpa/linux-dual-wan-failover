#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# common.sh — shared utilities for linux-dual-wan-failover
#
# Provides logging wrappers, state management, error handling, signal
# handling, and the alerting-plugin loader used by send_notification().
#
# This file is meant to be sourced, not executed.

set -uo pipefail

# ============================================================================
# LOGGING SETUP
# ============================================================================
#
# linux-dual-wan-failover relies on the bash-production-toolkit's logging.sh
# for structured journald + file logging. The toolkit can be installed via:
#
#   - System-wide: /usr/local/lib/bash-production-toolkit/foundation/logging.sh
#                  (recommended; install via the toolkit's install.sh)
#   - Submodule:   <this-repo>/vendor/bash-production-toolkit/src/foundation/logging.sh
#                  (override TOOLKIT_LIB to point at the submodule path)
#   - Custom:      set TOOLKIT_LIB to any directory containing logging.sh
#
# If the toolkit is not installed, common.sh falls back to a minimal local
# log() implementation so the failover services still run.

SCRIPT_NAME="${SCRIPT_NAME:-failover-monitor}"

SCRIPT_DIR_COMMON=""
if ! SCRIPT_DIR_COMMON="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; then
    echo "FATAL: Failed to determine common module directory" >&2
    exit 1
fi
readonly SCRIPT_DIR_COMMON

# ============================================================================
# PROJECT VERSION
# ============================================================================
#
# The version lives in exactly one place: the VERSION file at the repo root.
# Everything that reports a version reads it from here. Until v0.7.0 the
# orchestrator carried its own `SCRIPT_VERSION="0.1.1"` literal, which nobody
# bumped for six releases — the daemon announced 0.1.1 on every start while
# the tag said 0.7.0. A second place to maintain a number is a place that
# drifts.
#
# Two candidate paths because the repo layout and the installed layout differ
# in depth: <repo>/src/lib/common.sh vs. ${LIB_DIR}/lib/common.sh.
_resolve_project_version() {
    local candidates=(
        "${SCRIPT_DIR_COMMON}/../../VERSION"   # repo:      src/lib/ -> <root>
        "${SCRIPT_DIR_COMMON}/../VERSION"      # installed: lib/     -> ${LIB_DIR}
    )
    local c version
    for c in "${candidates[@]}"; do
        if [[ -r "$c" ]]; then
            read -r version < "$c" || continue
            # Guard against a truncated or garbage file: only x.y.z counts.
            if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$version"
                return 0
            fi
        fi
    done
    return 1
}

if ! PROJECT_VERSION="$(_resolve_project_version)"; then
    # Not fatal: a missing VERSION file must never keep the failover daemon
    # from starting. It only costs an accurate version in the logs.
    PROJECT_VERSION="unknown"
fi
# shellcheck disable=SC2034 # consumed by sourcing services (SCRIPT_VERSION)
readonly PROJECT_VERSION

# Logging defaults — MUST be set BEFORE sourcing the toolkit: its logging.sh
# initializes these with `:=` at source time, so anything set afterwards is a
# dead assignment. LOG_TO_STDOUT stays true because journald visibility relies
# on it: the units run with StandardOutput=journal and docs/how-to/
# debug-failover.md reads logs via `journalctl -u failover-monitor` — with the
# toolkit loaded, stdout is the only path into the journal (LOG_TO_JOURNAL
# stays false; the stderr fallback logger covers the no-toolkit case).
# Note for callers: functions whose stdout is captured via `$(...)` must not
# log without `>&2`, or the log line becomes part of the captured value.
LOG_FILE="${LOG_FILE:-/var/log/linux-dual-wan-failover/failover.log}"
LOG_TO_JOURNAL="${LOG_TO_JOURNAL:-false}"
LOG_TO_STDOUT="${LOG_TO_STDOUT:-true}"

# Resolve the toolkit library directory.
# Order: TOOLKIT_LIB env > system path > vendor/ submodule > none.
_resolve_toolkit_lib() {
    local candidates=(
        "${TOOLKIT_LIB:-}"
        "/usr/local/lib/bash-production-toolkit/foundation"
        "${SCRIPT_DIR_COMMON}/../../vendor/bash-production-toolkit/src/foundation"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -n "$c" && -f "$c/logging.sh" ]] && { echo "$c"; return 0; }
    done
    return 1
}

if TOOLKIT_LIB_RESOLVED="$(_resolve_toolkit_lib)"; then
    # shellcheck source=/dev/null
    if source "${TOOLKIT_LIB_RESOLVED}/logging.sh" && declare -F log_info &>/dev/null; then
        readonly TOOLKIT_LIB="$TOOLKIT_LIB_RESOLVED"
    else
        echo "WARN: Failed to load toolkit logging.sh from $TOOLKIT_LIB_RESOLVED — falling back to minimal logger" >&2
    fi
fi

# Minimal fallback logger if the toolkit is not available.
# The failover services still log to stderr / journal via systemd, just
# without structured fields. Override LOG_FILE to also write to a file.
if ! declare -F log_info &>/dev/null; then
    log_info()    { printf '%s [INFO] %s\n'    "$(date -u +%FT%TZ)" "$*" >&2; }
    log_warning() { printf '%s [WARN] %s\n'    "$(date -u +%FT%TZ)" "$*" >&2; }
    log_error()   { printf '%s [ERROR] %s\n'   "$(date -u +%FT%TZ)" "$*" >&2; }
    log_debug()   { [[ "${DEBUG:-0}" == 1 ]] && printf '%s [DEBUG] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
fi

# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================

# ============================================================================
# MODULE MAP — 19 Funktionen in 6 Gruppen
# ============================================================================
#
# 1. LOGGING — Hybrid Wrapper Pattern (→ Zeile 109)
#    log()                      Legacy-Wrapper über logging.sh (2-Parameter-Signatur)
#
# 2. STATE MANAGEMENT — Pfade, Init, Persistenz (→ Zeile 144)
#    init_state_paths()         State-File-Pfade nach Config-Load setzen
#    init_state_files()         State-Directory + Dateien mit Defaults initialisieren
#    save_state()               Atomic Write eines Key-Value-Paares
#    load_state()               State-Wert lesen mit Default-Fallback
#
# 3. ERROR HANDLING — Abbruch und Traps (→ Zeile 220)
#    die()                      Critical Error → Log + Exit 1
#    setup_error_handling()     INT/TERM/ERR Traps registrieren
#
# 4. VALIDATION — Umgebungsprüfung (→ Zeile 236)
#    validate_environment()     Root-Check, Commands, Interface-Config
#
# 5. UTILITY — Hilfsfunktionen und Notification (→ Zeile 351)
#    is_numeric()               Integer/Float-Validierung
#    get_timestamp()            Unix-Timestamp (Sekunden)
#    get_timestamp_ms()         Unix-Timestamp (Millisekunden)
#    get_human_time()           Timestamp → YYYY-MM-DD HH:MM:SS
#    file_older_than()          Datei-Alter gegen Max-Age prüfen
#    send_notification()        Log-basierte Notification (Mattermost via alerts.sh)
#
# ============================================================================

# Default configuration
# (Unused DEFAULT_CHECK_INTERVAL/_FAILURE_THRESHOLD/_RECOVERY_THRESHOLD/
# _LOG_FILE constants removed — values were stale 2025 numbers and the real
# defaults live in the monitor service; only the state dir is consumed here.)
readonly DEFAULT_STATE_DIR="/run/wan-state"

# State management paths (will be set after config load)
STATE_FILE=""
METRICS_FILE=""
LAST_FAILOVER_FILE=""

# Initialize state file paths after config is loaded
init_state_paths() {
    local state_dir="${STATE_DIR:-$DEFAULT_STATE_DIR}"
    STATE_FILE="$state_dir/active_wan"
    METRICS_FILE="$state_dir/connection_metrics"
    LAST_FAILOVER_FILE="$state_dir/last_failover"
    LAST_FAILOVER_TO_BACKUP_FILE="$state_dir/last_failover_to_backup"  # v4.3.0: MIN_BACKUP_TIME tracking

    # Export for use in modules
    export STATE_FILE METRICS_FILE LAST_FAILOVER_FILE LAST_FAILOVER_TO_BACKUP_FILE
}

# ============================================================================
# LOGGING FUNCTIONS (HYBRID WRAPPER PATTERN)
# ============================================================================

# Hybrid wrapper: log() function wraps logging.sh for backward compatibility
# This preserves the existing 2-parameter signature used in all 282 log calls
# across 9 files (main + 8 modules) without requiring any code changes
log() {
    local level="$1"
    shift
    local message="$*"

    # Map legacy log levels to logging.sh functions
    case "$level" in
        INFO)
            log_info "$message"
            ;;
        DEBUG)
            log_debug "$message"
            ;;
        WARNING|WARN)
            log_warning "$message"
            ;;
        ERROR)
            log_error "$message"
            ;;
        CRITICAL)
            # Map CRITICAL to ERROR (logging.sh has no separate CRITICAL level)
            log_error "[CRITICAL] $message"
            ;;
        *)
            # Unknown level - log as info
            log_info "[$level] $message"
            ;;
    esac
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

# Initialize state directory
init_state_files() {
    local state_dir="${STATE_DIR:-$DEFAULT_STATE_DIR}"

    # Create state directory if it doesn't exist
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" || {
            log "ERROR" "Failed to create state directory: $state_dir"
            return 1
        }
    fi

    # Fail loudly if any required path variable was not initialised by the caller.
    : "${STATE_FILE:?init_state_files: STATE_FILE is not set - aborting init}"
    : "${METRICS_FILE:?init_state_files: METRICS_FILE is not set - aborting init}"
    : "${LAST_FAILOVER_FILE:?init_state_files: LAST_FAILOVER_FILE is not set - aborting init}"

    # Initialize state files with defaults using secure-file-utils
    # sfu_write_file now supports optional third parameter for permissions (644)
    if [[ ! -f "$STATE_FILE" ]]; then
        sfu_write_file "primary" "$STATE_FILE" "644" || {
            log "ERROR" "Failed to initialize $STATE_FILE"
            return 1
        }
    fi
    if [[ ! -f "$METRICS_FILE" ]]; then
        sfu_write_file "{}" "$METRICS_FILE" "644" || {
            log "ERROR" "Failed to initialize $METRICS_FILE"
            return 1
        }
    fi
    if [[ ! -f "$LAST_FAILOVER_FILE" ]]; then
        sfu_write_file "0" "$LAST_FAILOVER_FILE" "644" || {
            log "ERROR" "Failed to initialize $LAST_FAILOVER_FILE"
            return 1
        }
    fi

    log "DEBUG" "State files initialized in $state_dir (permissions: 644)"
}

# Save state safely with atomic write
save_state() {
    local key="$1"
    local value="$2"
    local state_dir="${STATE_DIR:-$DEFAULT_STATE_DIR}"
    local target_file="$state_dir/$key"

    # Atomic write using secure-file-utils with 644 permissions
    # (644 = world-readable, needed for failover-metrics-collector running as admin user)
    if sfu_write_file "$value" "$target_file" "644"; then
        log "DEBUG" "Saved state: $key = $value (permissions: 644)"
        return 0
    else
        log "ERROR" "Failed to save state: $key"
        return 1
    fi
}

# Load state with default fallback
load_state() {
    local key="$1"
    local default="${2:-}"
    local state_dir="${STATE_DIR:-$DEFAULT_STATE_DIR}"
    local state_file="$state_dir/$key"

    if [[ -r "$state_file" ]]; then
        cat "$state_file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Die with critical error
die() {
    log "CRITICAL" "$*"
    exit 1
}

# Setup error traps
setup_error_handling() {
    trap 'log "ERROR" "Script interrupted by signal"' INT TERM
    trap 'log "ERROR" "Script failed on line $LINENO"' ERR
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

# Validate environment and dependencies
validate_environment() {
    local errors=0

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Must run as root for route manipulation"
        ((errors++))
    fi

    # Check required commands
    local required_commands=("ip" "ping" "bc" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR" "Required command not found: $cmd"
            ((errors++)) || true
        fi
    done

    # Optional hardware-monitoring backend (Raspberry Pi `vcgencmd`).
    # Failover does not depend on hardware sensors — this is informational.
    # Future versions will support pluggable HARDWARE_TEMP_BACKEND with a
    # `thermal_zone0` reader as the cross-platform default.
    if [[ "${HARDWARE_TEMP_BACKEND:-none}" == "vcgencmd" ]] \
        && ! command -v vcgencmd >/dev/null 2>&1; then
        log "WARNING" "HARDWARE_TEMP_BACKEND=vcgencmd but binary not found — hardware monitoring disabled"
    fi

    # Validate configuration
    if [[ -z "${PRIMARY_IFACE:-}" ]] || [[ -z "${BACKUP_IFACE:-}" ]]; then
        log "ERROR" "PRIMARY_IFACE and BACKUP_IFACE must be configured"
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        die "Environment validation failed with $errors errors"
    fi

    log "INFO" "Environment validation passed"
}

# ============================================================================
# SIGNAL HANDLING & LIFECYCLE
# ============================================================================
# setup_signal_handlers/handle_event_signal/graceful_shutdown/
# cleanup_temp_files removed: dead code that exclusively referenced functions
# of the long-removed events module (handle_instant_failover_event etc.).
# The monitor service registers its own traps (handle_instant_failover,
# handle_shutdown).

# ============================================================================
# UTILITY
# ============================================================================

# Check if value is numeric (integer or float, trailing dot accepted)
# SSOT — network.sh nutzt diese Definition via export -f (keine eigene Kopie mehr)
is_numeric() {
    [[ "$1" =~ ^[0-9]+\.?[0-9]*$ ]]
}

# Get current timestamp
get_timestamp() {
    date +%s
}

# Get timestamp with millisecond precision (Best Practices 2025)
get_timestamp_ms() {
    date +%s%3N
}

# v3.3.0: Get monotonic time (seconds since boot) - immune to NTP clock skew
# Use for anti-flapping and cooldown timers where wall clock jumps would cause issues
get_monotonic_time() {
    awk '{print int($1)}' /proc/uptime
}

# Get human readable time
get_human_time() {
    local timestamp="${1:-$(get_timestamp)}"
    date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S'
}

# Check if file is older than N seconds
file_older_than() {
    local file="$1"
    local max_age="$2"

    if [[ ! -f "$file" ]]; then
        return 0  # Non-existent files are considered "old"
    fi

    local file_time
    file_time=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    local current_time
    current_time=$(get_timestamp)
    local age
    age=$(( ${current_time:-0} - ${file_time:-0} ))

    [[ $age -gt $max_age ]]
}

# Send notification via logging + alerting-plugin
# Usage: send_notification "message" ["level"]
# Levels: info (default) | warning|warn | critical|error
#
# Behavior:
#   - Always logs at the corresponding log level
#   - If ALERTING_BACKEND != "none", forwards to the selected plugin's
#     send_alert function. Plugin is loaded lazily on first call and
#     cached for the rest of the process lifetime.
#   - Plugin failures are best-effort: alert errors don't fail the notification.
#
# Plugin contract (see plugins/alerting/README.md):
#   - File: ${ALERTING_PLUGIN_DIR}/${ALERTING_BACKEND}.sh
#   - Must define: send_alert <alert_type> <message>
#   - Built-in backends: none, mattermost, webhook
send_notification() {
    local message="${1:-}"
    local level="${2:-info}"

    # Validate input
    [[ -n "$message" ]] || {
        log "ERROR" "send_notification: Message cannot be empty"
        return 1
    }

    # Map level → log severity + alert_type (severity auto-derived by plugin)
    local alert_type
    case "$level" in
        critical|error)
            log "ERROR" "[NOTIFICATION] $message"
            alert_type="CRIT_FAILOVER"
            ;;
        warning|warn)
            log "WARNING" "[NOTIFICATION] $message"
            alert_type="WARN_FAILOVER"
            ;;
        *)
            log "INFO" "[NOTIFICATION] $message"
            alert_type="INFO_FAILOVER"
            ;;
    esac

    # Plugin forwarding (default OFF: ALERTING_BACKEND=none)
    local backend="${ALERTING_BACKEND:-none}"
    [[ "$backend" == "none" ]] && return 0

    # Lazy-load plugin once per process. Resolution order matches the
    # contract documented in plugins/alerting/README.md:
    #   1. ALERTING_PLUGIN_PATH        (custom plugins outside the dir)
    #   2. ALERTING_PLUGIN_DIR/<backend>.sh
    #   3. <repo>/plugins/alerting/<backend>.sh   (dev / bats tests)
    if ! declare -F send_alert >/dev/null 2>&1; then
        # Reject unsafe backend names early (path traversal, shell metacharacters).
        if [[ ! "$backend" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log "WARNING" "Refusing to load alerting plugin: invalid backend name '$backend'"
            return 0
        fi

        local _plugin=""
        if [[ -n "${ALERTING_PLUGIN_PATH:-}" ]]; then
            if [[ -f "$ALERTING_PLUGIN_PATH" ]]; then
                _plugin="$ALERTING_PLUGIN_PATH"
            else
                log "WARNING" "ALERTING_PLUGIN_PATH set but file not found: $ALERTING_PLUGIN_PATH"
            fi
        fi
        if [[ -z "$_plugin" ]]; then
            local _plugin_dir="${ALERTING_PLUGIN_DIR:-/usr/local/lib/linux-dual-wan-failover/plugins/alerting}"
            if [[ -f "${_plugin_dir}/${backend}.sh" ]]; then
                _plugin="${_plugin_dir}/${backend}.sh"
            fi
        fi
        if [[ -z "$_plugin" ]]; then
            # Fallback: repository-relative path (dev / bats tests)
            local _repo_plugin
            _repo_plugin="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/../../plugins/alerting/${backend}.sh" 2>/dev/null || true)"
            [[ -f "$_repo_plugin" ]] && _plugin="$_repo_plugin"
        fi

        if [[ -n "$_plugin" ]]; then
            # shellcheck source=/dev/null
            source "$_plugin" 2>/dev/null || \
                log "DEBUG" "Failed to source alerting plugin: $_plugin"
        else
            log "DEBUG" "Alerting plugin '$backend' not found — alerts disabled for this process"
            return 0
        fi
    fi

    if declare -F send_alert >/dev/null 2>&1; then
        send_alert "$alert_type" "$message" >/dev/null 2>&1 || \
            log "DEBUG" "send_alert returned non-zero (rate-limited or backend unreachable)"
    fi

    return 0
}

# Export functions for use by other modules
export -f log save_state load_state die validate_environment
export -f is_numeric get_timestamp get_timestamp_ms get_monotonic_time get_human_time file_older_than
export -f send_notification
