#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# none.sh — no-op alerting plugin (default)
#
# Selecting ALERTING_BACKEND=none short-circuits in common.sh before this
# file is sourced, so this is mostly here for symmetry. If you do source
# it, send_alert() just returns 0.

send_alert() {
    return 0
}
