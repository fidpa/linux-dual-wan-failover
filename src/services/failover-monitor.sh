#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# failover-monitor — main orchestrator daemon for linux-dual-wan-failover
#
# Periodically scores both WAN interfaces, evaluates anti-flap and hysteresis
# rules, and switches the default route when the backup outscores the
# primary. Also handles SIGUSR1 from `nmcli-failover-monitor` for sub-second
# emergency failover.
#
# Configured via /etc/linux-dual-wan-failover/failover.conf (overridable
# via FAILOVER_CONF_PATH).
#
set -o pipefail

# ---- Paths ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR

# Allow LIB_DIR override for testing / non-standard install paths.
LIB_DIR="${LIB_DIR:-${SCRIPT_DIR}/../lib}"
readonly LIB_DIR

readonly SCRIPT_VERSION="0.1.1"
readonly PID_FILE="${PID_FILE:-/run/failover-monitor.pid}"

# ---- Library imports --------------------------------------------------------

if [[ ! -f "${LIB_DIR}/common.sh" ]]; then
    echo "FATAL: common.sh library not found at ${LIB_DIR}/common.sh" >&2
    exit 1
fi
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh" || exit 1

# shellcheck source=../lib/performance.sh
source "${LIB_DIR}/performance.sh" || {
    log_error "Failed to load performance.sh"
    exit 1
}

# shellcheck source=../lib/network.sh
source "${LIB_DIR}/network.sh" || {
    log_error "Failed to load network.sh"
    exit 1
}

# shellcheck source=../lib/routing.sh
source "${LIB_DIR}/routing.sh" || {
    log_error "Failed to load routing.sh"
    exit 1
}

# Optional: detect code changes and trigger a clean restart on next loop.
# shellcheck source=../lib/script-watch.sh
source "${LIB_DIR}/script-watch.sh" 2>/dev/null || \
    log_warning "script-watch.sh not loaded — automatic restart on code update disabled"

# Now enable strict mode (after all libraries loaded safely).
set -u

# ============================================================================
# CONFIGURATION
# ============================================================================

# Load configuration file if exists
# v4.6.1 FIX: Correct config path (was failover-monitor.conf, actual file is failover.conf)
if [[ -f "/etc/linux-dual-wan-failover/failover.conf" ]]; then
    source "/etc/linux-dual-wan-failover/failover.conf" 2>/dev/null || {
        log_warning "Failed to load config file, using defaults"
    }
fi

# Initialize state paths
init_state_paths

# Interface configuration
PRIMARY_IFACE="${PRIMARY_IFACE:-eth0}"
BACKUP_IFACE="${BACKUP_IFACE:-lte0}"

# Network test targets (required by performance.sh)
# shellcheck disable=SC2034 # consumed by sourced lib/performance.sh
CHECK_IPS=("8.8.8.8" "1.1.1.1" "9.9.9.9" "208.67.222.222")
# shellcheck disable=SC2034 # consumed by sourced lib/performance.sh
DNS_SERVERS=("8.8.8.8" "1.1.1.1")

# Monitoring intervals
# Defaults synchronized with failover.conf (production-tuned values).
# These activate only if failover.conf is missing or unloadable.
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"  # Check every 15 seconds (failover.conf override)
METRICS_EXPORT_INTERVAL="${METRICS_EXPORT_INTERVAL:-5}"  # Export metrics every 5s

# Failover thresholds (synchronized with failover.conf)
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-5}"  # 5 consecutive failures (v4.7.1: 3→5 false-positive fix)
RECOVERY_THRESHOLD="${RECOVERY_THRESHOLD:-20}"  # 20 consecutive successes
EMERGENCY_THRESHOLD="${EMERGENCY_THRESHOLD:-15}"  # Score < 15 = emergency

# Anti-flapping protection (synchronized with failover.conf)
ANTI_FLAPPING_DELAY="${ANTI_FLAPPING_DELAY:-600}"  # 10 minutes between failovers
ANTI_FLAPPING_DELAY_INSTANT="${ANTI_FLAPPING_DELAY_INSTANT:-60}"  # 60s for instant_event (v4.1.1 #4)

# v4.4.0: Minimum time on backup WAN after failover
MIN_BACKUP_TIME="${MIN_BACKUP_TIME:-3600}"  # 60 minutes in seconds (default: 3600s = 60min)

# v4.7.1: Minimum continuous stability duration for primary interface (reduced from 3600s)
# Schadensdauer pro False-Positive 65→20min, Flapping-Schutz weiter via MIN_BACKUP_TIME + ANTI_FLAPPING_DELAY
MIN_STABLE_DURATION="${MIN_STABLE_DURATION:-900}"  # 15 minutes in seconds (synchronized with failover.conf)

# v4.1.7: Both-interfaces-degraded threshold (triggers alert, not failover)
BOTH_DEGRADED_THRESHOLD="${BOTH_DEGRADED_THRESHOLD:-25}"

# v4.5.0: Critical packet loss threshold (bypasses score-based logic)
CRITICAL_PACKET_LOSS="${CRITICAL_PACKET_LOSS:-50}"  # 50% packet loss = critical

# v4.7.0: Minimum primary score for failback after stability requirements met
MIN_FAILBACK_SCORE="${MIN_FAILBACK_SCORE:-60}"  # 60 = matches stability window threshold

# Stability-window reset threshold (anti-flap).
# See failover.conf for full rationale. Must be <= FAILOVER_THRESHOLD_DOWN.
STABILITY_RESET_THRESHOLD="${STABILITY_RESET_THRESHOLD:-50}"

# Emergency-failback thresholds: trigger failback when the backup is UP but
# end-to-end measurements (DNS time) indicate the link is unusable.
EMERGENCY_FAILBACK_DNS_THRESHOLD_MS="${EMERGENCY_FAILBACK_DNS_THRESHOLD_MS:-800}"
EMERGENCY_FAILBACK_DEGRADED_CHECKS="${EMERGENCY_FAILBACK_DEGRADED_CHECKS:-6}"
EMERGENCY_FAILBACK_MIN_PRIMARY_SCORE="${EMERGENCY_FAILBACK_MIN_PRIMARY_SCORE:-60}"
EMERGENCY_FAILBACK_MIN_BACKUP_TIME="${EMERGENCY_FAILBACK_MIN_BACKUP_TIME:-600}"
EMERGENCY_FAILBACK_COOLDOWN="${EMERGENCY_FAILBACK_COOLDOWN:-900}"
WAN_QUALITY_PROM_MAX_AGE="${WAN_QUALITY_PROM_MAX_AGE:-300}"

# v4.8.0: Runtime state for emergency failback (not persisted — resets on restart)
backup_degraded_streak=0            # Consecutive checks with backup DNS > threshold
last_emergency_failback_mono=0      # Monotonic timestamp of last emergency failback

# v4.10.0: Last-Resort failover state + config (Followup 25.04.2026 — Quota-blocked safety net)
LAST_RESORT_PRIMARY_THRESHOLD="${LAST_RESORT_PRIMARY_THRESHOLD:-25}"
LAST_RESORT_COOLDOWN="${LAST_RESORT_COOLDOWN:-1800}"
last_last_resort_mono=0             # Monotonic timestamp of last Last-Resort trigger

# v4.7.0: Prolonged backup time alert thresholds
PROLONGED_BACKUP_ALERT_TIME="${PROLONGED_BACKUP_ALERT_TIME:-7200}"  # 2 hours on backup = alert
PROLONGED_BACKUP_ALERT_INTERVAL="${PROLONGED_BACKUP_ALERT_INTERVAL:-14400}"  # Rate limit: 1 per 4h

