#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# performance.sh — performance module for linux-dual-wan-failover
#
# This file is meant to be sourced from the failover services, not
# executed directly. See docs/reference/architecture-overview.md for
# the role of this module in the overall system.
#
set -uo pipefail  # Removed -e: Explicit error handling (Best Practice 2025)

# ============================================================================
# PERFORMANCE CONFIGURATION
# ============================================================================

# Event system performance metrics
event_signal_latency=0
event_signal_count=0
event_processing_time=0
emergency_failover_time=0

# ============================================================================
# MODULE MAP — 17 Funktionen in 4 Gruppen
# ============================================================================
#
# 1. INTERFACE TESTS — Multi-Metrik Scoring (→ Zeile 68)
#    test_interface_comprehensive()  4 Tests → Gesamt-Score (0-100) + LTE-Bonus
#    test_connectivity_score()       Ping zu CHECK_IPS → 0-25 Punkte
#    test_dns_score()                DNS-Auflösung → 0-25 Punkte
#    test_gateway_score()            Gateway-Ping → 0-25 Punkte
#    test_http_score()               HTTP curl → 0-25 Punkte
#    perform_ping_test()             Ping mit Timeout
#    _end_to_end_penalty()           WAN-Quality-Prom-basierter Penalty (v4.8.0)
#    _backup_quota_cap()             Backup-link Quota Cap
#    _backup_quota_exhausted()       Quota-exhausted Check
#
# 2. EVENT PERFORMANCE METRICS — Signal-/Failover-Zeitmessung (→ Zeile 412)
#    record_event_signal_latency()    Signal-Latenz aufzeichnen
#    record_event_processing_time()   Verarbeitungszeit aufzeichnen
#    record_emergency_failover_time() Emergency-Failover-Dauer aufzeichnen
#    get_event_performance_stats()    Durchschnitts-Statistiken
#    get_performance_stats()          Event Gesamtstatistik
#
# 3. METRICS EXPORT — Score-Berechnung und JSON-Export (→ Zeile 453)
#    calculate_interface_score()  test_interface_comprehensive + connection_scores
#    export_metrics_json()        JSON-Metriken für failover-metrics-collector.py
#
# Cache-Framework entfernt: ~330 Zeilen die durch die Subshell-Architektur
# ($(...) um calculate_interface_score) nie wirkten. Verifiziert im Review
# (dauerhaft "0% hit rate (0/0), 0 entries").
# ============================================================================

# ============================================================================
# PING TEST
# ============================================================================

# Perform actual ping test with timeout and metrics
perform_ping_test() {
    local target="$1"
    local interface="$2"
    local timeout=2

    # Use timeout to prevent hanging
    timeout $timeout ping -c 1 -W 1 -I "$interface" "$target" 2>/dev/null | grep -q 'time='
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "success"
        return 0
    elif [[ $exit_code -eq 124 ]]; then
        log "DEBUG" "Ping timeout on $interface to $target after ${timeout}s"
        echo "timeout"
        return 1
    else
        log "DEBUG" "Ping failed on $interface to $target (exit: $exit_code)"
        echo "failure"
        return 1
    fi
}

# ============================================================================
# COMPREHENSIVE INTERFACE TESTING
# ============================================================================

