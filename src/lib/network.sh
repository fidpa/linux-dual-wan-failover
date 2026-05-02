#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# network.sh — network module for linux-dual-wan-failover
#
# This file is meant to be sourced from the failover services, not
# executed directly. See docs/reference/architecture-overview.md for
# the role of this module in the overall system.
#
set -uo pipefail  # Removed -e: Explicit error handling (Best Practice 2025)

# ============================================================================
# NETWORK CONFIGURATION
# ============================================================================

# Test targets and configuration
readonly DEFAULT_CHECK_IPS=("8.8.8.8" "1.1.1.1" "9.9.9.9" "208.67.222.222")
readonly DEFAULT_DNS_SERVERS=("8.8.8.8" "1.1.1.1")
readonly DEFAULT_DNS_TEST_DOMAINS=("google.com" "cloudflare.com")

# Network test timeouts
readonly PING_TIMEOUT=2
readonly DNS_TIMEOUT=3
readonly HTTP_TIMEOUT=5

# ============================================================================
# MODULE MAP — 32 Funktionen in 5 Gruppen
# ============================================================================
#
# 1. CONNECTIVITY TESTS — Pass/Fail-Checks (→ Zeile 44)
#    test_connectivity()        Ping zu 4 public IPs, gibt Success-Rate zurück
#    test_ping_target()         Einzelner Ping-Test gegen ein Ziel
#    test_dns()                 DNS-Auflösung mit Interface-Binding
#    test_dns_server()          Einzelner DNS-Server-Test (dig + nslookup Fallback)
#    test_gateway()             Gateway-Erreichbarkeit via Ping
#    get_gateway()              Gateway-IP für ein Interface auslesen
#    test_http_connectivity()   HTTP-Erreichbarkeit (pass/fail)
#
# 2. SCORING — Metriken → 0-100 Score (→ Zeile 215)
#    assess_network_quality()   Wrapper → calculate_weighted_score()
#    calculate_weighted_score() Haupt-Score: Connectivity 40% + Latency 30% + Loss 30%
#    calculate_latency_score()  Latenz (ms) → Score (0-100)
#    calculate_loss_score()     Paketverlust (%) → Score (0-100)
#    calculate_dns_score()      DNS-Zeit (ms) → Score [WAN-Monitoring only, nicht Failover]
#    calculate_http_score()     HTTP-Zeit (ms) → Score [WAN-Monitoring only, nicht Failover]
#    compare_interfaces()       Zwei Interfaces vergleichen, gibt besseres zurück
#
# 3. MEASUREMENTS — Rohdaten sammeln (→ Zeile 499)
#    measure_latency()          Durchschnitts-Latenz über n Samples
#    measure_packet_loss()      Paketverlust-Prozentsatz (ping -c n)
#    measure_jitter()           Latenz-Standardabweichung über n Samples
#    measure_dns_time()         DNS-Auflösungszeit in ms (dig -b)
#    measure_http_time()        HTTP-Verbindungszeit in ms
#    measure_dns_performance()  DNS-Performance-Messung (Alias für measure_dns_time)
#    measure_http_performance() HTTP-Performance mit HTTP-Code-Validierung
#    test_wan_quality()         Composite WAN-Assessment → JSON (latency/loss/jitter/dns/http)
#    measure_dns_detailed()     Multi-Resolver DNS-Analyse → JSON (Google/Cloudflare/ISP)
#    test_bandwidth()           Bandwidth-Test via curl (kbps)
#
# 4. PROMETHEUS INTEGRATION — Prometheus first, Live-Messung als Fallback (→ Zeile 553)
#    get_interface_latency()    wan_quality.prom → Fallback: measure_latency()
#    get_interface_packet_loss() wan_quality.prom → Fallback: measure_packet_loss()
#    get_interface_dns_time()   wan_quality.prom → Fallback: test_dns()
#    get_interface_http_time()  wan_quality.prom → Fallback: test_http_connectivity()
#
# 5. INTERFACE UTILS — Zustand und Validierung (→ Zeile 748)
#    validate_interface()       Existence + UP-State + IP-Adresse prüfen
#    get_interface_ip()         Primäre IPv4-Adresse eines Interface
#    get_interface_status()     Status-Zusammenfassung als Text
#    is_numeric()               Util: Integer/Float-Validierung (genutzt in allen Gruppen)
#
# ============================================================================

# ============================================================================
# BASIC CONNECTIVITY TESTS
# ============================================================================