# v4.1.7: Rate limiting for degraded alerts (prevent alert spam)
last_degraded_alert=0
last_prolonged_backup_alert=0

# State variables
declare -gA connection_scores
# shellcheck disable=SC2034 # legacy state, kept for compat with debug dumps
declare -gA failure_counts
# shellcheck disable=SC2034 # legacy state, kept for compat with debug dumps
declare -gA recovery_counts
declare -gA consecutive_failures  # NEW: Track consecutive failures for FAILURE_THRESHOLD
declare -gA consecutive_recoveries  # NEW: Track consecutive recoveries for RECOVERY_THRESHOLD

current_wan="primary"
last_failover_time=0
last_failover_mono=0  # v4.6.1 FIX M3: Monotonic timestamp for anti-flapping (NTP-safe)
last_metrics_export=0
instant_event_pending=0  # NEW (v4.1.1): Flag for signal handler safety
both_interfaces_down=0  # NEW (v4.1.1 #5): State machine for both-down scenario
last_primary_recovery_time=0  # NEW (v4.3.1): Timestamp when PRIMARY last became healthy (for MIN_STABLE_DURATION)

# ============================================================================
# MODULE MAP — 19 Funktionen in 6 Gruppen
# ============================================================================
#
# 1. STATE ACCESSORS — set -u sichere Getter für assoziative Arrays (→ Zeile 313)
#    get_connection_score()                Score eines Interface auslesen
#    get_consecutive_failures()            Konsekutive Fehler eines Interface
#    get_consecutive_recoveries()          Konsekutive Erfolge eines Interface
#
# 2. SIGNAL HANDLERS — USR1 Instant-Failover, TERM Graceful Shutdown (→ Zeile 335)
#    handle_instant_failover()             USR1-Flag setzen (POSIX-konform, kein I/O)
#    handle_shutdown()                     Metriken exportieren, PID-File aufräumen
#
# 3. FAILOVER EVALUATION — Counter-Updates, Schwellenwerte, Degraded-Handling (→ Zeile 365)
#    update_interface_counters()           Consecutive-Counter für beide Interfaces aktualisieren
#    is_emergency_failover_needed()        Score < EMERGENCY_THRESHOLD + Backup viable
#    is_standard_failover_needed()         FAILURE_THRESHOLD + Score < 60 + Delta > 20
#    is_severely_degraded_failover_needed() eth0 ≤ 30 + 3 Failures (Bypass MIN_QUALITY_DELTA)
#    is_failback_needed()                  Recovery + MIN_BACKUP_TIME + MIN_STABLE_DURATION + Hysterese
#    process_instant_failover_request()    USR1-Verarbeitung mit frischen Scores (Cache invalidiert)
#    refresh_interface_scores()            Zentraler Score-Refresh für beide Interfaces
#    handle_both_interfaces_down()         Beide Scores = 0 → Degraded Mode, Counter-Reset
#    handle_both_interfaces_degraded()     Beide ≤ 25 → Rate-Limited Alert, Stabilisierung
#
# 4. FAILOVER EXECUTION — Route-Wechsel, Packet-Loss-Bypass, Orchestrierung (→ Zeile 635)
#    perform_failover()                    Anti-Flapping + safe_route_change + State-Update
#    is_critical_packet_loss()             Packet Loss > 50% → Bypass Score-Logik
#    check_failover_conditions()           Haupt-Orchestrator: Decision Tree aller Bedingungen
#
# 5. METRICS EXPORT — JSON für failover-metrics-collector.py (→ Zeile 856)
#    export_current_metrics()              Scores als JSON nach /run/linux-dual-wan-failover/wan-state/ exportieren
#
# 6. MONITORING LOOP — Hauptschleife mit Fixed-Rate Timing (→ Zeile 869)
#    main()                                Init + While-Loop (30s Intervall, Cache-Cleanup, Stats)
#
# ============================================================================

# ============================================================================
# STATE ACCESSORS
# ============================================================================

# Safe getter for connection scores (prevents set -u crashes on missing keys)
get_connection_score() {
    local iface="$1"
    echo "${connection_scores[$iface]:-0}"
}

# Safe getter for consecutive failures
get_consecutive_failures() {
    local iface="$1"
    echo "${consecutive_failures[$iface]:-0}"
}

