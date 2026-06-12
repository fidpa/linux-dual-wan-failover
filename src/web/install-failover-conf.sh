#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-failover-conf.sh — root-side validating installer for failover.conf
#
# Purpose
# -------
# Closes a privilege-escalation path that exists whenever a non-root web
# service can write the config that a root-running daemon then `source`s
# as Bash. Without this validator the chain looks like::
#
#   failover-web → writes /var/lib/failover-web/staging/failover.conf
#                → sudo cp copies bytes verbatim → /etc/.../failover.conf
#                → failover-monitor.sh sources it as Bash (running as root)
#                = arbitrary root code execution via attacker-controlled `source`.
#
# Architecture
# ------------
#
#   ┌─ Web-Schema ─┐
#   │  (Layer 1)   │  failover-web validates schema (web/readers/config_reader.py)
#   └──────────────┘
#          │
#          ▼
#   /var/lib/failover-web/staging/failover.conf  (failover-web:failover-web 0640)
#          │
#          │  sudo /usr/local/sbin/install-failover-conf
#          ▼
#   ┌─ Re-Validate ─┐  (Layer 2 — THIS SCRIPT, root:root 0750)
#   │  per Line!    │  - Re-parse every key/value against SAFE_KEY_RE / SAFE_VALUE_RE
#   └───────────────┘  - Reject `$`, backticks, `$(...)`, `;`, `|`, newlines in values
#          │           - Atomic write via tempfile + rename
#          ▼
#   /etc/<project>/failover.conf  (root:root 0644)
#          │
#          ▼
#   [failover-monitor.sh `source`]                  ◀ now safe: source content was sanitized as root
#
# Sudoers entry (replaces any broad `install` rule)::
#
#   failover-web ALL=(root) NOPASSWD: /usr/local/sbin/install-failover-conf
#
# Defence-in-depth properties
# ---------------------------
# - The staging path is FIXED (no argument).
# - The destination path is FIXED (no argument).
# - Validation runs as root (cannot be tampered with by failover-web).
# - Only the keys listed in CONFIG_SCHEMA are accepted; everything else aborts.
# - Values must match SAFE_VALUE_RE (digits-only — failover.conf is integers only
#   for the whitelisted keys).
# - Line and file caps prevent runaway input.
# - Atomic install via mktemp + chown + chmod + mv.
#
# Override points (env, set in the systemd unit or the install script)::
#
#   STAGING_PATH   — defaults to /var/lib/failover-web/staging/failover.conf
#   TARGET_PATH    — defaults to /etc/linux-dual-wan-failover/failover-overrides.conf
#   TARGET_OWNER   — defaults to root
#   TARGET_GROUP   — defaults to root
#   TARGET_MODE    — defaults to 0644

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

readonly STAGING_PATH="${STAGING_PATH:-/var/lib/failover-web/staging/failover.conf}"
# Target is the OVERRIDE file, not the base config: this helper requires
# EVERY line of the staged file to be a whitelisted integer tunable — the
# full base config (interfaces, test targets, ...) could never pass that
# validation. The base config stays static; the daemon sources the override
# file after it (bash last-wins).
readonly TARGET_PATH="${TARGET_PATH:-/etc/linux-dual-wan-failover/failover-overrides.conf}"
readonly TARGET_OWNER="${TARGET_OWNER:-root}"
readonly TARGET_GROUP="${TARGET_GROUP:-root}"
readonly TARGET_MODE="${TARGET_MODE:-0644}"

# Keep the schema in sync with web/readers/config_reader.py::CONFIG_SCHEMA.
# When you add a tunable to the web UI, add it here as well.
readonly -a CONFIG_SCHEMA=(
    "FAILOVER_THRESHOLD_DOWN"
    "FAILURE_THRESHOLD"
    "RECOVERY_THRESHOLD"
    "EMERGENCY_THRESHOLD"
    "ANTI_FLAPPING_DELAY"
    "MIN_FAILBACK_SCORE"
    "MIN_BACKUP_TIME"
    "MIN_STABLE_DURATION"
    "STABILITY_RESET_THRESHOLD"
    "LATENCY_CRITICAL"
    "LATENCY_WARNING"
    "PACKET_LOSS_CRITICAL"
    "PACKET_LOSS_WARNING"
    "EMERGENCY_FAILBACK_DNS_THRESHOLD_MS"
    "EMERGENCY_FAILBACK_MIN_BACKUP_TIME"
)

