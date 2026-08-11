#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# failover-monitor-health-check.sh
#
# Verifies that the failover-monitor orchestrator is healthy:
#   1. The PID file exists and the process is alive.
#   2. The orchestrator's metrics state file has been touched within
#      HEALTH_CHECK_MAX_AGE seconds (default 120 s).
#
# If either check fails, the script attempts to restart
# failover-monitor.service and exits non-zero.
#
# Designed to be invoked by the failover-monitor-health-check.timer.

set -uo pipefail

# Load operator config (best-effort; defaults below cover a stock install).
if [[ -f /etc/linux-dual-wan-failover/failover.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/linux-dual-wan-failover/failover.conf
fi

readonly RUNTIME_DIR="${RUNTIME_DIR:-/run/linux-dual-wan-failover}"
readonly PID_FILE="${PID_FILE:-${RUNTIME_DIR}/failover-monitor.pid}"
readonly METRICS_FILE="${METRICS_FILE:-${RUNTIME_DIR}/wan-state/connection_metrics}"
readonly HEALTH_CHECK_MAX_AGE="${HEALTH_CHECK_MAX_AGE:-120}"
readonly SERVICE_NAME="${SERVICE_NAME:-failover-monitor.service}"

log() {
    # journal-friendly: stderr with priority prefix.
    local level="$1"; shift
    case "$level" in
        ERR)  echo "<3>health-check: $*" >&2 ;;
        WARN) echo "<4>health-check: $*" >&2 ;;
        INFO) echo "<6>health-check: $*" >&2 ;;
        *)    echo "<7>health-check: $*" >&2 ;;
    esac
}

restart_service() {
    local reason="$1"
    log WARN "restarting ${SERVICE_NAME}: ${reason}"
    if systemctl restart "$SERVICE_NAME"; then
        log INFO "restart issued"
    else
        log ERR "systemctl restart ${SERVICE_NAME} failed"
    fi
    return 1
}

# 1. PID-file presence and process liveness.
if [[ ! -f "$PID_FILE" ]]; then
    restart_service "PID file ${PID_FILE} missing"
    exit 1
fi

pid=$(cat "$PID_FILE" 2>/dev/null || true)
if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    restart_service "PID file ${PID_FILE} unreadable or malformed"
    exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
    restart_service "process ${pid} from ${PID_FILE} is not alive"
    exit 1
fi

# 2. State-file freshness.
if [[ ! -f "$METRICS_FILE" ]]; then
    log WARN "metrics file ${METRICS_FILE} not present yet; skipping freshness check"
    exit 0
fi

now=$(date +%s)
mtime=$(stat -c %Y "$METRICS_FILE" 2>/dev/null || echo 0)
age=$((now - mtime))

if (( age > HEALTH_CHECK_MAX_AGE )); then
    restart_service "metrics file ${METRICS_FILE} is ${age}s old (>${HEALTH_CHECK_MAX_AGE}s)"
    exit 1
fi

log DEBUG "ok (pid=${pid}, metrics_age=${age}s)"
exit 0
