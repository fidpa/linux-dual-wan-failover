#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Tests for WAN path measurement in network.sh.
#
# Regression guard: latency, packet loss and jitter must describe the internet
# path, not the next LAN hop. Measuring against the gateway makes a backup link
# look healthy (a LAN cable is always ~1ms) right up to the moment it is
# promoted to active WAN.

load '../helpers'

setup() {
    setup_test_env

    # Per-test ping stub, ahead of tests/mocks on PATH. A PATH stub is required
    # rather than a bash function: measure_path_quality() runs `timeout ping`,
    # and timeout execs the real binary, bypassing any exported function.
    export STUB_BIN="${TMPROOT}/stub-bin"
    mkdir -p "$STUB_BIN"
    export PATH="${STUB_BIN}:${PATH}"

    # shellcheck source=/dev/null
    source "${SRC_DIR}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${SRC_DIR}/lib/network.sh"
}

teardown() {
    teardown_test_env
}

# ============================================================================
# Stub helpers
# ============================================================================

_stub_ping_healthy() {
    cat > "${STUB_BIN}/ping" << 'STUB'
#!/bin/bash
echo "PING target: 56 data bytes"
echo "10 packets transmitted, 10 received, 0% packet loss, time 1807ms"
echo "rtt min/avg/max/mdev = 54.003/70.695/121.369/18.404 ms"
exit 0
STUB
    chmod +x "${STUB_BIN}/ping"
}

# Total loss: statistics line present, rtt summary absent (real ping behaviour)
_stub_ping_total_loss() {
    cat > "${STUB_BIN}/ping" << 'STUB'
#!/bin/bash
echo "PING target: 56 data bytes"
echo "10 packets transmitted, 0 received, 100% packet loss, time 9200ms"
exit 1
STUB
    chmod +x "${STUB_BIN}/ping"
}

_stub_ping_silent() {
    printf '#!/bin/bash\nexit 2\n' > "${STUB_BIN}/ping"
    chmod +x "${STUB_BIN}/ping"
}

# Only the given target answers; every other target fails
_stub_ping_only() {
    local good_target="$1"
    cat > "${STUB_BIN}/ping" << STUB
#!/bin/bash
target="\${@: -1}"
if [[ "\$target" == "${good_target}" ]]; then
    echo "10 packets transmitted, 10 received, 0% packet loss, time 1807ms"
    echo "rtt min/avg/max/mdev = 10.000/20.000/30.000/2.500 ms"
    exit 0
fi
echo "10 packets transmitted, 0 received, 100% packet loss, time 9200ms"
exit 1
STUB
    chmod +x "${STUB_BIN}/ping"
}

# Gateway answers fast, internet target slow — lets a test tell them apart
_stub_ping_split() {
    cat > "${STUB_BIN}/ping" << 'STUB'
#!/bin/bash
target="${@: -1}"
if [[ "$target" == "198.51.100.1" ]]; then
    echo "3 packets transmitted, 3 received, 0% packet loss, time 400ms"
    echo "rtt min/avg/max/mdev = 1.100/1.300/1.500/0.100 ms"
else
    echo "10 packets transmitted, 10 received, 0% packet loss, time 1807ms"
    echo "rtt min/avg/max/mdev = 40.000/58.465/90.000/9.014 ms"
fi
exit 0
STUB
    chmod +x "${STUB_BIN}/ping"
}

# ============================================================================
# measure_path_quality
# ============================================================================

@test "measure_path_quality: parses avg, loss and mdev from one ping series" {
    _stub_ping_healthy

    run measure_path_quality "lte0" "8.8.8.8" 10

    [ "$status" -eq 0 ]
    [ "$output" = "70.695|0|18.404" ]
}

@test "measure_path_quality: reports mdev as jitter, not min or max" {
    _stub_ping_healthy

    run measure_path_quality "lte0" "8.8.8.8" 10

    [ "${output##*|}" = "18.404" ]
}

@test "measure_path_quality: keeps loss when the rtt summary is absent" {
    _stub_ping_total_loss

    run measure_path_quality "lte0" "8.8.8.8" 10

    [ "$status" -eq 1 ]
    [ "$output" = "999.99|100|999.99" ]
}

@test "measure_path_quality: returns sentinels on empty ping output" {
    _stub_ping_silent

    run measure_path_quality "lte0" "8.8.8.8" 10

    [ "$status" -eq 1 ]
    [ "$output" = "999.99|100|999.99" ]
}

# ============================================================================
# _pick_probe_target
# ============================================================================