# End-to-end penalty derived from wan_quality.prom.
# The 4×25 binary tests miss throttled-but-UP uplinks: ping/DNS/HTTP succeed,
# but actual DNS resolution takes ~1 s and HTTP clients time out. This penalty
# reads the Prometheus DNS-time metric (written by failover-metrics-collector)
# and reduces the score when end-to-end latency is poor.
#
# Args:   $1 = interface (eth0, lte0, ...)
# Echo:   integer penalty in points to SUBTRACT from total_score (0-55)
# Fallback: 0 if prom file is missing, stale (>WAN_QUALITY_PROM_MAX_AGE), or
#           contains no numeric value for this interface.
_end_to_end_penalty() {
    local interface="$1"
    # WAN_QUALITY_PROM_FILE override exists for bats tests (see failover-monitor:_get_prom_metric_ms).
    local prom_file="${WAN_QUALITY_PROM_FILE:-/var/lib/node_exporter/textfile_collector/wan_quality.prom}"
    local max_age="${WAN_QUALITY_PROM_MAX_AGE:-300}"
    local penalty=0

    # NOTE: This function is called inside `$(...)` command substitution
    # (via calculate_interface_score → test_interface_comprehensive). The
    # `log` wrapper writes to STDOUT with LOG_FORMAT=compact, which would
    # corrupt the penalty value echoed at the end. All log() calls here
    # MUST be redirected to stderr (`>&2`).

    [[ -f "$prom_file" ]] || { echo "0"; return 0; }

    # Mtime-based staleness (survives a stuck collector that keeps old values)
    local mtime now age
    mtime=$(stat -c %Y "$prom_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - mtime))
    if [[ $age -gt $max_age ]]; then
        log "DEBUG" "wan_quality.prom stale (${age}s > ${max_age}s), skipping E2E penalty for $interface" >&2
        echo "0"
        return 0
    fi

    # DNS-time penalty: three distinct bands (0 / 15 / 25 / 40)
    local dns_ms
    dns_ms=$(awk -v iface="$interface" '
        /^wan_dns_time_milliseconds\{interface=/ {
            match($0, /interface="[^"]+"/)
            ifn = substr($0, RSTART+11, RLENGTH-12)
            if (ifn == iface) { print int($2); exit }
        }' "$prom_file" 2>/dev/null)

    # Three-tier DNS-time penalty (distinct bands, no dead branch):
    #   >1500ms → -40 (deep throttling / tunnel broken)
    #   > 800ms → -25 (provider-side slowdown — matches EMERGENCY_FAILBACK trigger)
    #   > 500ms → -15 (slow but usable)
    if [[ -n "$dns_ms" ]] && [[ "$dns_ms" =~ ^[0-9]+$ ]]; then
        if [[ $dns_ms -gt 1500 ]]; then
            penalty=$((penalty + 40))
        elif [[ $dns_ms -gt 800 ]]; then
            penalty=$((penalty + 25))
        elif [[ $dns_ms -gt 500 ]]; then
            penalty=$((penalty + 15))
        fi
    fi

    # HTTP-time penalty: 0 / 25 bands
    local http_ms
    http_ms=$(awk -v iface="$interface" '
        /^wan_http_time_milliseconds\{interface=/ {
            match($0, /interface="[^"]+"/)
            ifn = substr($0, RSTART+11, RLENGTH-12)
            if (ifn == iface) { print int($2); exit }
        }' "$prom_file" 2>/dev/null)

    if [[ -n "$http_ms" ]] && [[ "$http_ms" =~ ^[0-9]+$ ]]; then
        if [[ $http_ms -gt 2000 ]]; then
            penalty=$((penalty + 25))
        fi
    fi

    echo "$penalty"
}

# ----------------------------------------------------------------------------
# Backup-link quota cap
# ----------------------------------------------------------------------------
# Reads QUOTA_SNAPSHOT_PATH (written by the configured quota provider plugin —
# see plugins/quota-providers/) and returns a score cap when the backup link
# is near or over its monthly quota.
#
# Tiers come from QUOTA_CAP_TIER_{90,96,100} in failover.conf:
#   ≥100%  → QUOTA_CAP_TIER_100  (default 0:  block failover)
#   ≥96%   → QUOTA_CAP_TIER_96   (default 10: primary wins even if heavily degraded)
#   ≥90%   → QUOTA_CAP_TIER_90   (default 40: primary wins at normal scores)
#    <90%  → no cap
#
# Returns empty (no cap) when:
#   - QUOTA_PROVIDER=none (default; plugin disabled)
#   - snapshot file missing
#   - snapshot is older than QUOTA_SNAPSHOT_MAX_STALE_SEC
#   - limit_pct is null (no quota configured upstream)
#
# Called from test_interface_comprehensive. Output goes to stdout in a
# command substitution, so all logs MUST go to stderr (>&2).
# ----------------------------------------------------------------------------
_backup_quota_cap() {
    [[ "${QUOTA_PROVIDER:-none}" != "none" ]] || return 0

    local json="${QUOTA_SNAPSHOT_PATH:-/var/lib/linux-dual-wan-failover/quota-snapshot.json}"
    local max_stale="${QUOTA_SNAPSHOT_MAX_STALE_SEC:-3600}"
    local tier90="${QUOTA_CAP_TIER_90:-40}"
    local tier96="${QUOTA_CAP_TIER_96:-10}"
    local tier100="${QUOTA_CAP_TIER_100:-0}"

    [[ -f "$json" ]] || return 0

    # Mtime-based staleness — the snapshot's own `collected_at` field
    # would lie if the provider crashed mid-write or the collector is
    # stuck. File mtime cannot lie.
    local mtime now age
    mtime=$(stat -c %Y "$json" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - mtime))
    if [[ $age -gt $max_stale ]]; then
        log "DEBUG" "quota snapshot stale (${age}s > ${max_stale}s), skipping cap" >&2
        return 0
    fi

    local result
    result=$(python3 - "$json" "$tier90" "$tier96" "$tier100" <<'PYEOF' 2>/dev/null
import json, sys
path = sys.argv[1]
t90, t96, t100 = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
try:
    with open(path) as f:
        d = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

pct = d.get("limit_pct")
if pct is None:
    sys.exit(0)

pct = float(pct)
if pct >= 100:
    print(t100)
elif pct >= 96:
    print(t96)
elif pct >= 90:
    print(t90)
PYEOF
)
    [[ -n "$result" ]] && echo "$result"
    return 0
}

# ----------------------------------------------------------------------------
# Backup-link quota fully exhausted (limit_pct >= 100 %)
# ----------------------------------------------------------------------------
# Returns 0 (true) only when the snapshot reports limit_pct >= 100 %.
# Returns 1 (false) for disabled provider, missing/stale snapshots, lower
# percentages, or any parsing error — the conservative default.
#
# Used by failover-monitor::is_last_resort_failover_needed to distinguish
# "backup scored 0 because real connectivity failed" (no failover possible)
# from "backup scored 0 because the quota cap forced it to 0" (link
# routing-layer reachable). Only the latter justifies overriding the cap.
# ----------------------------------------------------------------------------
_backup_quota_exhausted() {
    [[ "${QUOTA_PROVIDER:-none}" != "none" ]] || return 1

    local json="${QUOTA_SNAPSHOT_PATH:-/var/lib/linux-dual-wan-failover/quota-snapshot.json}"
    local max_stale="${QUOTA_SNAPSHOT_MAX_STALE_SEC:-3600}"

    [[ -f "$json" ]] || return 1

    local mtime now age
    mtime=$(stat -c %Y "$json" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - mtime))
    [[ $age -le $max_stale ]] || return 1

    python3 - "$json" >/dev/null 2>&1 <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

pct = d.get("limit_pct")
if pct is None:
    sys.exit(1)
sys.exit(0 if float(pct) >= 100 else 1)
PYEOF
}

# Test interface with multiple metrics
test_interface_comprehensive() {
    local interface="$1"
    local total_score=0

    # Connectivity test (25 points)
    local connectivity_score
    connectivity_score=$(test_connectivity_score "$interface")
    total_score=$((total_score + connectivity_score))

    # DNS test (25 points)
    local dns_score
    dns_score=$(test_dns_score "$interface")
    total_score=$((total_score + dns_score))

    # Gateway test (25 points)
    local gateway_score
    gateway_score=$(test_gateway_score "$interface")
    total_score=$((total_score + gateway_score))

    # HTTP test (25 points)
    local http_score
    http_score=$(test_http_score "$interface")
    total_score=$((total_score + http_score))

    # NOTE: test_interface_comprehensive is invoked via `$(calculate_interface_score ...)`.
    # The score is captured from stdout, so any log output here must go to stderr
    # or the caller will receive garbage as the score.
    log "DEBUG" "Interface $interface scores: conn=$connectivity_score, dns=$dns_score, gw=$gateway_score, http=$http_score, total=$total_score" >&2

    # Interface-type adjustment for cellular connections.
    # LTE has inherently higher latency due to physics. Applied BEFORE
    # the E2E penalty so a throttled LTE loses the bonus to the penalty
    # (intended behavior — bonus rewards low-latency LTE, not all LTE).
    if [[ "$interface" == lte* ]] || [[ "$interface" == wwan* ]]; then
        if [[ $total_score -ge 70 ]]; then
            local lte_bonus=15
            total_score=$((total_score + lte_bonus))
            log "DEBUG" "LTE bonus applied to $interface: +$lte_bonus (cellular latency adjustment, physics-aware scoring)" >&2
        fi
    fi

    # v4.8.0: End-to-end penalty for slow DNS/HTTP (real user-perceived latency)
    local e2e_penalty
    e2e_penalty=$(_end_to_end_penalty "$interface")
    if [[ -n "$e2e_penalty" ]] && [[ "$e2e_penalty" =~ ^[0-9]+$ ]] && [[ $e2e_penalty -gt 0 ]]; then
        total_score=$((total_score - e2e_penalty))
        log "INFO" "E2E penalty applied to $interface: -$e2e_penalty (throttled/slow uplink detected via wan_quality.prom)" >&2
    fi

    # Backup-link quota cap. The cap applies when this is the configured
    # BACKUP_IFACE and the quota-provider plugin reports the link near or
    # over its monthly quota — failing over to a throttled or capped link
    # is usually worse than staying on a degraded primary.
    if [[ "$interface" == "${BACKUP_IFACE:-lte0}" ]]; then
        local limit_cap
        limit_cap=$(_backup_quota_cap)
        if [[ -n "$limit_cap" ]] && [[ "$limit_cap" =~ ^[0-9]+$ ]] && [[ $total_score -gt $limit_cap ]]; then
            log "INFO" "backup-quota cap applied to $interface: score $total_score -> $limit_cap" >&2
            total_score=$limit_cap
        fi
    fi

    # Clamp to [0, 100]
    if [[ $total_score -gt 100 ]]; then
        total_score=100
    elif [[ $total_score -lt 0 ]]; then
        total_score=0
    fi

    echo "$total_score"
}

# Test connectivity to multiple targets
test_connectivity_score() {
    local interface="$1"
    local success_count=0
    local total_targets=${#CHECK_IPS[@]}

    for target in "${CHECK_IPS[@]}"; do
        if perform_ping_test "$target" "$interface" | grep -q "success"; then
            ((success_count++)) || true
        fi
    done

    # Calculate score (0-25 based on success ratio)
    local score=0
    if [[ $total_targets -gt 0 ]]; then
        score=$((success_count * 25 / total_targets))
    fi
    echo "$score"
}

# Test DNS resolution with interface binding (DoH-based)
# Returns 25 on success, 0 on failure.
test_dns_score() {
    local interface="$1"
    local score=0
    local result
    result=$(measure_dns_doh "$interface" "google.com")
    if [[ "$result" != "999" ]]; then
        score=25
    fi
    echo "$score"
}

# Test gateway reachability
test_gateway_score() {
    local interface="$1"
    local gateway
    gateway=$(ip route show dev "$interface" | grep default | awk '{print $3}' | head -1)

    if [[ -z "$gateway" ]]; then
        echo "0"
        return 0
    fi

    # Test gateway ping
    if perform_ping_test "$gateway" "$interface" | grep -q "success"; then
        echo "25"
    else
        echo "0"
    fi
}

# Test HTTP connectivity
test_http_score() {
    local interface="$1"

    # Simple HTTP test
    if timeout 5 curl -s --interface "$interface" -m 3 http://google.com &>/dev/null; then
        echo "25"
    else
        echo "0"
    fi
}

# ============================================================================
# EVENT PERFORMANCE METRICS
# ============================================================================

# Record event signal processing time
record_event_signal_latency() {
    local latency="$1"
    ((event_signal_count++)) || true
    event_signal_latency=$((event_signal_latency + latency))

    log "DEBUG" "Event signal latency recorded: ${latency}ms (count: $event_signal_count)"
}

# Record event processing time
record_event_processing_time() {
    local processing_time="$1"
    event_processing_time="$processing_time"

    log "DEBUG" "Event processing time: ${processing_time}ms"
}

# Record emergency failover completion time
record_emergency_failover_time() {
    local failover_time="$1"
    emergency_failover_time="$failover_time"

    log "INFO" "Emergency failover completed in: ${failover_time}ms"
}

# Get event performance statistics
get_event_performance_stats() {
    local avg_signal_latency=0

    if [[ $event_signal_count -gt 0 ]]; then
        avg_signal_latency=$((event_signal_latency / event_signal_count))
    fi

    echo "Event Performance: ${event_signal_count} signals, avg latency ${avg_signal_latency}ms, last processing ${event_processing_time}ms, last failover ${emergency_failover_time}ms"
}

# Get comprehensive performance statistics
get_performance_stats() {
    get_event_performance_stats
}

# ============================================================================
# METRICS EXPORT
# ============================================================================

# Calculate comprehensive interface score (0-100)
# Returns: Integer score representing interface health and performance
calculate_interface_score() {
    local interface="$1"

    # Use cached comprehensive test result
    local score
    score=$(test_interface_comprehensive "$interface")

    # Store in global connection_scores array (if defined)
    if declare -p connection_scores &>/dev/null 2>&1; then
        connection_scores[$interface]="$score"
    fi

    echo "$score"
    return 0
}

# Export metrics to JSON file for failover-metrics-collector.py.
#
# The schema uses semantic keys (primary/backup) so the collector and any
# downstream consumers do not have to know the operator's interface names.
# The actual interface names are still emitted as primary_interface /
# backup_interface for human-readable Prometheus labels.
#
# IMPORTANT: only failover-monitor writes the active_wan state file. Do not
# derive `current_wan` from scores here — that race caused phantom failover
# events in the past.
#
# Args: $1 = primary score, $2 = backup score
export_metrics_json() {
    local primary_score="${1:-0}"
    local backup_score="${2:-0}"
    local primary_iface="${PRIMARY_IFACE:-eth0}"
    local backup_iface="${BACKUP_IFACE:-lte0}"
    local metrics_file="${METRICS_FILE:-/run/linux-dual-wan-failover/wan-state/connection_metrics}"

    local primary_failures="${consecutive_failures[$primary_iface]:-0}"
    local primary_recoveries="${consecutive_recoveries[$primary_iface]:-0}"
    local backup_failures="${consecutive_failures[$backup_iface]:-0}"
    local backup_recoveries="${consecutive_recoveries[$backup_iface]:-0}"

    local temp_file="${metrics_file}.tmp"
    cat > "$temp_file" <<EOF
{
    "timestamp": $(date +%s),
    "current_wan": "${current_wan:-primary}",
    "primary_interface": "${primary_iface}",
    "backup_interface": "${backup_iface}",
    "primary_score": ${primary_score},
    "backup_score": ${backup_score},
    "counters": {
        "primary": {"failures": ${primary_failures}, "recoveries": ${primary_recoveries}},
        "backup":  {"failures": ${backup_failures},  "recoveries": ${backup_recoveries}}
    },
    "thresholds": {
        "failure":  ${FAILURE_THRESHOLD:-3},
        "recovery": ${RECOVERY_THRESHOLD:-20}
    }
}
EOF

    mv -f "$temp_file" "$metrics_file" 2>/dev/null || {
        log "ERROR" "Failed to write metrics file: $metrics_file"
        return 1
    }
    chmod 644 "$metrics_file" 2>/dev/null || true

    log "DEBUG" "Exported metrics: primary=${primary_score} backup=${backup_score} wan=${current_wan:-primary}"
    return 0
}

# Export functions for use by main script
export -f perform_ping_test test_interface_comprehensive
export -f record_event_signal_latency record_event_processing_time
export -f record_emergency_failover_time get_event_performance_stats get_performance_stats
export -f calculate_interface_score export_metrics_json
