# SPDX-License-Identifier: MIT
# tests/helpers.bash — shared setup/teardown for bats tests.
#
# Source from each .bats file:
#   load ../helpers

# Repo root, regardless of where bats was invoked from.
TEST_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_REPO_ROOT

# Path to the source under test.
SRC_DIR="${TEST_REPO_ROOT}/src"
export SRC_DIR

# Set up an isolated temp environment for one bats test:
#   - All state/runtime/log paths point under BATS_TMPDIR
#   - System commands `ip`, `nmcli`, `ping` are intercepted by mocks
#   - Toolkit lookup is disabled (we use the in-tree fallback logger)
setup_test_env() {
    export TMPROOT
    TMPROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}/lduwf-$$}"
    mkdir -p "$TMPROOT"/{run,state,log}

    export RUNTIME_DIR="$TMPROOT/run"
    export STATE_DIR="$TMPROOT/state"
    export LOG_DIR="$TMPROOT/log"
    export LOG_FILE="$LOG_DIR/test.log"
    export LOG_TO_JOURNAL=false
    export LOG_TO_STDOUT=false

    # Default test interfaces; override per-test as needed.
    export PRIMARY_IFACE="eth0"
    export BACKUP_IFACE="lte0"

    # Quota / alerting plugins disabled by default.
    export QUOTA_PROVIDER="none"
    export ALERTING_BACKEND="none"
    export QUOTA_SNAPSHOT_PATH="$STATE_DIR/quota-snapshot.json"
    export QUOTA_SNAPSHOT_MAX_STALE_SEC=3600
    export QUOTA_CAP_TIER_90=40
    export QUOTA_CAP_TIER_96=10
    export QUOTA_CAP_TIER_100=0

    # Disable toolkit lookup so common.sh uses its fallback logger.
    unset TOOLKIT_LIB

    # Prefer mocks over real binaries.
    export PATH="${TEST_REPO_ROOT}/tests/mocks:$PATH"
}

teardown_test_env() {
    [[ -n "${TMPROOT:-}" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"
}

# Write a quota snapshot JSON to QUOTA_SNAPSHOT_PATH.
# Usage: make_quota_snapshot 87.4
#        make_quota_snapshot null 7200    # null + age in seconds
make_quota_snapshot() {
    local pct="$1"
    local age="${2:-0}"
    local pct_field
    if [[ "$pct" == "null" ]]; then
        pct_field='null'
    else
        pct_field="$pct"
    fi
    cat > "$QUOTA_SNAPSHOT_PATH" <<EOF
{"limit_pct": ${pct_field}, "collected_at": "2026-04-27T00:00:00Z", "provider": "test"}
EOF
    if [[ $age -gt 0 ]]; then
        local ts
        ts=$(($(date +%s) - age))
        touch -d "@$ts" "$QUOTA_SNAPSHOT_PATH"
    fi
}
