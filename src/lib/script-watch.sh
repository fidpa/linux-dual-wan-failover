#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Script-Watch Library — Erkennt Code-Änderungen in laufenden Daemons
# Version: 1.1.0
# Created: 02.04.2026
#
#
[[ -n "${_SCRIPT_WATCH_LOADED:-}" ]] && return 0
readonly _SCRIPT_WATCH_LOADED=1

set -uo pipefail

# ERROR HANDLING PATTERN:
# - Alle Funktionen geben 0 (OK) oder 1 (Init-Fehler) zurück
# - AUSNAHME: script_watch_check() und script_watch_check_timed() rufen exit 0 auf
#   wenn das Script geändert wurde. Dies ist eine bewusste Designentscheidung (kein return):
#   Die Library-Funktion muss den CALLER-Prozess beenden, nicht nur sich selbst zurückgeben.
#   audit-rationale: exit-in-lib — systemd-restart-signal

# Interne State-Variablen (global, aber mit Namespace-Prefix)
_SCRIPT_WATCH_PATH=""
_SCRIPT_WATCH_MTIME=0
_SCRIPT_WATCH_INTERVAL="${SCRIPT_WATCH_INTERVAL:-20}"      # Default: alle 20 Iterationen
_SCRIPT_WATCH_LAST_CHECK=0
_SCRIPT_WATCH_TIME_INTERVAL="${SCRIPT_WATCH_TIME_INTERVAL:-60}"  # Default: alle 60s

# ----------------------------------------------------------------------------
# script_watch_init <script_path>
#
# Registriert das zu überwachende Script und merkt sich die aktuelle mtime.
# Muss einmalig beim Script-Start aufgerufen werden.
#
# Args:
#   $1 — Pfad zum Script (typisch: "${BASH_SOURCE[0]}" im aufrufenden Script)
# ----------------------------------------------------------------------------
script_watch_init() {
    local script_path="${1:-}"

    if [[ -z "$script_path" ]]; then
        log "WARNING" "script_watch_init: kein Pfad angegeben — Script-Watch deaktiviert" 2>/dev/null || \
            echo "[WARN] script_watch_init: kein Pfad angegeben — Script-Watch deaktiviert" >&2
        return 1
    fi

    # Symlinks auflösen (readlink -f) damit mtime des echten Files verglichen wird
    local resolved_path
    resolved_path="$(readlink -f "$script_path" 2>/dev/null)" || resolved_path="$script_path"

    if [[ ! -f "$resolved_path" ]]; then
        log "WARNING" "script_watch_init: Script nicht gefunden: $resolved_path — Script-Watch deaktiviert" 2>/dev/null || \
            echo "[WARN] script_watch_init: Script nicht gefunden: $resolved_path" >&2
        return 1
    fi

    _SCRIPT_WATCH_PATH="$resolved_path"
    _SCRIPT_WATCH_MTIME="$(stat -c %Y "$resolved_path" 2>/dev/null || echo "0")"

    log "INFO" "Script-Watch aktiv: $(basename "$_SCRIPT_WATCH_PATH") (mtime: $_SCRIPT_WATCH_MTIME, Check alle ${_SCRIPT_WATCH_INTERVAL} Iterationen)" 2>/dev/null || \
        echo "[INFO] Script-Watch aktiv: $(basename "$_SCRIPT_WATCH_PATH")" >&2

    return 0
}

# ----------------------------------------------------------------------------
# script_watch_check <iteration>
#
# Prüft ob das Script seit dem Start geändert wurde. Bei Änderung wird das
# Script mit exit 0 beendet — systemd (Restart=always) startet die neue Version.
#
# Args:
#   $1 — aktueller Loop-Zähler (check findet nur alle N Iterationen statt)
# ----------------------------------------------------------------------------
script_watch_check() {
    local iteration="${1:-0}"

    # Nur initialisiert und im richtigen Intervall prüfen
    [[ -z "$_SCRIPT_WATCH_PATH" ]] && return 0
    (( iteration % _SCRIPT_WATCH_INTERVAL != 0 )) && return 0

    local current_mtime
    current_mtime="$(stat -c %Y "$_SCRIPT_WATCH_PATH" 2>/dev/null)" || return 0

    if [[ "$current_mtime" != "$_SCRIPT_WATCH_MTIME" ]]; then
        log "INFO" "SCRIPT_WATCH: $(basename "$_SCRIPT_WATCH_PATH") wurde geändert (mtime: $_SCRIPT_WATCH_MTIME → $current_mtime) — sauberer Neustart via systemd" 2>/dev/null || \
            echo "[INFO] SCRIPT_WATCH: Script geändert — Neustart" >&2
        # audit-rationale: exit-in-lib — Absicht: Caller-Prozess beenden für systemd-Restart
        exit 0
    fi

    return 0
}

# ----------------------------------------------------------------------------
# script_watch_check_timed
#
# Zeitbasierte Variante für Stream-basierte Daemons ohne Iteration-Counter
# (z.B. `ip monitor link`). Prüft ob N Sekunden seit dem letzten Check
# vergangen sind (Default: 60s via SCRIPT_WATCH_TIME_INTERVAL).
#
# Kein Argument erforderlich — nutzt interne Zeitstempel-Variable.
# ----------------------------------------------------------------------------
script_watch_check_timed() {
    [[ -z "$_SCRIPT_WATCH_PATH" ]] && return 0

    local now
    now="${EPOCHSECONDS:-$(date +%s)}"

    (( now - _SCRIPT_WATCH_LAST_CHECK < _SCRIPT_WATCH_TIME_INTERVAL )) && return 0
    _SCRIPT_WATCH_LAST_CHECK="$now"

    local current_mtime
    current_mtime="$(stat -c %Y "$_SCRIPT_WATCH_PATH" 2>/dev/null)" || return 0

    if [[ "$current_mtime" != "$_SCRIPT_WATCH_MTIME" ]]; then
        log "INFO" "SCRIPT_WATCH: $(basename "$_SCRIPT_WATCH_PATH") wurde geändert (mtime: $_SCRIPT_WATCH_MTIME → $current_mtime) — sauberer Neustart via systemd" 2>/dev/null || \
            echo "[INFO] SCRIPT_WATCH: Script geändert — Neustart" >&2
        # audit-rationale: exit-in-lib — Absicht: Caller-Prozess beenden für systemd-Restart
        exit 0
    fi

    return 0
}