readonly SAFE_KEY_RE='^[A-Z_][A-Z0-9_]*$'
readonly SAFE_VALUE_RE='^[0-9]+$'
readonly MAX_LINES=200
readonly MAX_LINE_LEN=256
readonly MAX_FILE_BYTES=16384

log() { printf '[install-failover-conf] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

[[ "$(id -u)" -eq 0 ]] || die "must be invoked via sudo (EUID=$(id -u))"
(( $# == 0 )) || die "no arguments allowed (got: $*)"

[[ -f "$STAGING_PATH" ]] || die "staging file missing: $STAGING_PATH"
[[ -r "$STAGING_PATH" ]] || die "staging file unreadable: $STAGING_PATH"

staged_size=$(stat -c '%s' "$STAGING_PATH")
(( staged_size <= MAX_FILE_BYTES )) || die "staging file too large: ${staged_size} bytes (max ${MAX_FILE_BYTES})"

# ----------------------------------------------------------------------------
# Validation pass
# ----------------------------------------------------------------------------

line_no=0
seen_keys=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if (( line_no > MAX_LINES )); then
        die "line $line_no: exceeds MAX_LINES=$MAX_LINES"
    fi
    if (( ${#line} > MAX_LINE_LEN )); then
        die "line $line_no: exceeds MAX_LINE_LEN=$MAX_LINE_LEN (length=${#line})"
    fi
    line="${line%$'\r'}"

    if [[ -z "${line// }" ]]; then continue; fi
    if [[ "${line## }" =~ ^# ]]; then continue; fi

    if [[ "$line" != *=* ]]; then
        die "line $line_no: missing '=' in KEY=VALUE line: ${line}"
    fi
    key="${line%%=*}"
    value="${line#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    case "$value" in
        \"*\") value_unquoted="${value:1:${#value}-2}" ;;
        \'*\') value_unquoted="${value:1:${#value}-2}" ;;
        *)     value_unquoted="$value" ;;
    esac

    if [[ "$value" == "$value_unquoted" && "$value_unquoted" == *#* ]]; then
        value_unquoted="${value_unquoted%%#*}"
        value_unquoted="${value_unquoted%"${value_unquoted##*[![:space:]]}"}"
    fi

    if [[ ! "$key" =~ $SAFE_KEY_RE ]]; then
        die "line $line_no: key not safe-identifier: ${key}"
    fi
    found=0
    for allowed in "${CONFIG_SCHEMA[@]}"; do
        if [[ "$key" == "$allowed" ]]; then found=1; break; fi
    done
    (( found == 1 )) || die "line $line_no: key not in CONFIG_SCHEMA: ${key}"

    case "$value_unquoted" in
        *[\$\`\;\|\&\<\>\\\!\(\)\{\}\*\?\[\]]*)
            die "line $line_no: value contains shell metacharacter: ${value_unquoted}"
            ;;
    esac

    if [[ ! "$value_unquoted" =~ $SAFE_VALUE_RE ]]; then
        die "line $line_no: value not safe-integer for ${key}: ${value_unquoted}"
    fi

    for prior in "${seen_keys[@]:-}"; do
        [[ "$prior" == "$key" ]] && die "line $line_no: duplicate key ${key}"
    done
    seen_keys+=("$key")
done < "$STAGING_PATH"

(( line_no > 0 )) || die "staging file is empty"

log "validation OK ($line_no lines, ${#seen_keys[@]} keys)"

# ----------------------------------------------------------------------------
# Atomic install
# ----------------------------------------------------------------------------

target_dir="$(dirname "$TARGET_PATH")"
[[ -d "$target_dir" ]] || die "target directory missing: $target_dir"

tmp_path="$(mktemp -p "$target_dir" .install-failover-conf.XXXXXX)" \
    || die "mktemp failed in $target_dir"
# shellcheck disable=SC2064  # we WANT $tmp_path expanded now (cleanup if mv fails)
trap "rm -f '$tmp_path'" EXIT

cp -f "$STAGING_PATH" "$tmp_path"
chown "$TARGET_OWNER:$TARGET_GROUP" "$tmp_path"
chmod "$TARGET_MODE" "$tmp_path"
mv -f "$tmp_path" "$TARGET_PATH"
trap - EXIT

log "installed $STAGING_PATH → $TARGET_PATH (owner=$TARGET_OWNER:$TARGET_GROUP mode=$TARGET_MODE)"
exit 0
