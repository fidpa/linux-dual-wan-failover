#!/usr/bin/env bash
set -euo pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

python3 - "$WORK" "$TESTDIR" <<'PY'
from pathlib import Path
import sys

work = Path(sys.argv[1])
target = Path(sys.argv[2])

source = (work / "src/services/route-guardian.sh").read_text()

start = source.index("cleanup_interface_duplicate_routes() {")
end = source.index("\n}", start) + 2

(target / "cleanup.sh").write_text(source[start:end] + "\n")
PY

source "$TESTDIR/cleanup.sh"

DSL_INTERFACE=eth0
LTE_INTERFACE=wlan0
BACKUP_METRIC=200

EXPECTED=50
LOCK_ACTIVE=false
LOCK_BUSY=false
ROUTES=""
DELETIONS=""

log_message() { :; }

_acquire_route_lock() {
    [[ "$LOCK_BUSY" == false ]]
}

_release_route_lock() { :; }

_failover_lock_active() {
    [[ "$LOCK_ACTIVE" == true ]]
}

get_expected_primary_metric() {
    echo "$EXPECTED"
}

ip() {
    case "$*" in
        "-4 route show default dev "*)
            printf '%s\n' "$ROUTES"
            ;;
        "-4 route del default via "*)
            DELETIONS+="$*"$'\n'
            ;;
        *)
            echo "Unexpected mock command: $*" >&2
            return 1
            ;;
    esac
}

PASSED=0

check() {
    local name="$1"
    local expected="$2"
    local iface="${3:-eth0}"

    DELETIONS=""

    cleanup_interface_duplicate_routes "$iface"

    if [[ "$DELETIONS" == "$expected" ]]; then
        echo "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $name"
        printf 'Expected: %q\n' "$expected"
        printf 'Actual:   %q\n' "$DELETIONS"
        exit 1
    fi
}

ROUTES=$'default via 192.168.178.1 dev eth0 metric 50\ndefault via 192.168.178.1 dev eth0 metric 500'

EXPECTED=50
check "Normalbetrieb: metric 50 behalten" \
    $'-4 route del default via 192.168.178.1 dev eth0 metric 500\n'

EXPECTED=500
check "Failover: metric 500 behalten" \
    $'-4 route del default via 192.168.178.1 dev eth0 metric 50\n'

LOCK_ACTIVE=true
check "Aktive Failover-Sperre" ""
LOCK_ACTIVE=false

LOCK_BUSY=true
check "Route Lock belegt" ""
LOCK_BUSY=false

ROUTES="default via 192.168.178.1 dev eth0 metric 50"
EXPECTED=500
check "Erwartete Route fehlt: nichts löschen" ""

ROUTES="default via 192.168.178.1 dev eth0 metric 500"
check "Korrekte Einzelroute behalten" ""

ROUTES=""
check "Keine vorhandenen Routen" ""

ROUTES=$'default via 172.20.10.1 dev wlan0 metric 200\ndefault via 172.20.10.1 dev wlan0 metric 300'

check "Backup-Metrik 200 behalten" \
    $'-4 route del default via 172.20.10.1 dev wlan0 metric 300\n' \
    wlan0

echo
EXPECTED=500
ROUTES="default via 192.168.178.1 dev eth0"

check "Route ohne explizite Metrik" ""

echo "=== REGRESSION TEST RESULTS ==="
echo "$PASSED/9 tests passed"
echo "Production network unchanged."