# Test basic connectivity to target IPs
test_connectivity() {
    local interface="$1"
    local target_ips=("${CHECK_IPS[@]:-${DEFAULT_CHECK_IPS[@]}}")
    local success_count=0
    local total_tests=${#target_ips[@]}

    log "DEBUG" "Testing connectivity on $interface to ${total_tests} targets"

    for target in "${target_ips[@]}"; do
        if test_ping_target "$interface" "$target"; then
            ((success_count++)) || true
        fi
    done

    # Calculate success percentage
    local success_rate=0
    if [[ $total_tests -gt 0 ]]; then
        success_rate=$((success_count * 100 / total_tests))
    fi
    log "DEBUG" "Connectivity test: $success_count/$total_tests successful ($success_rate%)"

    echo "$success_rate"
}

# Test ping to a specific target
# v4.7.1 (11.04.2026): 3-packet burst to tolerate transient ICMP drops.
# Returns success if at least 1 of 3 packets is received (ping -c 3 exits 0
# unless all packets lost). Max duration: (3-1)*0.2 + 1 = 1.4s per call,
# timeout wrapper 3s. 4 targets serial ≈ 1.7s typical / 12s worst case
# (fits 15s CHECK_INTERVAL). Mitigates early-morning DSL line-sync false
# positives where a single dropped ICMP triggered failover.
test_ping_target() {
    local interface="$1"
    local target="$2"

    if timeout "$PING_TIMEOUT" ping -c 3 -W 1 -i 0.2 -I "$interface" "$target" &>/dev/null; then
        log "DEBUG" "Ping successful: $interface -> $target"
        return 0
    else
        log "DEBUG" "Ping failed: $interface -> $target"
        return 1
    fi
}

# ============================================================================
# DNS FUNCTIONALITY TESTS
# ============================================================================

# Test DNS resolution capabilities with interface binding
test_dns() {
    local interface="$1"
    local dns_servers=("${DNS_SERVERS[@]:-${DEFAULT_DNS_SERVERS[@]}}")
    local test_domains=("${DNS_TEST_DOMAINS[@]:-${DEFAULT_DNS_TEST_DOMAINS[@]}}")

    log "DEBUG" "Testing DNS resolution on $interface"

    # Test each DNS server with interface binding
    for dns_server in "${dns_servers[@]}"; do
        if test_dns_server "$dns_server" "${test_domains[0]}" "$interface"; then
            log "DEBUG" "DNS test successful using server: $dns_server via $interface"
            echo "100"
            return 0
        fi
    done

    log "DEBUG" "All DNS tests failed on $interface"
    echo "0"
    return 1
}

# Test specific DNS server with interface binding (DoH-based)
# The previous nslookup fallback was a false-positive trap: it ignored the
# interface argument and answered via the active default route, so the backup
# interface always appeared "DNS-OK" even when source-bound dig had timed out.
# Args: $1=dns_server (deprecated/ignored, kept for caller compatibility),
#       $2=test_domain, $3=interface (REQUIRED for binding)
test_dns_server() {
    local dns_server="$1"  # Retained for log compat; ignored by DoH path
    local test_domain="$2"
    local interface="${3:-}"

    if [[ -z "$interface" ]]; then
        log "DEBUG" "test_dns_server: no interface specified, cannot bind (legacy=$dns_server)"
        return 1
    fi

    local result
    result=$(measure_dns_doh "$interface" "$test_domain")
    if [[ "$result" != "999" ]]; then
        log "DEBUG" "DNS test successful: $interface (DoH) for $test_domain (legacy=$dns_server)"
        return 0
    fi

    log "DEBUG" "DNS test failed: $interface (DoH) for $test_domain (legacy=$dns_server)"
    return 1
}

# ============================================================================
# GATEWAY REACHABILITY TESTS
# ============================================================================

# Test gateway reachability
test_gateway() {
    local interface="$1"
    local gateway

    gateway=$(get_gateway "$interface")

    if [[ -z "$gateway" ]]; then
        log "WARNING" "No gateway found for interface $interface"
        echo "0"
        return 1
    fi

    log "DEBUG" "Testing gateway $gateway on $interface"

    if test_ping_target "$interface" "$gateway"; then
        log "DEBUG" "Gateway test successful: $gateway"
        echo "100"
        return 0
    else
        log "WARNING" "Gateway test failed: $gateway"
        echo "0"
        return 1
    fi
}

# Get gateway for interface
get_gateway() {
    local interface="$1"
    local gateway

    # Get default gateway for this interface
    gateway=$(ip route show dev "$interface" | grep default | awk '{print $3}' | head -1)

    if [[ -n "$gateway" ]]; then
        echo "$gateway"
    else
        log "DEBUG" "No gateway found for $interface"
        echo ""
    fi
}

# ============================================================================
# HTTP CONNECTIVITY TESTS
# ============================================================================

# Test HTTP connectivity
test_http_connectivity() {
    local interface="$1"
    local test_url="${2:-http://google.com}"

    log "DEBUG" "Testing HTTP connectivity on $interface to $test_url"

    if timeout $HTTP_TIMEOUT curl -s --interface "$interface" -m 3 "$test_url" &>/dev/null; then
        log "DEBUG" "HTTP test successful on $interface"
        echo "100"
        return 0
    else
        log "DEBUG" "HTTP test failed on $interface"
        echo "0"
        return 1
    fi
}

# ============================================================================
# SCORING ENTRY POINT
# ============================================================================

# Comprehensive network quality assessment
# NOTE: Delegates to calculate_weighted_score() — Wrapper für Backwards-Compat.
assess_network_quality() {
    local interface="$1"

    # Use new weighted scoring system with Prometheus integration
    calculate_weighted_score "$interface"
}

# ============================================================================
# WEIGHTED SCORING SYSTEM (Best Practices 2025)
# ============================================================================

# Calculate a network-focused weighted score from multiple link metrics.
# Returns: 0-100 score based on three weighted components.
#
# Weights: connectivity 40, latency 30, packet loss 30. DNS and HTTP are
# excluded from the routing-decision score because per-interface DNS/HTTP
# tests require policy-based routing on most stock distros, and a degraded
# upstream service should not affect an otherwise healthy link.
calculate_weighted_score() {
    local interface="$1"
    local total_score=0

    log "DEBUG" "Calculating weighted score for $interface (Network-fokussiert v3.2)"

    # Component 1: Connectivity (40% weight) - v3.2: increased from 30%
    # Tests: Ping to 4 public IPs (Google, Cloudflare, Quad9, OpenDNS)
    # Returns: 0-100 (percentage of successful pings)
    local ping_success_rate
    ping_success_rate=$(test_connectivity "$interface")
    local connectivity_component
    connectivity_component=$((ping_success_rate * 40 / 100))
    log "DEBUG" "  Connectivity: $ping_success_rate → Component: $connectivity_component/40"

    # Component 2: Latency (30% weight) - v3.2: increased from 25%
    # Source: Prometheus metrics OR live measurement
    # Scoring: <50ms=100, 50-100ms=75-100, 100-200ms=25-75, >200ms=0-25
    local latency_ms
    latency_ms=$(get_interface_latency "$interface")
    local latency_score
    latency_score=$(calculate_latency_score "$latency_ms")
    local latency_component
    latency_component=$((latency_score * 30 / 100))
    log "DEBUG" "  Latency: ${latency_ms}ms → Score: $latency_score → Component: $latency_component/30"

    # Component 3: Packet Loss (30% weight) - v3.2: increased from 20%
    # Source: Prometheus metrics OR live measurement
    # Scoring: 0%=100, <1%=90, 1-5%=60-90, 5-10%=30-60, >10%=0-30
    local packet_loss
    packet_loss=$(get_interface_packet_loss "$interface")
    local loss_score
    loss_score=$(calculate_loss_score "$packet_loss")
    local loss_component
    loss_component=$((loss_score * 30 / 100))
    log "DEBUG" "  Packet Loss: ${packet_loss}% → Score: $loss_score → Component: $loss_component/30"

    # DNS and HTTP removed from failover scoring (v3.2)
    # Rationale: These are Service-Level tests, not Network-Level
    # They are still monitored via wan_quality.prom but don't affect failover decisions
    # Note: DNS test via dig -b doesn't work correctly without Policy-Based-Routing

    # Calculate total weighted score (40 + 30 + 30 = 100)
    total_score=$((connectivity_component + latency_component + loss_component))

    log "INFO" "Weighted score for $interface: TOTAL=$total_score (conn:$connectivity_component/40, lat:$latency_component/30, loss:$loss_component/30)"

    echo "$total_score"
}

# ============================================================================
# UTILITY
# ============================================================================

# Check if value is numeric (integer or float)
# Used across all sections: scoring, measurements, Prometheus reads
is_numeric() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]
}