# Safe getter for consecutive recoveries
get_consecutive_recoveries() {
    local iface="$1"
    echo "${consecutive_recoveries[$iface]:-0}"
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

# USR1: Instant failover trigger (from nmcli-failover-monitor.sh)
# v4.2.0 ARCHITECTURE REVIEW FIX #4: POSIX-compliant signal handler (no I/O operations)
# Signal handlers must be kept minimal - logging moved to main loop
handle_instant_failover() {
    instant_event_pending=1  # Only flag assignment - no logging (not signal-safe)
    return 0
}

# TERM: Graceful shutdown
handle_shutdown() {
    log_info "SIGTERM received - shutting down gracefully"

    # Export final metrics (no timeout - bash function not available in subshell)
    # v4.1.3 FIX: Removed timeout wrapper (caused "command not found" error)
    export_current_metrics || log_warning "Failed to export final metrics"

    # Cleanup PID file
    rm -f "$PID_FILE"

    log_info "Failover Monitor v${SCRIPT_VERSION} stopped"
    exit 0
}

trap handle_instant_failover USR1
trap handle_shutdown SIGTERM SIGINT

# ============================================================================
# FAILOVER EVALUATION
# ============================================================================

# Update consecutive counters for interfaces (no side effects)
update_interface_counters() {
    local eth0_score="$1"
    local lte0_score="$2"

    # Update PRIMARY interface counters
    if [[ $eth0_score -lt 60 ]]; then
        # Primary is degraded — counts toward FAILURE_THRESHOLD (failover pathway)
        consecutive_failures[$PRIMARY_IFACE]=$((${consecutive_failures[$PRIMARY_IFACE]:-0} + 1))
        consecutive_recoveries[$PRIMARY_IFACE]=0

        # Stability-window reset uses a separate threshold to tolerate score
        # flapping around FAILOVER_THRESHOLD_DOWN=60. Only a real degradation
        # (< STABILITY_RESET_THRESHOLD) resets the 60-minute failback-stability
        # window. Scores in [STABILITY_RESET_THRESHOLD .. 59] keep the window
        # open but continue to increment consecutive_failures (preserving
        # failover responsiveness).
        if [[ $last_primary_recovery_time -gt 0 ]] && [[ $eth0_score -lt $STABILITY_RESET_THRESHOLD ]]; then
            log_warning "PRIMARY stability window reset (eth0=$eth0_score < STABILITY_RESET_THRESHOLD=$STABILITY_RESET_THRESHOLD, was stable since $(date -d "@$last_primary_recovery_time" '+%H:%M:%S'))"
            last_primary_recovery_time=0
        fi

        log_debug "Primary degraded: eth0=$eth0_score (consecutive failures: ${consecutive_failures[$PRIMARY_IFACE]}/$FAILURE_THRESHOLD, window_kept=$([[ $eth0_score -ge $STABILITY_RESET_THRESHOLD ]] && echo yes || echo no))"
    else
        # Primary is healthy
        consecutive_failures[$PRIMARY_IFACE]=0
        local prev_recoveries=${consecutive_recoveries[$PRIMARY_IFACE]:-0}
        consecutive_recoveries[$PRIMARY_IFACE]=$((prev_recoveries + 1))

        # v4.3.1: Track stability window start (when counter goes 0→1 after degradation)
        if [[ $prev_recoveries -eq 0 ]]; then
            last_primary_recovery_time=$(date +%s)
            log_info "PRIMARY stability window started (eth0=$eth0_score, recovery from degradation)"
        fi

        log_debug "Primary healthy: eth0=$eth0_score (consecutive recoveries: ${consecutive_recoveries[$PRIMARY_IFACE]}/$RECOVERY_THRESHOLD)"
    fi

    # Update BACKUP interface counters (for diagnostics)
    if [[ $lte0_score -lt 60 ]]; then
        consecutive_failures[$BACKUP_IFACE]=$((${consecutive_failures[$BACKUP_IFACE]:-0} + 1))
        consecutive_recoveries[$BACKUP_IFACE]=0
    else
        consecutive_failures[$BACKUP_IFACE]=0
        consecutive_recoveries[$BACKUP_IFACE]=$((${consecutive_recoveries[$BACKUP_IFACE]:-0} + 1))
    fi
    return 0
}

# Detect if emergency failover is needed (returns 0=yes, 1=no)
is_emergency_failover_needed() {
    local eth0_score="$1"
    local lte0_score="$2"

    # v4.6.1 FIX: Skip if already on backup (prevent redundant failovers)
    [[ "$current_wan" == "primary" ]] \
        && [[ $eth0_score -lt $EMERGENCY_THRESHOLD ]] && [[ $lte0_score -gt 50 ]]
}

# Detect if standard failover is needed (returns 0=yes, 1=no)
is_standard_failover_needed() {
    local eth0_score="$1"
    local lte0_score="$2"

    # v4.6.1 FIX: Skip if already on backup (prevent redundant failovers)
    [[ "$current_wan" == "primary" ]] \
        && [[ $(get_consecutive_failures "$PRIMARY_IFACE") -ge $FAILURE_THRESHOLD ]] \
        && [[ $eth0_score -lt 60 ]] \
        && [[ $lte0_score -gt 70 ]] \
        && [[ $((lte0_score - eth0_score)) -gt 20 ]]
}

# Detect if severely degraded primary should force failover (v4.5.1)
# Triggers when: eth0 ≤30 AND 3+ consecutive failures (bypasses MIN_QUALITY_DELTA)
# Returns 0=yes (failover needed), 1=no
is_severely_degraded_failover_needed() {
    local eth0_score="$1"
    local lte0_score="$2"

    # Severity threshold: eth0 ≤30 is critically degraded
    local SEVERE_DEGRADATION_THRESHOLD=30

    # Conditions:
    # 0. Must be on primary (v4.6.1 FIX: prevent redundant failovers when already on backup)
    # 1. eth0 severely degraded (≤30)
    # 2. FAILURE_THRESHOLD reached (≥3 consecutive failures)
    # 3. Backup is at least minimally viable (>25 score)
    [[ "$current_wan" == "primary" ]] \
        && [[ $eth0_score -le $SEVERE_DEGRADATION_THRESHOLD ]] \
        && [[ $(get_consecutive_failures "$PRIMARY_IFACE") -ge $FAILURE_THRESHOLD ]] \
        && [[ $lte0_score -gt 25 ]]
}

# Read a Prometheus textfile metric for an interface.
# Args:  $1 = metric name (e.g. wan_dns_time_milliseconds)
#        $2 = interface (e.g. lte0)
# Echo:  integer value in ms, or empty if unavailable / stale / non-numeric.
# Staleness:  returns empty if file mtime older than WAN_QUALITY_PROM_MAX_AGE.
_get_prom_metric_ms() {
    local metric="$1"
    local interface="$2"
    # WAN_QUALITY_PROM_FILE override exists for bats tests — Production keeps the
    # node_exporter textfile-collector default. Ignored at runtime when unset.
    local prom_file="${WAN_QUALITY_PROM_FILE:-/var/lib/node_exporter/textfile_collector/wan_quality.prom}"
    local max_age="${WAN_QUALITY_PROM_MAX_AGE:-300}"

    # Unavailable → empty string (callers treat empty as "no fresh signal")
    [[ -f "$prom_file" ]] || { echo ""; return 0; }

    local mtime now age
    mtime=$(stat -c %Y "$prom_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - mtime))
    if [[ $age -gt $max_age ]]; then
        echo ""
        return 0
    fi

    # awk substr arithmetic:
    #   RSTART points at `interface` (10 chars) + `="` (2 chars) = 12 total.
    #   We want to skip `interface="` which is 11 chars, so RSTART+11 lands
    #   on the first char of the value. RLENGTH covers `interface="lte0"`
    #   so RLENGTH-12 strips `interface="` (11) + closing `"` (1) = 12.
    #   Safe for single-label lines like `{interface="lte0"}` emitted by
    #   failover-metrics-collector.py.
    local value
    value=$(awk -v m="$metric" -v iface="$interface" '
        $0 ~ "^"m"\\{interface=" {
            match($0, /interface="[^"]+"/)
            ifn = substr($0, RSTART+11, RLENGTH-12)
            if (ifn == iface) { print int($2); exit }
        }' "$prom_file" 2>/dev/null)

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo ""
    fi
}

# Emergency failback when the backup is UP but end-to-end unusable
# (DNS time >> ping time). Bypasses MIN_BACKUP_TIME and MIN_STABLE_DURATION
# to restore service quickly. Has its own cooldown so it cannot be defeated
# by ANTI_FLAPPING_DELAY.
#
# Preconditions:
#   - current_wan == "backup"
#   - primary score >= EMERGENCY_FAILBACK_MIN_PRIMARY_SCORE (60)
#   - backup DNS time > EMERGENCY_FAILBACK_DNS_THRESHOLD_MS for
#     EMERGENCY_FAILBACK_DEGRADED_CHECKS consecutive checks (default 6 × 15s = 90s)
#   - at least EMERGENCY_FAILBACK_MIN_BACKUP_TIME on backup (10min — avoids
#     racing a legitimate failover that just happened)
#   - EMERGENCY_FAILBACK_COOLDOWN (15min) since last emergency failback
#
# Side effects:
#   - increments/resets global backup_degraded_streak
#
# Returns: 0 = yes, 1 = no.
is_emergency_failback_needed() {
    local eth0_score="$1"
    local lte0_score="$2"

    [[ "$current_wan" == "backup" ]] || { backup_degraded_streak=0; return 1; }

    local backup_dns_ms
    backup_dns_ms=$(_get_prom_metric_ms "wan_dns_time_milliseconds" "$BACKUP_IFACE")

    # No fresh metric → reset streak and bail out (fail-safe)
    if [[ -z "$backup_dns_ms" ]]; then
        backup_degraded_streak=0
        return 1
    fi

    if [[ $backup_dns_ms -gt $EMERGENCY_FAILBACK_DNS_THRESHOLD_MS ]]; then
        backup_degraded_streak=$((backup_degraded_streak + 1))
        log_info "Backup end-to-end degraded: $BACKUP_IFACE DNS=${backup_dns_ms}ms > ${EMERGENCY_FAILBACK_DNS_THRESHOLD_MS}ms (streak=$backup_degraded_streak/$EMERGENCY_FAILBACK_DEGRADED_CHECKS)"
    else
        if [[ $backup_degraded_streak -gt 0 ]]; then
            log_debug "Backup DNS recovered ($BACKUP_IFACE=${backup_dns_ms}ms) — resetting degraded streak from $backup_degraded_streak"
        fi
        backup_degraded_streak=0
        return 1
    fi

    # Streak not long enough yet
    [[ $backup_degraded_streak -ge $EMERGENCY_FAILBACK_DEGRADED_CHECKS ]] || return 1

    # Safety gate: primary must be healthy enough to take over
    if [[ $eth0_score -lt $EMERGENCY_FAILBACK_MIN_PRIMARY_SCORE ]]; then
        log_debug "Emergency failback blocked: primary too weak (eth0=$eth0_score < $EMERGENCY_FAILBACK_MIN_PRIMARY_SCORE)"
        return 1
    fi

    # Minimum time on backup (avoid racing the legitimate failover we just did)
    local failover_to_backup_time=0
    if [[ -f "$LAST_FAILOVER_TO_BACKUP_FILE" ]]; then
        failover_to_backup_time=$(cat "$LAST_FAILOVER_TO_BACKUP_FILE" 2>/dev/null || echo "0")
    fi
    local current_time time_on_backup
    current_time=$(date +%s)
    time_on_backup=$((current_time - failover_to_backup_time))
    if [[ $time_on_backup -lt $EMERGENCY_FAILBACK_MIN_BACKUP_TIME ]]; then
        log_debug "Emergency failback blocked: only ${time_on_backup}s on backup (need ${EMERGENCY_FAILBACK_MIN_BACKUP_TIME}s)"
        return 1
    fi

    # Dedicated cooldown (monotonic clock, NTP-safe)
    local mono_now time_since_last
    mono_now=$(get_monotonic_time)
    time_since_last=$((mono_now - last_emergency_failback_mono))
    if [[ $last_emergency_failback_mono -gt 0 ]] && [[ $time_since_last -lt $EMERGENCY_FAILBACK_COOLDOWN ]]; then
        log_debug "Emergency failback blocked: ${time_since_last}s since last (need ${EMERGENCY_FAILBACK_COOLDOWN}s)"
        return 1
    fi

    return 0
}

# Detect if Last-Resort failover is needed (returns 0=yes, 1=no)
# v4.10.0 (25.04.2026): Quota-blocked safety net — primary catastrophic AND
# backup score=0 because the LTE quota cap clamped it. Without this path the
# system would stay on a dead primary instead of using throttled-but-routable
# LTE. Triggers extra LTE-data charges → "critical" Mattermost alert.
#
# Preconditions (ALL):
#   - current_wan == "primary"  (no flip-flop on backup)
#   - eth0 score <= LAST_RESORT_PRIMARY_THRESHOLD (catastrophic primary)
#   - lte0 score == 0  (capped, not just degraded)
#   - _lte_quota_blocked  (cap=0 reason is *quota >=100%*, not real outage)
#   - LAST_RESORT_COOLDOWN since last trigger
#
# Returns: 0 = yes, 1 = no.
is_last_resort_failover_needed() {
    local eth0_score="$1"
    local lte0_score="$2"

    # v4.10.1 (26.04.2026): Master switch — disabled by default after Incident
    # 26.04.2026. When quota is exhausted, user prefers outage over extra cost.
    [[ "${LAST_RESORT_ENABLED:-false}" == "true" ]] || return 1

    [[ "$current_wan" == "primary" ]] || return 1
    [[ $eth0_score -le $LAST_RESORT_PRIMARY_THRESHOLD ]] || return 1
    [[ $lte0_score -eq 0 ]] || return 1

    # The expensive check (Python subshell + JSON parse) only runs once the
    # cheap score gates pass — keeps per-check overhead near zero.
    _backup_quota_exhausted || return 1

    local mono_now time_since_last
    mono_now=$(get_monotonic_time)
    time_since_last=$((mono_now - last_last_resort_mono))
    if [[ $last_last_resort_mono -gt 0 ]] && [[ $time_since_last -lt $LAST_RESORT_COOLDOWN ]]; then
        log_debug "Last-Resort failover blocked: ${time_since_last}s since last (need ${LAST_RESORT_COOLDOWN}s)"
        return 1
    fi

    return 0
}

# Detect if failback is needed (returns 0=yes, 1=no)
# v4.1.5: Enhanced with perfect score override and capped hysteresis
is_failback_needed() {
    local eth0_score="$1"
    local lte0_score="$2"

    # Must be on backup and have stable recovery period
    if [[ "$current_wan" != "backup" ]] || [[ $(get_consecutive_recoveries "$PRIMARY_IFACE") -lt $RECOVERY_THRESHOLD ]]; then
        return 1
    fi

    # v4.3.0: Enforce minimum backup time (30 minutes on LTE after failover)
    local failover_to_backup_time=0
    if [[ -f "$LAST_FAILOVER_TO_BACKUP_FILE" ]]; then
        failover_to_backup_time=$(cat "$LAST_FAILOVER_TO_BACKUP_FILE" 2>/dev/null || echo "0")
    fi

    local current_time
    current_time=$(date +%s)
    local time_on_backup
    time_on_backup=$((current_time - failover_to_backup_time))

    if [[ $time_on_backup -lt $MIN_BACKUP_TIME ]]; then
        local remaining
        remaining=$((MIN_BACKUP_TIME - time_on_backup))
        local elapsed_min
        elapsed_min=$((time_on_backup / 60))
        local remaining_min
        remaining_min=$((remaining / 60))
        log_info "Failback suppressed by MIN_BACKUP_TIME: ${elapsed_min}min elapsed, ${remaining_min}min remaining (60min policy)"
        return 1
    fi

    # v4.7.0: Prolonged backup alert (rate-limited Mattermost warning)
    if [[ $time_on_backup -ge $PROLONGED_BACKUP_ALERT_TIME ]]; then
        local time_since_alert
        time_since_alert=$((current_time - last_prolonged_backup_alert))
        if [[ $time_since_alert -ge $PROLONGED_BACKUP_ALERT_INTERVAL ]]; then
            local elapsed_hours
            elapsed_hours=$((time_on_backup / 3600))
            local elapsed_remaining_min
            elapsed_remaining_min=$(( (time_on_backup % 3600) / 60 ))
            send_notification \
                "WARNUNG: System seit ${elapsed_hours}h${elapsed_remaining_min}m auf LTE-Backup!
eth0: $eth0_score/100, lte0: $lte0_score/100
LTE-Datenvolumen wird verbraucht (50GB Limit).
Failback-Status: Warte auf Stability-Requirements." \
                "warning"
            last_prolonged_backup_alert="$current_time"
            log_info "Prolonged backup alert sent (${time_on_backup}s on backup)"
        fi
    fi

    # v4.3.1: Enforce continuous stability duration (prevents failback during transient recovery)
    local stable_duration=0
    if [[ $last_primary_recovery_time -gt 0 ]]; then
        stable_duration=$((current_time - last_primary_recovery_time))
    fi

    if [[ $stable_duration -lt $MIN_STABLE_DURATION ]]; then
        local remaining
        remaining=$((MIN_STABLE_DURATION - stable_duration))
        local elapsed_min
        elapsed_min=$((stable_duration / 60))
        local remaining_min
        remaining_min=$((remaining / 60))
        log_info "Failback suppressed by MIN_STABLE_DURATION: eth0 stable for ${elapsed_min}min, need ${remaining_min}min more (60min continuous stability required)"
        return 1
    fi

    log_info "Stability requirements met: ${time_on_backup}s on backup, ${stable_duration}s eth0 stable (both >= ${MIN_BACKUP_TIME}s)"

    # v4.7.0: Prefer primary after stability requirements met
    # Rationale: After 60min on backup + 60min continuous stability,
    # primary at MIN_FAILBACK_SCORE+ is clearly functional.
    # LTE has 50GB monthly limit — prefer DSL for cost reasons.
    local min_failback_score="${MIN_FAILBACK_SCORE:-60}"
    if [[ $eth0_score -ge $min_failback_score ]]; then
        log_info "PREFER PRIMARY: eth0=${eth0_score} >= ${min_failback_score} after stability period (${time_on_backup}s on backup, ${stable_duration}s stable) — triggering failback"
        return 0
    fi

    # Special case: Perfect primary score (100) always triggers failback after stability
    if [[ $eth0_score -eq 100 ]] && [[ $eth0_score -gt $lte0_score ]]; then
        log_info "Perfect DSL score detected (100) - failback warranted after stability period"
        return 0
    fi

    # Standard hysteresis check with intelligent capping
    local hysteresis=20
    local max_possible_delta
    max_possible_delta=$((100 - lte0_score))

    # Cap hysteresis to prevent impossible conditions
    if [[ $hysteresis -gt $max_possible_delta ]]; then
        hysteresis=$max_possible_delta
        log_debug "Hysteresis capped to $hysteresis (max possible with lte0=$lte0_score)"
    fi

    # Standard failback condition with capped hysteresis
    [[ $eth0_score -gt 90 ]] && [[ $eth0_score -gt $((lte0_score + hysteresis)) ]]
}

# Process instant failover request (called from main loop, not signal handler)
# v4.2.0 FIX: Cache invalidation for BOTH interfaces + improved edge-case logic
process_instant_failover_request() {
    # v4.2.0 ARCHITECTURE REVIEW FIX #1: Invalidate cache for BOTH interfaces before scoring
    # Instant events can affect PRIMARY or BACKUP (e.g., "lte0 connected" event)
    # Using cached backup score (up to 15s stale) could cause missed failovers or delayed failbacks
    invalidate_cache "$PRIMARY_IFACE"
    invalidate_cache "$BACKUP_IFACE"  # FIX: Also invalidate backup cache

    # Get FRESH scores for BOTH interfaces (after cache invalidation)
    local eth0_score
    eth0_score=$(calculate_interface_score "$PRIMARY_IFACE")
    local lte0_score
    lte0_score=$(calculate_interface_score "$BACKUP_IFACE")  # FIX: Use calculate_interface_score (fresh) instead of get_connection_score (cached)

    log_info "Processing instant failover request: eth0=$eth0_score (fresh), lte0=$lte0_score (fresh)"

    # v4.1.7 FIX #2: Improved decision matrix with edge cases
    #
    # Decision Matrix:
    #   eth0≤25 AND lte0≤25 -> Both-Degraded (alert, no failover, maintain current)
    #   eth0≤50 AND lte0>eth0 -> Force failover (primary degraded, backup better)
    #   eth0≤50 AND lte0≤eth0 -> No failover (backup worse or equal)
    #   lte0>eth0 AND lte0>50 -> Standard failover (backup significantly better)

    # Edge Case 1: Both interfaces critically degraded - alert and maintain current
    if [[ $eth0_score -le $BOTH_DEGRADED_THRESHOLD ]] && [[ $lte0_score -le $BOTH_DEGRADED_THRESHOLD ]]; then
        log_warning "Both interfaces degraded during instant event (eth0=$eth0_score, lte0=$lte0_score) - maintaining current WAN"
        handle_both_interfaces_degraded "$eth0_score" "$lte0_score"
        return 0
    fi

    # Edge Case 2: Primary critical (≤50) AND backup is BETTER (even marginally)
    if [[ $eth0_score -le 50 ]] && [[ $lte0_score -gt $eth0_score ]]; then
        log_warning "Critical primary failure (eth0=$eth0_score ≤50, lte0=$lte0_score > eth0) - failover to backup"
        perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "instant_event"
    # Standard: Backup significantly better
    elif [[ $lte0_score -gt $eth0_score ]] && [[ $lte0_score -gt 50 ]]; then
        perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "instant_event"
    else
        log_warning "Instant failover ignored: backup not better (eth0=$eth0_score, lte0=$lte0_score)"
    fi
}

# Refresh interface scores (centralized, v4.1.1 #8)
refresh_interface_scores() {
    connection_scores[$PRIMARY_IFACE]=$(calculate_interface_score "$PRIMARY_IFACE")
    connection_scores[$BACKUP_IFACE]=$(calculate_interface_score "$BACKUP_IFACE")
    return 0
}

# Handle both interfaces down scenario (v4.1.1 #5)
handle_both_interfaces_down() {
    log_critical "BOTH INTERFACES DOWN (eth0=0, lte0=0) - entering degraded mode, maintaining current WAN"

    # Mark state
    both_interfaces_down=1

    # Reset counters to avoid stale state
    consecutive_failures[$PRIMARY_IFACE]=0
    consecutive_recoveries[$PRIMARY_IFACE]=0
    consecutive_failures[$BACKUP_IFACE]=0
    consecutive_recoveries[$BACKUP_IFACE]=0
    return 0
}

# v4.2.0 ARCHITECTURE REVIEW FIX #2: Handle both interfaces degraded with stabilization period
# Sends rate-limited Mattermost alert, maintains current WAN, saves timestamp for recovery delay
handle_both_interfaces_degraded() {
    local eth0_score="$1"
    local lte0_score="$2"

    log_critical "BOTH INTERFACES DEGRADED: eth0=$eth0_score, lte0=$lte0_score (threshold=$BOTH_DEGRADED_THRESHOLD)"

    # Mark state
    both_interfaces_down=1

    # v4.2.0 FIX #2: Save degradation timestamp for stabilization period after recovery
    local current_time
    current_time=$(date +%s)
    save_state "last_both_degraded" "$current_time"

    # Rate-limited Mattermost alert (max 1 per 5 minutes)
    local time_since_alert
    time_since_alert=$((current_time - last_degraded_alert))

    if [[ $time_since_alert -ge 300 ]]; then
        # Send notification via common.sh (includes Mattermost if configured)
        send_notification \
            "FAILOVER ALERT: Beide WAN-Interfaces degraded!
eth0: $eth0_score/100
lte0: $lte0_score/100
System bleibt auf aktuellem WAN ($current_wan).
Threshold: $BOTH_DEGRADED_THRESHOLD" \
            "critical"

        last_degraded_alert="$current_time"
        log_info "Mattermost alert sent for both-interfaces-degraded scenario"
    else
        log_debug "Mattermost alert suppressed (rate limit: $((300 - time_since_alert))s remaining)"
    fi

    # v4.2.0 FIX #2: Reset counters to avoid stale state decisions
    # After recovery, stabilization period will block failovers anyway (see check_failover_conditions)
    consecutive_failures[$PRIMARY_IFACE]=0
    consecutive_recoveries[$PRIMARY_IFACE]=0
    consecutive_failures[$BACKUP_IFACE]=0
    consecutive_recoveries[$BACKUP_IFACE]=0
    return 0
}

# ============================================================================
# FAILOVER EXECUTION
# ============================================================================

# Perform failover from one interface to another
perform_failover() {
    local from_interface="$1"
    local to_interface="$2"
    local reason="${3:-score_based}"

    local current_time
    current_time=$(date +%s)
    local eth0_score
    eth0_score=$(get_connection_score "$PRIMARY_IFACE")
    local lte0_score
    lte0_score=$(get_connection_score "$BACKUP_IFACE")

    # v4.1.1 #4: Hybrid anti-flapping (60s for instant_event, 300s for score_based/failback)
    # v4.1.2 FIX #1: Failback ALWAYS enforces anti-flapping (prevent rapid oscillation)
    # v4.6.1 FIX M3: Using monotonic clock (NTP clock skew cannot bypass or freeze cooldowns)
    local mono_now
    mono_now=$(get_monotonic_time)
    if [[ "$reason" == "failback" ]]; then
        # CRITICAL: Failback must ALWAYS respect full cooldown (recovery isn't an emergency)
        local time_since_last
        time_since_last=$((mono_now - last_failover_mono))
        if [[ $time_since_last -lt $ANTI_FLAPPING_DELAY ]]; then
            local remaining
            remaining=$((ANTI_FLAPPING_DELAY - time_since_last))
            log_warning "Failback suppressed by anti-flapping (${remaining}s remaining of 300s cooldown, last failover was ${time_since_last}s ago)"
            return 0  # Anti-flapping is not an error - return success to prevent service crash
        fi
    elif [[ "$reason" == "instant_event" ]]; then
        # Reduced cooldown for USR1 signals
        local time_since_last
        time_since_last=$((mono_now - last_failover_mono))
        if [[ $time_since_last -lt $ANTI_FLAPPING_DELAY_INSTANT ]]; then
            local remaining
            remaining=$((ANTI_FLAPPING_DELAY_INSTANT - time_since_last))
            log_warning "Instant failover suppressed by anti-flapping (${remaining}s remaining of 60s cooldown)"
            return 0  # Anti-flapping is not an error - return success to prevent service crash
        fi
    fi

    # v4.4.0: Score-based anti-flapping removed (redundant with 8 other protection layers)
    # - FAILURE_THRESHOLD=3 ensures 3 consecutive failures before failover
    # - MIN_BACKUP_TIME=60min prevents premature failback
    # - MIN_STABLE_DURATION=60min ensures DSL stability before failback
    # - Emergency (<15 score) was already exempt from cooldown
    #
    # Reasoning: 300s cooldown caused 5-minute protection gap after failover.
    # If DSL fails again immediately after failover, system should failover again
    # (after 3 consecutive failures), not wait 5 minutes with degraded service.
    #
    # Kept protections:
    # - Failback cooldown (300s) - prevents flapping back to DSL
    # - Instant-event cooldown (60s) - prevents signal-based flapping
    # - Both-down recovery stabilization (300s) - prevents oscillation after total outage
    #
    # No score-based cooldown check anymore - removed in v4.4.0

    # v4.2.0 ARCHITECTURE REVIEW FIX #6: Update timestamp AFTER route change (allow retry on failure)
    # v4.1.2 rationale (prevent USR1 race) was valid, but created worse problem: failed failover locks out retry
    # Trade-off: Accept theoretical USR1 race (rare) to allow retry on genuine route-change failure (critical)
    # Execute route changes FIRST (via routing.sh module)
    if safe_route_change "$to_interface" "$from_interface"; then
        # SUCCESS: Now update timestamp (after successful route change)
        # shellcheck disable=SC2034 # state retained for debug dumps / future hooks
        last_failover_time="$current_time"
        last_failover_mono=$(get_monotonic_time)  # v4.6.1 FIX M3: Monotonic for anti-flapping
        # v4.6.1 FIX H4: Use atomic save_state instead of echo > file
        save_state "last_failover" "$current_time"

        # v4.6.0: Log FAILOVER only AFTER successful route change (reduce log noise)
        log_info "FAILOVER: $from_interface → $to_interface | reason=$reason | scores=(eth0=$eth0_score, lte0=$lte0_score) | counters=(failures=$(get_consecutive_failures "$PRIMARY_IFACE"), recoveries=$(get_consecutive_recoveries "$PRIMARY_IFACE")) | delta=$((lte0_score - eth0_score))"

        # v4.3.0: Save timestamp when failing over TO backup (for MIN_BACKUP_TIME check)
        if [[ "$to_interface" == "$BACKUP_IFACE" ]]; then
            # v4.6.1 FIX H4: Use atomic save_state instead of echo > file
            save_state "last_failover_to_backup" "$current_time"
            log_info "Saved failover-to-backup timestamp: $current_time (MIN_BACKUP_TIME=60min check starts)"
        fi

        # Update current WAN state (for internal tracking)
        if [[ "$to_interface" == "$PRIMARY_IFACE" ]]; then
            current_wan="primary"
        else
            current_wan="backup"
        fi

        # Save active interface to state file (for failover-metrics-collector)
        save_state "active_wan" "$to_interface"

        log_notice "Failover completed: now using $to_interface"
        return 0
    else
        log_error "Failover FAILED: route switch unsuccessful - timestamp NOT updated (retry possible)"
        # DON'T update last_failover_time on failure → next check can retry immediately if conditions still warrant failover
        return 1
    fi
}

# v4.5.0: Check for critical packet loss (bypasses score-based logic)
is_critical_packet_loss() {
    local interface="$1"
    local packet_loss

    # Input validation
    if [[ -z "$interface" ]]; then
        log_error "is_critical_packet_loss: interface parameter missing"
        return 1
    fi

    # Read packet loss from WAN metrics (uses network.sh function)
    packet_loss=$(get_interface_packet_loss "$interface")

    if [[ -z "$packet_loss" ]] || [[ "$packet_loss" == "N/A" ]]; then
        log_debug "No packet loss data available for $interface"
        return 1
    fi

    # Check if packet loss exceeds critical threshold (using awk for reliability)
    if awk "BEGIN { exit !($packet_loss > $CRITICAL_PACKET_LOSS) }"; then
        log_warning "CRITICAL: Packet loss on $interface is ${packet_loss}% (threshold: ${CRITICAL_PACKET_LOSS}%)"

        # Send Mattermost alert (with error handling)
        if ! send_notification \
            "🚨 CRITICAL Packet Loss!

Interface: $interface
Packet Loss: ${packet_loss}%
Threshold: ${CRITICAL_PACKET_LOSS}%

Checking backup interface for failover..." \
            "critical"; then
            log_warning "Failed to send critical packet loss alert via Mattermost"
        fi

        return 0  # True - critical!
    fi

    return 1  # False - OK
}

# Check if failover is needed (v4.1.1 #3: Decoupled orchestrator)
check_failover_conditions() {
    local eth0_score
    eth0_score=$(get_connection_score "$PRIMARY_IFACE")
    local lte0_score
    lte0_score=$(get_connection_score "$BACKUP_IFACE")

    # Carrier-aware pre-check (Layer-1 authority, bypasses score logic).
    # If primary has no carrier (cable unplugged, modem powered off) and the
    # backup is at least physically up with score > 0 (not quota-blocked),
    # force an unconditional failover. Score heuristics are irrelevant when
    # primary is dead at Layer 1 — and an exact-threshold backup score
    # (e.g. 25 from an end-to-end DNS penalty) would otherwise be classified
    # as "backup not viable" by every score-based path. The score>0 guard
    # preserves the LAST_RESORT quota-cap protection.
    if [[ "$current_wan" == "primary" ]]; then
        local primary_carrier backup_carrier
        primary_carrier=$(cat "/sys/class/net/${PRIMARY_IFACE}/carrier" 2>/dev/null || echo "1")
        backup_carrier=$(cat "/sys/class/net/${BACKUP_IFACE}/carrier" 2>/dev/null || echo "0")

        if [[ "$primary_carrier" == "0" ]] && [[ "$backup_carrier" == "1" ]] && [[ $lte0_score -gt 0 ]]; then
            log_warning "PRIMARY NO CARRIER: $PRIMARY_IFACE Layer-1 dead, $BACKUP_IFACE viable (carrier=1, score=$lte0_score) — forcing failover (bypass score logic)"
            send_notification \
"FAILOVER (carrier pre-check) — primary Layer-1 down
$PRIMARY_IFACE: carrier=0
$BACKUP_IFACE: carrier=1, score=$lte0_score
Score logic bypassed (anti-stall)" \
                "warning" || true
            perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "primary_no_carrier"
            return 0
        fi
    fi

    # v4.5.0: Critical packet loss check - bypasses score-based logic
    if [[ "$current_wan" == "primary" ]] && is_critical_packet_loss "$PRIMARY_IFACE"; then
        # Check if backup is viable (score > 50)
        if [[ $lte0_score -gt 50 ]]; then
            log_warning "CRITICAL PACKET LOSS on primary - forcing failover to backup (lte0_score=$lte0_score)"
            perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "critical_packet_loss"
            return 0
        else
            log_warning "CRITICAL PACKET LOSS on primary but backup not viable (lte0_score=$lte0_score)"
            # Continue to normal failover logic
        fi
    fi

    # v4.10.0: Last-Resort BEFORE both_degraded — when lte0=0 is purely from
    # the quota cap (limit_pct >= 100%) and primary is catastrophic, the link
    # is still routable. Without this check, both_degraded would fire and
    # leave us offline with a dead primary plus a usable-but-capped backup.
    # Mattermost alert is "critical" because the override incurs extra costs.
    if is_last_resort_failover_needed "$eth0_score" "$lte0_score"; then
        log_warning "LAST RESORT: primary catastrophic (eth0=$eth0_score), lte0 quota-capped to 0 — overriding cap"
        send_notification \
"LAST-RESORT FAILOVER — Quota-Cap überschrieben
eth0=$eth0_score (catastrophic, ≤ ${LAST_RESORT_PRIMARY_THRESHOLD})
lte0=$lte0_score (quota-capped, limit_pct >= 100%)
DSL ist tot. LTE wird aktiviert trotz erschöpftem Volumen.
Provider berechnet evtl. Zusatzkosten — alternativ wäre System komplett offline.
Cooldown: ${LAST_RESORT_COOLDOWN}s." \
            "critical" || true
        if perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "last_resort"; then
            last_last_resort_mono=$(get_monotonic_time)
        fi
        return 0
    fi

    # v4.1.7: Both interfaces critically degraded (≤25) - alert, don't failover
    if [[ $eth0_score -le $BOTH_DEGRADED_THRESHOLD ]] && [[ $lte0_score -le $BOTH_DEGRADED_THRESHOLD ]]; then
        handle_both_interfaces_degraded "$eth0_score" "$lte0_score"
        return 0
    fi

    # Special case: Both interfaces down (v4.1.1 #5) - exact zero
    if [[ $eth0_score -eq 0 ]] && [[ $lte0_score -eq 0 ]]; then
        handle_both_interfaces_down
        return 0
    elif (( both_interfaces_down == 1 )); then
        # v4.2.0 ARCHITECTURE REVIEW FIX #2: Recovery from both-down state with stabilization period
        log_info "Recovering from both-down state: eth0=$eth0_score, lte0=$lte0_score"

        # Check if stabilization period has elapsed
        local last_degraded
        last_degraded=$(load_state "last_both_degraded" "0")
        local current_time
        current_time=$(date +%s)
        local time_since
        time_since=$((current_time - last_degraded))

        if [[ $time_since -lt 300 ]]; then
            # Stabilization period: 5 minutes (300s) after both-degraded recovery
            # Prevents rapid failovers if interfaces are still unstable
            local remaining
            remaining=$((300 - time_since))
            log_info "Both-degraded recovery stabilization period active: ${time_since}s elapsed, ${remaining}s remaining (300s total)"
            return 0  # Block any failover decisions during stabilization
        fi

        # Stabilization period complete - clear state and allow re-evaluation
        both_interfaces_down=0
        log_info "Stabilization period complete - normal failover logic resumed"
        # Counters already reset in handle_both_interfaces_degraded(), continue to decision tree
    fi

    # Update counters first (no side effects)
    update_interface_counters "$eth0_score" "$lte0_score"

    # Decision tree (clear priority, v4.1.1 #3)
    # v4.1.2 FIX #2: Emergency bypass only applies to FAILOVER (primary→backup), NOT failback
    if is_emergency_failover_needed "$eth0_score" "$lte0_score"; then
        log_warning "EMERGENCY: eth0 score critical ($eth0_score < $EMERGENCY_THRESHOLD), lte0 available ($lte0_score)"
        perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "emergency"
    # v4.5.1: Severely degraded primary (bypasses MIN_QUALITY_DELTA)
    elif is_severely_degraded_failover_needed "$eth0_score" "$lte0_score"; then
        log_warning "SEVERELY DEGRADED: eth0=$eth0_score ≤30 with $(get_consecutive_failures "$PRIMARY_IFACE") failures - forcing failover (bypass MIN_QUALITY_DELTA)"
        perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "severely_degraded"
    elif is_standard_failover_needed "$eth0_score" "$lte0_score"; then
        log_info "Failover triggered: eth0=$eth0_score, lte0=$lte0_score (delta >20, $(get_consecutive_failures "$PRIMARY_IFACE") consecutive failures)"
        perform_failover "$PRIMARY_IFACE" "$BACKUP_IFACE" "score_based"
    elif is_emergency_failback_needed "$eth0_score" "$lte0_score"; then
        # Backup is UP but end-to-end unusable.
        # Skip MIN_BACKUP_TIME/MIN_STABLE_DURATION — service is effectively
        # offline right now. Dedicated cooldown in is_emergency_failback_needed
        # protects against ping-pong. Use "failback" reason so perform_failover
        # still enforces ANTI_FLAPPING_DELAY as a second safety net.
        #
        # Pre-check ANTI_FLAPPING_DELAY explicitly: perform_failover returns 0
        # both on success AND on anti-flapping suppression, so without a pre-
        # check we would poison last_emergency_failback_mono on a blocked call
        # and burn the 15min cooldown without an actual route change.
        local _mono_now _time_since_last_fo
        _mono_now=$(get_monotonic_time)
        _time_since_last_fo=$((_mono_now - last_failover_mono))
        if [[ $_time_since_last_fo -lt $ANTI_FLAPPING_DELAY ]]; then
            log_warning "EMERGENCY FAILBACK deferred: ANTI_FLAPPING_DELAY active (${_time_since_last_fo}s of ${ANTI_FLAPPING_DELAY}s elapsed) — not updating cooldown state"
        else
            log_warning "EMERGENCY FAILBACK: $BACKUP_IFACE end-to-end degraded (DNS slow), eth0=$eth0_score ready — triggering failback"
            send_notification \
"EMERGENCY FAILBACK — $BACKUP_IFACE end-to-end degraded
eth0=$eth0_score  |  lte0=$lte0_score
DNS response on $BACKUP_IFACE exceeded ${EMERGENCY_FAILBACK_DNS_THRESHOLD_MS}ms for ${EMERGENCY_FAILBACK_DEGRADED_CHECKS} checks.
Stability requirements (MIN_BACKUP_TIME/MIN_STABLE_DURATION) bypassed." \
                "warning" || true
            if perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "failback"; then
                # Only reached if perform_failover path succeeded past its own
                # anti-flapping check. Since we pre-checked, the only path here
                # is a real route change success (or route-change failure that
                # returns non-zero, which this `if` correctly skips).
                last_emergency_failback_mono=$(get_monotonic_time)
                backup_degraded_streak=0
            fi
        fi
    elif is_failback_needed "$eth0_score" "$lte0_score"; then
        log_info "Failback triggered: eth0 recovered and stable (eth0=$eth0_score > lte0=$lte0_score+20, $(get_consecutive_recoveries "$PRIMARY_IFACE") consecutive successes)"
        # v4.1.2: Failback uses "failback" reason (NOT "emergency") to enforce anti-flapping
        perform_failover "$BACKUP_IFACE" "$PRIMARY_IFACE" "failback"
    else
        # v4.1.1 #7 + v4.1.3 FIX: Changed to log_info (was log_debug - invisible in production!)
        log_info "No failover: eth0=$eth0_score lte0=$lte0_score | failures=$(get_consecutive_failures "$PRIMARY_IFACE")/$FAILURE_THRESHOLD | recoveries=$(get_consecutive_recoveries "$PRIMARY_IFACE")/$RECOVERY_THRESHOLD | current_wan=$current_wan"
    fi

    return 0
}

# ============================================================================
# METRICS EXPORT
# ============================================================================

# Export current metrics to JSON (for failover-metrics-collector.py)
export_current_metrics() {
    local primary_score="${connection_scores[$PRIMARY_IFACE]:-0}"
    local backup_score="${connection_scores[$BACKUP_IFACE]:-0}"

    export_metrics_json "$primary_score" "$backup_score"
    return 0
}

# ============================================================================
# MONITORING LOOP
# ============================================================================

main() {
    # v4.1.3 EMERGENCY FIX: Force stdout logging for systemd journal
    export LOG_TO_STDOUT=true
    export LOG_FORMAT=standard

    log_info "Failover Monitor v${SCRIPT_VERSION} starting (modular architecture)"
    log_info "Primary: $PRIMARY_IFACE, Backup: $BACKUP_IFACE"
    log_info "Check interval: ${CHECK_INTERVAL}s, Metrics export: ${METRICS_EXPORT_INTERVAL}s"

    # Double-check logging works (emergency diagnostic)
    echo "[EMERGENCY] Failover Monitor v${SCRIPT_VERSION} started - stdout direct echo" >&2

    # Registriere Script für Änderungs-Erkennung (exit 0 bei Code-Änderung → systemd restart)
    script_watch_init "${BASH_SOURCE[0]}"

    # Write PID file for signal handling
    echo "$$" > "$PID_FILE"
    chmod 644 "$PID_FILE"  # Allow nmcli-failover-monitor to read for USR1 signal

    # Initialize cache structures
    init_cache_structures

    # Initialize state directory (defensive check for STATE_FILE)
    [[ -n "${STATE_FILE:-}" ]] && {
        mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
        chmod 755 "$(dirname "$STATE_FILE")" 2>/dev/null || true
    } || log_warning "STATE_FILE not defined, skipping state directory init"

    # Initialise active_wan state file if missing.
    # RuntimeDirectory=wan-state clears STATE_FILE on every service restart, so
    # detect the active WAN from the kernel routing table instead of defaulting
    # to "primary",
    # which would disrupt an in-flight failover (metric 500 reset to 50).
    if [[ ! -f "$STATE_FILE" ]]; then
        local actual_dev
        actual_dev=$(ip route get 8.8.8.8 2>/dev/null | grep -o "dev [^ ]*" | awk '{print $2}')
        if [[ "$actual_dev" == "${BACKUP_IFACE:-lte0}" ]]; then
            save_state "active_wan" "$BACKUP_IFACE"
            current_wan="backup"
            log_info "Initialized active_wan state: backup (detected from routing: traffic via $actual_dev)"
        else
            save_state "active_wan" "$PRIMARY_IFACE"
            current_wan="primary"
            log_info "Initialized active_wan state: primary (detected from routing: traffic via ${actual_dev:-unknown})"
        fi
    else
        # v4.6.1 FIX M7: Do NOT use local - must update GLOBAL current_wan variable
        # Previous: `local current_wan` shadowed the global (line 270), causing wrong state after restart
        current_wan=$(load_state "active_wan" "primary")
        log_info "Preserved active_wan state: $current_wan (from previous run)"
    fi

    local iteration=0
    local next_run
    next_run=$(date +%s)  # v4.1.1 #11: Fixed-rate timing

    while true; do
        ((iteration++)) || true
        local loop_start
        loop_start=$(date +%s)

        # v4.1.1 #11: Calculate next run time BEFORE work (prevents drift)
        next_run=$((loop_start + CHECK_INTERVAL))

        # v4.2.0 FIX #4: Process pending instant_event flag (signal handler safety, logging in main loop)
        # v4.6.1 FIX H1: Re-check after processing - second USR1 during process_instant_failover_request() was lost
        if (( instant_event_pending == 1 )); then
            instant_event_pending=0
            log_info "USR1 signal received - processing instant failover check"  # Moved from signal handler (POSIX-compliance)
            process_instant_failover_request
            # Re-check: USR1 may have arrived during processing (15-30s window)
            if (( instant_event_pending == 1 )); then
                instant_event_pending=0
                log_info "Additional USR1 received during processing - re-checking"
                process_instant_failover_request
            fi
        fi

        # v4.1.1 #8: Centralized score refresh (prevents duplication)
        refresh_interface_scores

        local eth0_score
        eth0_score=$(get_connection_score "$PRIMARY_IFACE")
        local lte0_score
        lte0_score=$(get_connection_score "$BACKUP_IFACE")

        # v4.1.3 FIX: Changed to log_info (monitoring visibility in production)
        log_info "Check #$iteration: eth0=$eth0_score, lte0=$lte0_score, wan=$current_wan"

        # Export metrics every METRICS_EXPORT_INTERVAL seconds
        local current_time
        current_time=$(date +%s)
        if [[ $((current_time - last_metrics_export)) -ge $METRICS_EXPORT_INTERVAL ]]; then
            if ! export_current_metrics; then
                log_warning "Metrics export failed (non-critical)"
            fi
            last_metrics_export="$current_time"
        fi

        # Check failover conditions
        check_failover_conditions

        # Periodic cache cleanup (every 10 iterations)
        if [[ $((iteration % 10)) -eq 0 ]]; then
            cleanup_cache
        fi

        # Log performance stats (every 20 iterations = 10 minutes @ 30s interval)
        if [[ $((iteration % 20)) -eq 0 ]]; then
            log_info "$(get_performance_stats)"
        fi

        # Prüfe ob Script-Datei geändert wurde — exit 0 triggert systemd Restart mit neuer Version
        script_watch_check "$iteration"

        # v4.1.1 #11: Sleep until next_run (fixed-rate, no drift)
        local now
        now=$(date +%s)
        local sleep_time
        sleep_time=$((next_run - now))

        if [[ $sleep_time -gt 0 ]]; then
            sleep "$sleep_time"
        else
            log_warning "Check duration exceeded interval (overrun: $((sleep_time * -1))s)"
            # Don't sleep, run immediately but log the overrun
        fi
    done
}

# ============================================================================
# LIBRARY MODE SUPPORT (for BATS testing)
# ============================================================================
# When FAILOVER_MONITOR_LIB_MODE=1, script returns after loading functions
# This allows unit tests to source functions without starting the monitor loop
if [[ "${FAILOVER_MONITOR_LIB_MODE:-0}" == "1" ]]; then
    return 0 2>/dev/null || true  # return works when sourced
fi

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit $?
fi

# If sourced without LIB_MODE, return cleanly (don't exit, would kill parent shell)
return 0 2>/dev/null || exit 0
