#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install.sh — install linux-dual-wan-failover from the repo into
# /usr/local/lib/linux-dual-wan-failover and /etc/linux-dual-wan-failover.
#
# Idempotent: re-running this script updates an existing install.
#
# Does NOT enable any services — see docs/tutorial/01-quickstart.md
# for the post-install steps.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
LIB_DIR="${LIB_DIR:-${PREFIX}/lib/linux-dual-wan-failover}"
ETC_DIR="${ETC_DIR:-/etc/linux-dual-wan-failover}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "install.sh must be run as root (paths under /usr/local, /etc, /etc/systemd)" >&2
        exit 1
    fi
}

install_libs() {
    install -d -m 755 "${LIB_DIR}/lib" "${LIB_DIR}/services"
    install -m 644 "${REPO_ROOT}"/src/lib/*.sh "${LIB_DIR}/lib/"
    install -m 755 "${REPO_ROOT}"/src/services/*.sh "${LIB_DIR}/services/"
    install -m 755 "${REPO_ROOT}"/src/services/*.py "${LIB_DIR}/services/"
}

install_alerting_plugins() {
    install -d -m 755 "${LIB_DIR}/plugins/alerting"
    install -m 644 "${REPO_ROOT}"/plugins/alerting/*.sh "${LIB_DIR}/plugins/alerting/"
}

install_quota_template() {
    install -d -m 755 "${LIB_DIR}/plugins/quota-providers/custom-template"
    install -m 755 \
        "${REPO_ROOT}/plugins/quota-providers/custom-template/collect-quota.sh" \
        "${LIB_DIR}/plugins/quota-providers/custom-template/"

    install -d -m 755 "${LIB_DIR}/plugins/quota-providers/_schema"
    install -m 644 \
        "${REPO_ROOT}/plugins/quota-providers/_schema/quota-snapshot.schema.json" \
        "${LIB_DIR}/plugins/quota-providers/_schema/"
}

install_systemd_units() {
    install -d -m 755 "${SYSTEMD_DIR}"
    install -m 644 "${REPO_ROOT}"/systemd/*.service "${SYSTEMD_DIR}/"
    install -m 644 "${REPO_ROOT}"/systemd/*.timer "${SYSTEMD_DIR}/"
    systemctl daemon-reload
}

install_config() {
    install -d -m 755 "${ETC_DIR}"
    if [[ ! -f "${ETC_DIR}/failover.conf" ]]; then
        install -m 644 "${REPO_ROOT}/config/failover.conf.example" "${ETC_DIR}/failover.conf"
        echo "Installed default config: ${ETC_DIR}/failover.conf"
        echo "  → Edit it to set PRIMARY_IFACE, BACKUP_IFACE, *_NM_CONNECTION."
    else
        echo "Existing config preserved: ${ETC_DIR}/failover.conf"
        echo "  → New options may be in ${ETC_DIR}/failover.conf.example.new"
        install -m 644 "${REPO_ROOT}/config/failover.conf.example" \
            "${ETC_DIR}/failover.conf.example.new"
    fi
}

print_next_steps() {
    cat <<EOF

==================================================================
linux-dual-wan-failover installed.

Next steps:

  1. Edit the config:
       sudo \$EDITOR ${ETC_DIR}/failover.conf

  2. Enable and start the services:
       sudo systemctl enable --now \\
         failover-monitor.service \\
         nmcli-failover-monitor.service \\
         route-guardian.service \\
         failover-metrics-collector.service \\
         failover-monitor-health-check.timer

  3. Verify:
       systemctl is-active failover-monitor nmcli-failover-monitor route-guardian
       journalctl -u failover-monitor -f

Quickstart guide: docs/tutorial/01-quickstart.md
==================================================================
EOF
}

main() {
    require_root
    echo "Installing linux-dual-wan-failover into ${LIB_DIR} ..."
    install_libs
    install_alerting_plugins
    install_quota_template
    install_systemd_units
    install_config
    print_next_steps
}

main "$@"