# ============================================================================
# COMPONENT SCORING FUNCTIONS
# ============================================================================

# Calculate latency-based score using config thresholds
# Input: Latency in milliseconds (float)
# Output: Score 0-100
# Thresholds from failover.conf:
#   LATENCY_GOOD=100ms (50 in new scale)
#   LATENCY_WARNING=200ms
#   LATENCY_CRITICAL=500ms
calculate_latency_score() {
    local latency_ms="$1"

    # Handle invalid/missing latency
    if [[ -z "$latency_ms" ]] || ! is_numeric "$latency_ms"; then
        log "WARNING" "Invalid latency value: '$latency_ms'"
        echo "0"
        return 1
    fi

    # Excellent: <50ms → Score 100
    if (( $(echo "$latency_ms < 50" | bc -l) )); then
        echo "100"
        return 0
    fi

    # Good: 50-100ms → Linear scale 75-100
    if (( $(echo "$latency_ms < ${LATENCY_GOOD:-100}" | bc -l) )); then
        local score
        score=$(echo "scale=0; 100 - (($latency_ms - 50) * 25 / 50)" | bc -l)
        echo "$score"
        return 0
    fi

    # Fair: 100-200ms → Linear scale 25-75
    if (( $(echo "$latency_ms < ${LATENCY_WARNING:-200}" | bc -l) )); then
        local score
        score=$(echo "scale=0; 75 - (($latency_ms - 100) * 50 / 100)" | bc -l)
        echo "$score"
        return 0
    fi

    # Poor: 200-500ms → Linear scale 0-25
    if (( $(echo "$latency_ms < ${LATENCY_CRITICAL:-500}" | bc -l) )); then
        local score
        score=$(echo "scale=0; 25 - (($latency_ms - 200) * 25 / 300)" | bc -l)
        [[ $score -lt 0 ]] && score=0
        echo "$score"
        return 0
    fi

    # Critical: >500ms → Score 0
    echo "0"
}

# Calculate packet loss-based score using config thresholds
# Input: Packet loss percentage (0-100)
# Output: Score 0-100
# Thresholds from failover.conf:
#   PACKET_LOSS_GOOD=5%
#   PACKET_LOSS_WARNING=10%
#   PACKET_LOSS_CRITICAL=20%
calculate_loss_score() {
    local packet_loss_percent="$1"

    # Handle invalid/missing packet loss
    if [[ -z "$packet_loss_percent" ]] || ! is_numeric "$packet_loss_percent"; then
        log "WARNING" "Invalid packet loss value: '$packet_loss_percent'"
        echo "0"
        return 1
    fi

    # Perfect: 0% loss → Score 100
    if (( $(echo "$packet_loss_percent == 0" | bc -l) )); then
        echo "100"
        return 0
    fi

    # Excellent: <1% loss → Score 90
    if (( $(echo "$packet_loss_percent < 1" | bc -l) )); then
        echo "90"
        return 0
    fi

    # Good: 1-5% → Linear scale 60-90
    if (( $(echo "$packet_loss_percent < ${PACKET_LOSS_GOOD:-5}" | bc -l) )); then
        local score
        score=$(echo "scale=0; 90 - (($packet_loss_percent - 1) * 30 / 4)" | bc -l)
        echo "$score"
        return 0
    fi

    # Fair: 5-10% → Linear scale 30-60
    if (( $(echo "$packet_loss_percent < ${PACKET_LOSS_WARNING:-10}" | bc -l) )); then
        local score
        score=$(echo "scale=0; 60 - (($packet_loss_percent - 5) * 30 / 5)" | bc -l)
        echo "$score"
        return 0
    fi

    # Poor: 10-20% → Linear scale 0-30
    if (( $(echo "$packet_loss_percent < ${PACKET_LOSS_CRITICAL:-20}" | bc -l) )); then
        local score
        score=$(echo "scale=0; 30 - (($packet_loss_percent - 10) * 30 / 10)" | bc -l)
        [[ $score -lt 0 ]] && score=0
        echo "$score"
        return 0
    fi

    # Critical: >20% loss → Score 0
    echo "0"
}

