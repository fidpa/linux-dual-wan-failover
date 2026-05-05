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
#
# Usage::
#
#   sudo ./install.sh                 # core failover stack only
#   sudo ./install.sh --with-web-ui   # adds the optional Flask Web-UI
#                                       (creates failover-web user, venv,
#                                       sudoers, tmpfiles, systemd unit)
#   sudo ./install.sh --help          # show all options

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
LIB_DIR="${LIB_DIR:-${PREFIX}/lib/linux-dual-wan-failover}"
ETC_DIR="${ETC_DIR:-/etc/linux-dual-wan-failover}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
TMPFILES_DIR="${TMPFILES_DIR:-/etc/tmpfiles.d}"
SBIN_DIR="${SBIN_DIR:-${PREFIX}/sbin}"

WITH_WEB_UI=0

usage() {
    cat <<'EOF'
install.sh [--with-web-ui] [--help]

Options:
  --with-web-ui   Install the optional Flask Web-UI alongside the failover
                  stack. Creates /usr/local/lib/.../web/venv, the failover-web
                  system user, sudoers + tmpfiles fragments, and the
                  failover-web.service systemd unit. Requires python3-venv.
  --help          Show this help.

Environment overrides (advanced):
  PREFIX, LIB_DIR, ETC_DIR, SYSTEMD_DIR, SUDOERS_DIR, TMPFILES_DIR, SBIN_DIR
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --with-web-ui) WITH_WEB_UI=1 ;;
        --help|-h)     usage; exit 0 ;;
        *)             echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

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
        echo "  --> Edit it to set PRIMARY_IFACE, BACKUP_IFACE, *_NM_CONNECTION."
    else
        echo "Existing config preserved: ${ETC_DIR}/failover.conf"
        echo "  --> New options may be in ${ETC_DIR}/failover.conf.example.new"
        install -m 644 "${REPO_ROOT}/config/failover.conf.example" \
            "${ETC_DIR}/failover.conf.example.new"
    fi
}

# ---------------------------------------------------------------------------
# Optional Web-UI installation
# ---------------------------------------------------------------------------

ensure_wan_state_group() {
    if ! getent group wan-state >/dev/null; then
        groupadd --system wan-state
        echo "Created system group 'wan-state'."
    fi
}

ensure_failover_web_user() {
    if ! id -u failover-web >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /var/lib/failover-web \
                --shell /usr/sbin/nologin --gid wan-state failover-web
        # Give the user its own primary group too, then re-add wan-state
        # as supplementary if useradd defaulted to wan-state — distro-dependent.
        if ! getent group failover-web >/dev/null; then
            groupadd --system failover-web
            usermod -g failover-web failover-web
        fi
        usermod -a -G wan-state failover-web
        echo "Created system user 'failover-web' (groups: failover-web,wan-state)."
    fi
}

install_web_app() {
    local web_lib="${LIB_DIR}/web"
    install -d -m 755 "${web_lib}"
    cp -r "${REPO_ROOT}/src/web" "${web_lib}/src"
    # The package import path is `web` — symlink for clarity:
    #   /usr/local/lib/linux-dual-wan-failover/web/src/   ← real files
    # gunicorn is started with --pythonpath .../web/src so `import web`
    # picks up `.../web/src/web/...` as the package.
    if [[ ! -d "${web_lib}/venv" ]]; then
        python3 -m venv "${web_lib}/venv"
    fi
    "${web_lib}/venv/bin/pip" install --quiet --upgrade pip
    "${web_lib}/venv/bin/pip" install --quiet -r "${REPO_ROOT}/src/web/requirements.txt"
    echo "Web-UI venv ready: ${web_lib}/venv"
}

install_web_helper() {
    install -d -m 755 "${SBIN_DIR}"
    install -m 0750 -o root -g root \
        "${REPO_ROOT}/src/web/install-failover-conf.sh" \
        "${SBIN_DIR}/install-failover-conf"
}

install_web_systemd() {
    install -m 644 "${REPO_ROOT}/systemd/failover-web.service" "${SYSTEMD_DIR}/"

    install -d -m 755 "${SUDOERS_DIR}"
    install -m 0440 -o root -g root \
        "${REPO_ROOT}/systemd/failover-web.sudoers" \
        "${SUDOERS_DIR}/failover-web"
    if ! visudo -cf "${SUDOERS_DIR}/failover-web" >/dev/null; then
        echo "FATAL: sudoers fragment failed visudo validation; aborting." >&2
        exit 1
    fi

    install -d -m 755 "${TMPFILES_DIR}"
    install -m 644 "${REPO_ROOT}/systemd/failover-web.tmpfiles" \
        "${TMPFILES_DIR}/failover-web.conf"
    systemd-tmpfiles --create "${TMPFILES_DIR}/failover-web.conf" 2>/dev/null || true

    systemctl daemon-reload
}

install_web_ui() {
    if ! command -v python3 >/dev/null; then
        echo "FATAL: python3 not found; --with-web-ui requires Python 3.10+." >&2
        exit 1
    fi
    if ! python3 -c 'import venv' 2>/dev/null; then
        echo "FATAL: python3 lacks the 'venv' module (apt install python3-venv)." >&2
        exit 1
    fi
    ensure_wan_state_group
    ensure_failover_web_user
    install_web_app
    install_web_helper
    install_web_systemd
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
EOF

    if (( WITH_WEB_UI == 1 )); then
        cat <<EOF

  4. Optional Web-UI (installed):
       sudo systemctl enable --now failover-web.service
       curl -s http://127.0.0.1:8091/health | jq .

     The service binds to 127.0.0.1 by design — terminate TLS and limit
     access via a reverse proxy. See systemd/failover-web.nginx.example
     and docs/how-to/configure-web-ui.md.
EOF
    else
        cat <<EOF

  4. Optional Web-UI (NOT installed):
       Re-run with --with-web-ui to add the Flask dashboard.
       Documentation: docs/how-to/configure-web-ui.md.
EOF
    fi

    cat <<EOF

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
    if (( WITH_WEB_UI == 1 )); then
        echo "Installing optional Web-UI into ${LIB_DIR}/web ..."
        install_web_ui
    fi
    print_next_steps
}

main "$@"