@test "_pick_probe_target: skips a dead target and takes the next" {
    CHECK_IPS=("192.0.2.1" "1.1.1.1" "9.9.9.9")
    _stub_ping_only "1.1.1.1"

    run _pick_probe_target "lte0"

    [ "$status" -eq 0 ]
    [ "$output" = "1.1.1.1" ]
}

@test "_pick_probe_target: fails with empty output when nothing answers" {
    CHECK_IPS=("192.0.2.1" "192.0.2.2")
    _stub_ping_total_loss

    run _pick_probe_target "lte0"

    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "_pick_probe_target: falls back to DEFAULT_CHECK_IPS" {
    unset CHECK_IPS
    _stub_ping_only "8.8.8.8"

    run _pick_probe_target "lte0"

    [ "$status" -eq 0 ]
    [ "$output" = "8.8.8.8" ]
}

# ============================================================================
# test_wan_quality
# ============================================================================

@test "test_wan_quality: measures the internet path, reports gateway separately" {
    CHECK_IPS=("1.1.1.1")
    _stub_ping_split
    get_gateway() { echo "198.51.100.1"; }
    measure_dns_performance() { echo "195"; }
    measure_http_performance() { echo "179"; }

    run test_wan_quality "lte0"

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"latency_ms": 58.465'
    echo "$output" | grep -q '"gateway_latency_ms": 1.300'
}

@test "test_wan_quality: stdout is pure JSON with the gateway keys" {
    CHECK_IPS=("8.8.8.8")
    _stub_ping_healthy
    get_gateway() { echo "198.51.100.1"; }
    measure_dns_performance() { echo "195"; }
    measure_http_performance() { echo "179"; }

    # Deliberately NOT `run`: bats merges stderr into $output, while the metrics
    # collector reads stdout only. Capturing stdout alone is what reproduces the
    # collector's view — and it is the contract that matters.
    local json
    json=$(test_wan_quality "lte0" 2>/dev/null)

    echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for key in ('latency_ms', 'packet_loss_pct', 'jitter_ms',
            'gateway_latency_ms', 'gateway_reachable',
            'dns_time_ms', 'http_time_ms', 'overall_score'):
    assert key in d, f'missing key: {key}'
assert d['latency_ms'] == 70.695, d['latency_ms']
assert d['gateway_reachable'] == 1, d['gateway_reachable']
"
}

@test "test_wan_quality: keeps log output off stdout" {
    # Regression: common.sh logs to stdout by default, and test_wan_quality()
    # has its stdout captured by the metrics collector via json.loads(). Any
    # log call without >&2 turns the payload into unparseable "Extra data" and
    # silently kills the whole metrics pipeline.
    CHECK_IPS=("8.8.8.8")
    _stub_ping_healthy
    get_gateway() { echo "198.51.100.1"; }
    measure_dns_performance() { echo "195"; }
    measure_http_performance() { echo "179"; }

    local json first_char
    json=$(test_wan_quality "lte0" 2>/dev/null)
    first_char="${json:0:1}"

    [ "$first_char" = "{" ]
    # No log level markers anywhere in the payload
    ! grep -qE '\[(INFO|DEBUG|WARNING|ERROR)\]' <<< "$json"
}

@test "test_wan_quality: WAN_QUALITY_TARGET_MODE=gateway restores old behaviour" {
    export WAN_QUALITY_TARGET_MODE=gateway
    CHECK_IPS=("1.1.1.1")
    _stub_ping_split
    get_gateway() { echo "198.51.100.1"; }
    measure_dns_performance() { echo "195"; }
    measure_http_performance() { echo "179"; }

    run test_wan_quality "lte0"

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"latency_ms": 1.300'
}

@test "test_wan_quality: sentinels when no probe target is reachable" {
    CHECK_IPS=("192.0.2.1")
    _stub_ping_total_loss
    get_gateway() { echo "198.51.100.1"; }
    measure_dns_performance() { echo "999"; }
    measure_http_performance() { echo "999"; }

    run test_wan_quality "lte0"

    echo "$output" | grep -q '"latency_ms": 999.99'
    echo "$output" | grep -q '"packet_loss_pct": 100'
    echo "$output" | grep -q '"overall_score": 0'
}

@test "test_wan_quality: gateway_reachable=0 while the internet path still measures" {
    CHECK_IPS=("8.8.8.8")
    _stub_ping_only "8.8.8.8"
    get_gateway() { echo "198.51.100.1"; }
    measure_dns_performance() { echo "195"; }
    measure_http_performance() { echo "179"; }

    run test_wan_quality "lte0"

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"gateway_reachable": 0'
    echo "$output" | grep -q '"latency_ms": 20.000'
}