# Calculate DNS resolution time-based score
# Input: DNS time in milliseconds
# Output: Score 0-100
# Note: 999ms indicates failed DNS (from wan-quality-monitor.sh)
calculate_dns_score() {
    local dns_time_ms="$1"

    # Handle invalid/missing DNS time
    if [[ -z "$dns_time_ms" ]] || ! is_numeric "$dns_time_ms"; then
        log "WARNING" "Invalid DNS time value: '$dns_time_ms'"
        echo "0"
        return 1
    fi

    # Failed: 999ms indicates DNS failure
    if (( $(echo "$dns_time_ms >= 999" | bc -l) )); then
        echo "0"
        return 1
    fi

    # Excellent: <100ms → Score 100
    if (( $(echo "$dns_time_ms < 100" | bc -l) )); then
        echo "100"
        return 0
    fi

    # Good: 100-300ms → Linear scale 70-100
    if (( $(echo "$dns_time_ms < 300" | bc -l) )); then
        local score
        score=$(echo "scale=0; 100 - (($dns_time_ms - 100) * 30 / 200)" | bc -l)
        echo "$score"
        return 0
    fi

    # Fair: 300-500ms → Linear scale 40-70
    if (( $(echo "$dns_time_ms < 500" | bc -l) )); then
        local score
        score=$(echo "scale=0; 70 - (($dns_time_ms - 300) * 30 / 200)" | bc -l)
        echo "$score"
        return 0
    fi

    # Poor: >500ms → Linear scale 0-40
    local score
    score=$(echo "scale=0; 40 - (($dns_time_ms - 500) * 40 / 500)" | bc -l)
    [[ $score -lt 0 ]] && score=0
    echo "$score"
}

# Calculate HTTP connection time-based score
# Input: HTTP time in milliseconds
# Output: Score 0-100
# Note: 999ms indicates failed HTTP (from wan-quality-monitor.sh)
calculate_http_score() {
    local http_time_ms="$1"

    # Handle invalid/missing HTTP time
    if [[ -z "$http_time_ms" ]] || ! is_numeric "$http_time_ms"; then
        log "WARNING" "Invalid HTTP time value: '$http_time_ms'"
        echo "0"
        return 1
    fi

    # Failed: 999ms indicates HTTP failure
    if (( $(echo "$http_time_ms >= 999" | bc -l) )); then
        echo "0"
        return 1
    fi

    # Excellent: <200ms → Score 100
    if (( $(echo "$http_time_ms < 200" | bc -l) )); then
        echo "100"
        return 0
    fi

    # Good: 200-500ms → Linear scale 70-100
    if (( $(echo "$http_time_ms < 500" | bc -l) )); then
        local score
        score=$(echo "scale=0; 100 - (($http_time_ms - 200) * 30 / 300)" | bc -l)
        echo "$score"
        return 0
    fi

    # Fair: >500ms → Linear scale 0-70
    local score
    score=$(echo "scale=0; 70 - (($http_time_ms - 500) * 70 / 500)" | bc -l)
    [[ $score -lt 0 ]] && score=0
    echo "$score"
}

# Compare two interfaces and return the better one
compare_interfaces() {
    local interface1="$1"
    local interface2="$2"

    log "INFO" "Comparing interfaces: $interface1 vs $interface2"

    local score1
    local score2

    score1=$(assess_network_quality "$interface1")
    score2=$(assess_network_quality "$interface2")

    log "INFO" "Interface comparison: $interface1 (${score1}%) vs $interface2 (${score2}%)"

    if [[ $score1 -gt $score2 ]]; then
        echo "$interface1"
        return 0
    elif [[ $score2 -gt $score1 ]]; then
        echo "$interface2"
        return 0
    else
        echo "tie"
        return 2
    fi
}

# ============================================================================
# MEASUREMENTS — Basis (Latency, Packet Loss)
# ============================================================================

# Measure network latency
measure_latency() {
    local interface="$1"
    local target="${2:-8.8.8.8}"
    local samples="${3:-3}"

    local latency_sum=0
    local successful_pings=0

    for ((i=1; i<=samples; i++)); do
        local ping_result
        ping_result=$(timeout $PING_TIMEOUT ping -c 1 -W 1 -I "$interface" "$target" 2>/dev/null | grep 'time=' | cut -d'=' -f4 | cut -d' ' -f1)

        if [[ -n "$ping_result" ]] && is_numeric "$ping_result"; then
            latency_sum=$(echo "$latency_sum + $ping_result" | bc -l)
            ((successful_pings++)) || true
        fi
    done

    if [[ $successful_pings -gt 0 ]]; then
        local avg_latency
        avg_latency=$(echo "scale=2; $latency_sum / $successful_pings" | bc -l)
        echo "$avg_latency"
    else
        echo "999.99"  # High latency indicates failure
    fi
}

# Measure packet loss percentage
measure_packet_loss() {
    local interface="$1"
    local target="${2:-8.8.8.8}"
    local count="${3:-10}"

    local ping_output
    ping_output=$(timeout $((PING_TIMEOUT * count)) ping -c "$count" -W 1 -I "$interface" "$target" 2>/dev/null)

    if [[ -n "$ping_output" ]]; then
        local packet_loss
        packet_loss=$(grep 'packet loss' <<< "$ping_output" | awk '{print $6}' | cut -d'%' -f1)

        if is_numeric "$packet_loss"; then
            echo "$packet_loss"
        else
            echo "100"  # Assume 100% loss if we can't parse
        fi
    else
        echo "100"
    fi
}

# ============================================================================
# PROMETHEUS INTEGRATION — Metriken lesen, Live-Messung als Fallback
# ============================================================================

# Get interface latency from Prometheus metrics with fallback to live measurement
# Reads: wan_latency_milliseconds{interface="eth0"}
# Fallback: measure_latency() if metric unavailable
get_interface_latency() {
    local interface="$1"
    local prom_file="/var/lib/node_exporter/textfile_collector/wan_quality.prom"

    # Try to read from Prometheus metrics first
    if [[ -f "$prom_file" ]]; then
        local latency
        latency=$(grep "wan_latency_milliseconds{interface=\"$interface\"" "$prom_file" | awk '{print $2}')

        if [[ -n "$latency" ]] && is_numeric "$latency"; then
            log "DEBUG" "Latency for $interface from Prometheus: ${latency}ms"
            echo "$latency"
            return 0
        else
            log "DEBUG" "No valid Prometheus latency for $interface, using live measurement"
        fi
    else
        log "DEBUG" "Prometheus metrics file not found, using live measurement"
    fi

    # Fallback to live measurement
    measure_latency "$interface"
}

