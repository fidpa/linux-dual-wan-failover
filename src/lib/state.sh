#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Shared Monitoring Library - State Management Module
# Provides: Smart Alert state management for deduplication + defensive line counting
# Dependencies: logging.sh, secure-file-utils.sh
# Version: 1.2.0
# Date: 14.11.2025 (Created), 14.11.2025 (v1.1 Bug Fix), 20.01.2026 (v1.2 Bug Fix)
#
[[ -n "${MONITORING_STATE_LOADED:-}" ]] && return 0
readonly MONITORING_STATE_LOADED=1

# ============================================================================
# STATE FILE MANAGEMENT
# ============================================================================

# Load state from file
# Usage: state_load "check_name"
# Returns: Newline-separated list of items (empty if file doesn't exist)
state_load() {
    local state_name="$1"
    local state_file="${STATE_DIR}/.${state_name}_state"

    if [[ ! -f "$state_file" ]]; then
        log_debug "No previous state found for $state_name"
        return 0
    fi

    # Return file contents (newline-separated)
    cat "$state_file" 2>/dev/null || true

    # Note: Use cat|wc instead of wc<file to properly suppress permission errors
    log_debug "Loaded state for $state_name: $(cat "$state_file" 2>/dev/null | wc -l) items"
}

# Save state to file (atomic write)
# Usage: state_save "check_name" "item1\nitem2\nitem3"
# Empty state is allowed (means no issues)
state_save() {
    local state_name="$1"
    local state_data="$2"
    local state_file="${STATE_DIR}/.${state_name}_state"

    # Handle empty state (no issues = empty file)
    if [[ -z "$state_data" ]]; then
        # Empty state - create/truncate file
        : > "$state_file"  # Truncate to empty
        log_debug "Saved empty state for $state_name (no issues)"
        return 0
    fi

    # Use secure-file-utils for atomic write
    if sfu_write_file "$state_data" "$state_file"; then
        local count
        count=$(count_lines "$state_data")
        log_debug "Saved state for $state_name: $count items"
        return 0
    else
        log_error "Failed to save state for $state_name"
        return 1
    fi
}

# Reset state (delete state file)
# Usage: state_reset "check_name"
# Returns: 0 on success
state_reset() {
    local state_name="$1"
    local state_file="${STATE_DIR}/.${state_name}_state"

    if [[ -f "$state_file" ]]; then
        rm -f "$state_file"
        log_info "Reset state for $state_name"
        return 0
    else
        log_warning "No state file to reset for $state_name"
        return 1
    fi
}

# ============================================================================
# STATE COMPARISON
# ============================================================================

# Compare current vs known state
# Usage: state_compare "current_items" "known_items"
# Returns: "new_items|recovered_items|unchanged_items" (pipe-separated)
#
# Logic:
#   - new_items: In current but NOT in known (new failures)
#   - recovered_items: In known but NOT in current (recovered)
#   - unchanged_items: In BOTH current and known (ongoing issues)
state_compare() {
    local current="$1"
    local known="$2"

    # Handle empty cases
    if [[ -z "$current" ]] && [[ -z "$known" ]]; then
        echo "||"  # All empty
        return 0
    fi

    if [[ -z "$current" ]]; then
        # All issues recovered
        echo "|${known}|"
        return 0
    fi

    if [[ -z "$known" ]]; then
        # All issues are new
        echo "${current}||"
        return 0
    fi

    # Both have content - do proper comparison
    local new_items=""
    local recovered_items=""
    local unchanged_items=""

    # Find NEW items (in current but not in known)
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        if ! echo "$known" | grep -Fxq "$item"; then
            [[ -n "$new_items" ]] && new_items+=$'\n'
            new_items+="$item"
        fi
    done <<< "$current"

    # Find RECOVERED items (in known but not in current)
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        if ! echo "$current" | grep -Fxq "$item"; then
            [[ -n "$recovered_items" ]] && recovered_items+=$'\n'
            recovered_items+="$item"
        fi
    done <<< "$known"

    # Find UNCHANGED items (in both)
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        if echo "$current" | grep -Fxq "$item"; then
            [[ -n "$unchanged_items" ]] && unchanged_items+=$'\n'
            unchanged_items+="$item"
        fi
    done <<< "$known"

    # Return pipe-separated
    echo "${new_items}|${recovered_items}|${unchanged_items}"

    # Log comparison results (using defensive count_lines)
    local new_count
    new_count=$(count_lines "$new_items")
    local recovered_count
    recovered_count=$(count_lines "$recovered_items")
    local unchanged_count
    unchanged_count=$(count_lines "$unchanged_items")

    log_debug "State comparison: $new_count new, $recovered_count recovered, $unchanged_count unchanged"
}

# ============================================================================
# LINE COUNTING (Defensive Implementation)
# ============================================================================

# Count non-empty lines in a string
# Usage: count_lines "$string"
# Returns: Number of non-empty lines (0 if empty/whitespace-only)
#
# Best Practice 2025: Explicit empty-check prevents grep -c '^' bug
# where empty strings are counted as 1 line
count_lines() {
    local data="$1"

    # Empty check - return 0 immediately
    [[ -z "$data" ]] && { echo "0"; return 0; }

    # Whitespace-only check - return 0 for strings with only spaces/tabs/newlines
    [[ "$data" =~ ^[[:space:]]*$ ]] && { echo "0"; return 0; }

    # Count lines with actual content (grep . matches any character)
    # This is more reliable than grep -c '^' which counts newlines
    echo "$data" | grep -c '.'
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Check if state exists
# Usage: state_exists "check_name"
# Returns: 0 if exists, 1 if not
state_exists() {
    local state_name="$1"
    local state_file="${STATE_DIR}/.${state_name}_state"
    [[ -f "$state_file" ]]
}

# Get state file path
# Usage: state_get_path "check_name"
# Returns: Full path to state file
state_get_path() {
    local state_name="$1"
    echo "${STATE_DIR}/.${state_name}_state"
}

# Count items in state
# Usage: state_count "check_name"
# Returns: Number of items in state file (0 if doesn't exist)
state_count() {
    local state_name="$1"
    local state_file="${STATE_DIR}/.${state_name}_state"

    if [[ ! -f "$state_file" ]]; then
        echo "0"
        return 0
    fi

    # Use count_lines for consistent counting logic
    local state_data
    state_data=$(cat "$state_file" 2>/dev/null || true)
    count_lines "$state_data"
}

# ============================================================================
# EXPORTS
# ============================================================================

export -f count_lines
export -f state_load
export -f state_save
export -f state_reset
export -f state_compare
export -f state_exists
export -f state_get_path
export -f state_count