# Get interface packet loss from Prometheus metrics with fallback
# Reads: wan_packet_loss_percent{interface="eth0"}
# Fallback: measure_packet_loss() if metric unavailable
get_interface_packet_loss() {
    local interface="$1"
    local prom_file="/var/lib/node_exporter/textfile_collector/wan_quality.prom"

    # Try to read from Prometheus metrics first
    if [[ -f "$prom_file" ]]; then
        local packet_loss
        packet_loss=$(grep "wan_packet_loss_percent{interface=\"$interface\"" "$prom_file" | awk '{print $2}')

        if [[ -n "$packet_loss" ]] && is_numeric "$packet_loss"; then
            log "DEBUG" "Packet loss for $interface from Prometheus: ${packet_loss}%"
            echo "$packet_loss"
            return 0
        else
            log "DEBUG" "No valid Prometheus packet loss for $interface, using live measurement"
        fi
    else
        log "DEBUG" "Prometheus metrics file not found, using live measurement"
    fi

    # Fallback to live measurement
    measure_packet_loss "$interface"
}

# Get interface DNS time from Prometheus metrics with fallback
# Reads: wan_dns_time_milliseconds{interface="eth0"}
# Fallback: test_dns() if metric unavailable
get_interface_dns_time() {
    local interface="$1"
    local prom_file="/var/lib/node_exporter/textfile_collector/wan_quality.prom"

    # Try to read from Prometheus metrics first
    if [[ -f "$prom_file" ]]; then
        local dns_time
        dns_time=$(grep "wan_dns_time_milliseconds{interface=\"$interface\"" "$prom_file" | awk '{print $2}')

        if [[ -n "$dns_time" ]] && is_numeric "$dns_time"; then
            log "DEBUG" "DNS time for $interface from Prometheus: ${dns_time}ms"
            echo "$dns_time"
            return 0
        else
            log "DEBUG" "No valid Prometheus DNS time for $interface, using live measurement"
        fi
    else
        log "DEBUG" "Prometheus metrics file not found, using live measurement"
    fi

    # Fallback to live DNS test
    # Note: test_dns() returns 0 or 100, not milliseconds
    # Need to measure DNS time if Prometheus unavailable
    local dns_test_result
    dns_test_result=$(test_dns "$interface")
    if [[ "$dns_test_result" -eq 100 ]]; then
        echo "150"  # Assume reasonable time if successful
    else
        echo "999"  # Failed DNS
    fi
}

# Get interface HTTP time from Prometheus metrics with fallback
# Reads: wan_http_time_milliseconds{interface="eth0"}
# Fallback: test_http_connectivity() if metric unavailable
get_interface_http_time() {
    local interface="$1"
    local prom_file="/var/lib/node_exporter/textfile_collector/wan_quality.prom"

    # Try to read from Prometheus metrics first
    if [[ -f "$prom_file" ]]; then
        local http_time
        http_time=$(grep "wan_http_time_milliseconds{interface=\"$interface\"" "$prom_file" | awk '{print $2}')

        if [[ -n "$http_time" ]] && is_numeric "$http_time"; then
            log "DEBUG" "HTTP time for $interface from Prometheus: ${http_time}ms"
            echo "$http_time"
            return 0
        else
            log "DEBUG" "No valid Prometheus HTTP time for $interface, using live measurement"
        fi
    else
        log "DEBUG" "Prometheus metrics file not found, using live measurement"
    fi

    # Fallback to live HTTP test
    # Note: test_http_connectivity() returns 0 or 100, not milliseconds
    local http_test_result
    http_test_result=$(test_http_connectivity "$interface")
    if [[ "$http_test_result" -eq 100 ]]; then
        echo "250"  # Assume reasonable time if successful
    else
        echo "999"  # Failed HTTP
    fi
}

# ============================================================================
# MEASUREMENTS — Timed DNS/HTTP (Fallback for Prometheus)
# ============================================================================

# DoH (DNS-over-HTTPS) helper — real interface binding via curl --interface
# (SO_BINDTODEVICE) instead of dig -b (which only sets the source IP and is
# defeated by destination-based routing on a demoted backup interface).
#
# Args:    $1 = interface (eth0, lte0, ...)
#          $2 = test_domain (default: google.com)
# Echo:    integer DNS latency in ms, or 999 on failure
# Endpoints (each with --resolve bootstrap to bypass system-resolver dependency):
#   1. https://dns.google/resolve            (8.8.8.8, 8.8.4.4)
#   2. https://cloudflare-dns.com/dns-query  (1.1.1.1, 1.0.0.1)
# Validation: HTTP 200 + jq '.Status == 0' (NOERROR per RFC 8484/Google JSON-API)
#             + .Answer length >= 1 (filters captive-portal false positives).
# Feature flag: DNS_TEST_METHOD=dig falls back to _measure_dns_dig_legacy().
#
# Background: dig -b only sets the source IP — packets still follow the kernel's
# destination-based routing. When the primary interface is demoted (higher
# metric), DNS packets exit via the active backup with the primary's source IP
# → asymmetric routing → ISP filters or response cannot return → timeout (999).
# curl --interface uses SO_BINDTODEVICE, which forces the actual outgoing
# interface, so responses come back symmetrically.
measure_dns_doh() {
    local interface="$1"
    local test_domain="${2:-google.com}"
    local timeout="${DNS_TIMEOUT:-3}"

    # Soft rollback: DNS_TEST_METHOD=dig switches to legacy path
    if [[ "${DNS_TEST_METHOD:-doh}" == "dig" ]]; then
        _measure_dns_dig_legacy "$interface" "$test_domain"
        return $?
    fi

    # Defensive: both tools should be present on any sane Linux router
    if ! command -v curl >/dev/null 2>&1; then
        log "ERROR" "curl not found, cannot perform DoH test for $interface" >&2
        echo "999"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "ERROR" "jq not found, cannot validate DoH response for $interface" >&2
        echo "999"
        return 1
    fi

    # Endpoint list: host|path|bootstrap_ips_csv
    local endpoints=(
        "dns.google|/resolve|8.8.8.8,8.8.4.4"
        "cloudflare-dns.com|/dns-query|1.1.1.1,1.0.0.1"
    )

    local endpoint host path bootstrap
    for endpoint in "${endpoints[@]}"; do
        IFS='|' read -r host path bootstrap <<< "$endpoint"

        # One --resolve arg per bootstrap IP (belt & suspenders)
        local resolve_args=()
        local ip
        for ip in ${bootstrap//,/ }; do
            resolve_args+=("--resolve" "${host}:443:${ip}")
        done

        local url="https://${host}${path}?name=${test_domain}&type=A"
        local response
        response=$(timeout "$timeout" curl --silent --fail \
            --interface "$interface" \
            --max-time "$timeout" \
            --connect-timeout 2 \
            "${resolve_args[@]}" \
            -H 'Accept: application/dns-json' \
            -w '\nTIME_TOTAL=%{time_total}\n' \
            "$url" 2>/dev/null) || {
            log "DEBUG" "DoH curl failed: $interface -> $host (trying next endpoint)" >&2
            continue
        }

        local time_total body
        time_total=$(printf '%s\n' "$response" | awk -F= '/^TIME_TOTAL=/{print $2}' | tail -1)
        body=$(printf '%s\n' "$response" | sed '/^TIME_TOTAL=/d')

        # JSON validation: Status==0 (NOERROR) and Answer array non-empty
        local status answer_count
        status=$(printf '%s' "$body" | jq -r '.Status // -1' 2>/dev/null)
        answer_count=$(printf '%s' "$body" | jq -r '.Answer | length' 2>/dev/null)

        if [[ "$status" != "0" ]] || [[ -z "$answer_count" ]] || ! [[ "$answer_count" =~ ^[0-9]+$ ]] || [[ "$answer_count" -lt 1 ]]; then
            log "DEBUG" "DoH validation failed: $interface -> $host (Status=$status, Answers=$answer_count)" >&2
            continue
        fi

        # Convert seconds (e.g. 0.085) to integer ms via awk (no bc dependency)
        local duration_ms
        duration_ms=$(awk -v t="$time_total" 'BEGIN { printf "%d", t * 1000 }')

        log "DEBUG" "DoH success: $interface -> $host = ${duration_ms}ms" >&2
        echo "$duration_ms"
        return 0
    done

    log "DEBUG" "DoH failed on all endpoints for $interface" >&2
    echo "999"
    return 1
}

# Legacy dig -b DNS test (DEPRECATED, rollback path only via DNS_TEST_METHOD=dig).
# WARNING: subject to asymmetric-routing bug on demoted backup interfaces.
_measure_dns_dig_legacy() {
    local interface="$1"
    local test_domain="${2:-google.com}"
    local dns_server="${3:-8.8.8.8}"

    local bind_ip
    bind_ip=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

    if [[ -z "$bind_ip" ]]; then
        echo "999"
        return 1
    fi

    local start_ms
    start_ms=$(date +%s%3N)

    if timeout "${DNS_TIMEOUT:-3}" dig @"$dns_server" "$test_domain" +short -b "$bind_ip" &>/dev/null; then
        local end_ms duration_ms
        end_ms=$(date +%s%3N)
        duration_ms=$((end_ms - start_ms))
        echo "$duration_ms"
        return 0
    fi

    echo "999"
    return 1
}

# Measure DNS resolution time in milliseconds (DoH-based)
# Args: $1=interface, $2=dns_server (deprecated/ignored), $3=test_domain
# Returns: Time in ms, or 999 for failure
measure_dns_time() {
    local interface="$1"
    # $2 (dns_server) deprecated — DoH endpoints are configured in measure_dns_doh
    local test_domain="${3:-google.com}"

    measure_dns_doh "$interface" "$test_domain"
}

# Measure HTTP connection time in milliseconds
# Returns: Time in ms, or 999 for failure
measure_http_time() {
    local interface="$1"
    local test_url="${2:-http://google.com}"

    # Time the HTTP request
    local start_ms
    start_ms=$(date +%s%3N)

    if timeout ${HTTP_TIMEOUT:-3} curl -s --interface "$interface" -m 3 "$test_url" &>/dev/null; then
        local end_ms
        end_ms=$(date +%s%3N)
        local duration_ms
        duration_ms=$((end_ms - start_ms))

        log "DEBUG" "HTTP connection time for $interface: ${duration_ms}ms"
        echo "$duration_ms"
        return 0
    else
        log "DEBUG" "HTTP connection failed for $interface"
        echo "999"
        return 1
    fi
}

# ============================================================================
# INTERFACE STATUS AND VALIDATION
# ============================================================================

# Check if interface exists and is configured
validate_interface() {
    local interface="$1"

    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        log "ERROR" "Interface $interface does not exist"
        return 1
    fi

    # Check if interface is up
    if ! ip link show "$interface" | grep -q "state UP"; then
        log "WARNING" "Interface $interface is not UP"
        return 2
    fi

    # Check if interface has an IP address
    if ! ip addr show "$interface" | grep -q 'inet '; then
        log "WARNING" "Interface $interface has no IP address"
        return 3
    fi

    log "DEBUG" "Interface $interface validation passed"
    return 0
}

# Get interface IP address
get_interface_ip() {
    local interface="$1"

    ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1
}

# Get interface status summary
get_interface_status() {
    local interface="$1"
    local ip_addr
    local gateway
    local status

    ip_addr=$(get_interface_ip "$interface")
    gateway=$(get_gateway "$interface")

    if validate_interface "$interface"; then
        status="UP"
    else
        status="DOWN"
    fi

    echo "Interface: $interface, Status: $status, IP: ${ip_addr:-none}, Gateway: ${gateway:-none}"
}

# ============================================================================
# MEASUREMENTS — WAN Quality (Jitter, DNS-Perf, HTTP-Perf, Bandwidth)
# ============================================================================

# Measure jitter (latency variability / standard deviation)
measure_jitter() {
    local interface="$1"
    local target="${2:-8.8.8.8}"
    local samples="${3:-10}"

    local latencies=()
    local sum=0
    local count=0

    # Collect latency samples
    for ((i=1; i<=samples; i++)); do
        local ping_result
        ping_result=$(timeout $PING_TIMEOUT ping -c 1 -W 1 -I "$interface" "$target" 2>/dev/null | grep 'time=' | cut -d'=' -f4 | cut -d' ' -f1)

        if [[ -n "$ping_result" ]] && is_numeric "$ping_result"; then
            latencies+=("$ping_result")
            sum=$(echo "$sum + $ping_result" | bc -l)
            ((count++)) || true
        fi
    done

    # Need at least 2 samples for jitter calculation
    if [[ $count -lt 2 ]]; then
        echo "999.99"  # High jitter indicates failure
        return 1
    fi

    # Calculate mean
    local mean
    mean=$(echo "scale=2; $sum / $count" | bc -l)

    # Calculate variance and standard deviation (jitter)
    local variance_sum=0
    for latency in "${latencies[@]}"; do
        local diff
        diff=$(echo "$latency - $mean" | bc -l)
        local squared
        squared=$(echo "$diff * $diff" | bc -l)
        variance_sum=$(echo "$variance_sum + $squared" | bc -l)
    done

    local variance
    variance=$(echo "scale=2; $variance_sum / $count" | bc -l)
    local jitter
    jitter=$(echo "scale=2; sqrt($variance)" | bc -l)

    echo "$jitter"
}

# Measure DNS resolution performance (time in milliseconds, DoH-based)
# Args: $1=interface, $2=dns_server (deprecated/ignored), $3=test_domain
measure_dns_performance() {
    local interface="$1"
    # $2 (dns_server) deprecated — DoH endpoints in measure_dns_doh
    local test_domain="${3:-google.com}"

    measure_dns_doh "$interface" "$test_domain"
}

# Measure HTTP connectivity performance (time in milliseconds)
measure_http_performance() {
    local interface="$1"
    local test_url="${2:-http://connectivitycheck.gstatic.com/generate_204}"

    # Measure HTTP response time with curl
    local start_ms
    start_ms=$(date +%s%3N)

    local http_code
    http_code=$(timeout $HTTP_TIMEOUT curl -s -o /dev/null -w "%{http_code}" \
                --interface "$interface" -m 3 "$test_url" 2>/dev/null)

    local end_ms
    end_ms=$(date +%s%3N)

    # Check for successful response (200-399)
    if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
        local http_time
        http_time=$((end_ms - start_ms))
        echo "$http_time"
        return 0
    else
        echo "999"  # Failed
        return 1
    fi
}

# Comprehensive WAN quality assessment with detailed metrics
# Returns JSON-like output for easy parsing
test_wan_quality() {
    local interface="$1"
    local gateway
    gateway=$(get_gateway "$interface")

    if [[ -z "$gateway" ]]; then
        log "WARNING" "No gateway for $interface - cannot test WAN quality"
        # Return minimal JSON structure
        cat << EOF
{
  "interface": "$interface",
  "latency_ms": 999.99,
  "packet_loss_pct": 100,
  "jitter_ms": 999.99,
  "dns_time_ms": 999,
  "http_time_ms": 999,
  "overall_score": 0,
  "timestamp": $(date +%s)
}
EOF
        return 1
    fi

    log "DEBUG" "Testing WAN quality for $interface (gateway: $gateway)"

    # Measure all quality metrics
    local latency
    latency=$(measure_latency "$interface" "$gateway" 5)
    local packet_loss
    packet_loss=$(measure_packet_loss "$interface" "$gateway" 10)
    local jitter
    jitter=$(measure_jitter "$interface" "$gateway" 10)
    local dns_time
    dns_time=$(measure_dns_performance "$interface" "8.8.8.8" "google.com")
    local http_time
    http_time=$(measure_http_performance "$interface" "http://connectivitycheck.gstatic.com/generate_204")

    # Calculate overall quality score (0-100)
    # Latency: 100 points if <50ms, 0 if >200ms, linear between
    local latency_score=0
    if is_numeric "$latency" && (( $(echo "$latency < 200" | bc -l) )); then
        if (( $(echo "$latency < 50" | bc -l) )); then
            latency_score=100
        else
            latency_score=$(echo "scale=0; 100 - (($latency - 50) * 100 / 150)" | bc -l)
        fi
    fi

    # Packet Loss: 100 - loss_percentage
    local loss_score=0
    if is_numeric "$packet_loss"; then
        loss_score=$(echo "scale=0; 100 - $packet_loss" | bc -l)
    fi

    # Jitter: 100 points if <10ms, 0 if >50ms, linear between
    local jitter_score=0
    if is_numeric "$jitter" && (( $(echo "$jitter < 50" | bc -l) )); then
        if (( $(echo "$jitter < 10" | bc -l) )); then
            jitter_score=100
        else
            jitter_score=$(echo "scale=0; 100 - (($jitter - 10) * 100 / 40)" | bc -l)
        fi
    fi

    # DNS: 100 points if <50ms, 0 if >500ms
    local dns_score=0
    if [[ "$dns_time" -lt 500 ]]; then
        if [[ "$dns_time" -lt 50 ]]; then
            dns_score=100
        else
            dns_score=$(echo "scale=0; 100 - (($dns_time - 50) * 100 / 450)" | bc -l)
        fi
    fi

    # HTTP: 100 points if <200ms, 0 if >1000ms
    local http_score=0
    if [[ "$http_time" -lt 1000 ]]; then
        if [[ "$http_time" -lt 200 ]]; then
            http_score=100
        else
            http_score=$(echo "scale=0; 100 - (($http_time - 200) * 100 / 800)" | bc -l)
        fi
    fi

    # Weighted overall score
    # Latency: 25%, Loss: 25%, Jitter: 15%, DNS: 20%, HTTP: 15%
    local overall_score
    overall_score=$(echo "scale=0; ($latency_score * 25 + $loss_score * 25 + $jitter_score * 15 + $dns_score * 20 + $http_score * 15) / 100" | bc -l)

    log "INFO" "WAN quality for $interface: latency=${latency}ms, loss=${packet_loss}%, jitter=${jitter}ms, dns=${dns_time}ms, http=${http_time}ms, score=${overall_score}"

    # Ensure numeric values are properly formatted for JSON (no leading dots)
    # bc sometimes returns ".14" instead of "0.14" which is invalid JSON
    [[ "$latency" == .* ]] && latency="0$latency"
    [[ "$jitter" == .* ]] && jitter="0$jitter"

    # Return JSON structure for easy parsing by Python
    cat << EOF
{
  "interface": "$interface",
  "latency_ms": $latency,
  "packet_loss_pct": $packet_loss,
  "jitter_ms": $jitter,
  "dns_time_ms": $dns_time,
  "http_time_ms": $http_time,
  "overall_score": $overall_score,
  "timestamp": $(date +%s)
}
EOF
}

# Simple bandwidth test using curl
test_bandwidth() {
    local interface="$1"
    local test_url="${2:-http://speedtest.tele2.net/1MB.zip}"
    local timeout="${3:-10}"

    log "DEBUG" "Testing bandwidth on $interface"

    local start_time
    start_time=$(get_timestamp)
    local bytes_downloaded

    bytes_downloaded=$(timeout "$timeout" curl -s --interface "$interface" -m "$timeout" "$test_url" | wc -c 2>/dev/null || echo "0")

    local end_time
    end_time=$(get_timestamp)
    local duration
    duration=$((end_time - start_time))

    if [[ $duration -gt 0 ]] && [[ $bytes_downloaded -gt 0 ]]; then
        local kbps
        kbps=$((bytes_downloaded / duration / 1024))
        echo "$kbps"
    else
        echo "0"
    fi
}

# ============================================================================
# MEASUREMENTS — DNS Detailed (Multi-Resolver Analyse)
# ============================================================================

# Measure detailed DNS performance metrics across multiple resolvers (DoH-based)
# Returns JSON with success rates, failure categorization, resolver comparison.
# Note: ISP-resolver removed (does not speak DoH); SQLite ISP column will be NULL
# for new rows. The resolver labels remain "8.8.8.8"/"1.1.1.1" for schema
# continuity, even though internally measure_dns_doh contacts dns.google /
# cloudflare-dns.com.
measure_dns_detailed() {
    local interface="$1"
    local domain="${2:-google.com}"
    local resolvers=("8.8.8.8" "1.1.1.1")

    local interface_ip
    interface_ip=$(get_interface_ip "$interface")

    if [[ -z "$interface_ip" ]]; then
        echo "{\"error\":\"No IP found for interface $interface\"}"
        return 1
    fi

    local total_queries=0
    local successful_queries=0
    local timeouts=0
    local servfails=0

    local resolver_results=()

    local resolver
    for resolver in "${resolvers[@]}"; do
        local resolver_time=0
        local resolver_successes=0
        local samples=2

        local i
        for ((i=1; i<=samples; i++)); do
            ((total_queries++)) || true

            local query_time
            query_time=$(measure_dns_doh "$interface" "$domain")

            if [[ "$query_time" != "999" ]]; then
                ((successful_queries++)) || true
                ((resolver_successes++)) || true
                resolver_time=$((resolver_time + query_time))
            else
                ((timeouts++)) || true
            fi
        done

        local avg_time=999
        if [[ $resolver_successes -gt 0 ]]; then
            avg_time=$((resolver_time / resolver_successes))
        fi

        resolver_results+=("{\"resolver\":\"$resolver\",\"avg_time_ms\":$avg_time,\"success_rate\":$((resolver_successes * 100 / samples))}")
    done

    # Calculate overall success rate
    local success_rate=0
    if [[ $total_queries -gt 0 ]]; then
        success_rate=$((successful_queries * 100 / total_queries))
    fi

    # Calculate DNS quality score (0-100)
    local dns_score=0
    if [[ $success_rate -ge 95 ]]; then
        dns_score=100
    elif [[ $success_rate -ge 90 ]]; then
        dns_score=80
    elif [[ $success_rate -ge 80 ]]; then
        dns_score=60
    elif [[ $success_rate -ge 70 ]]; then
        dns_score=40
    else
        dns_score=20
    fi

    # Output JSON
    cat << EOF
{
  "interface": "$interface",
  "success_rate_pct": $success_rate,
  "total_queries": $total_queries,
  "successful_queries": $successful_queries,
  "timeouts": $timeouts,
  "servfails": $servfails,
  "dns_quality_score": $dns_score,
  "resolvers": [$(IFS=,; echo "${resolver_results[*]}")]
}
EOF
}

# Export functions for use by main script
export -f test_connectivity test_dns test_gateway test_http_connectivity
export -f assess_network_quality validate_interface get_interface_status
export -f measure_latency measure_packet_loss compare_interfaces
export -f get_gateway get_interface_ip test_bandwidth
export -f measure_jitter measure_dns_performance measure_http_performance test_wan_quality
export -f measure_dns_detailed measure_dns_doh
