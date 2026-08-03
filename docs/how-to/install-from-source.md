# How-to: install from source

This is the manual install procedure. The repo ships an `install.sh` that
automates these steps; this document is for operators who want to know
exactly what gets placed where, or who need to install on a distro the script doesn't cover.

## Prerequisites

- Linux (any distro with `systemd` ≥ 245 and `iproute2`).
- Bash 4.0+.
- NetworkManager (`nmcli`) for the event-driven monitor. Failover-monitor
  also works in polling-only mode without NM, but reaction time goes from
  ~5 s to ~15 s.
- Python 3.10+ for the metrics collector and the LM1200 quota provider.
- Root (for installing systemd units, writing to `/usr/local/lib`,
  manipulating `ip route`).

Recommended (but optional):
- [`bash-production-toolkit`](https://github.com/fidpa/bash-production-toolkit)
  installed to `/usr/local/lib/bash-production-toolkit/`. The failover
  services will auto-detect it and use its structured logging.

## Layout

```
/usr/local/lib/linux-dual-wan-failover/
├── lib/                  # sourced libraries
├── services/             # daemons (Bash + Python)
├── tools/                # operator CLIs (trace-failover.sh)
├── plugins/
│   ├── alerting/
│   └── quota-providers/
│       └── _schema/      # quota-snapshot JSON schema
└── web/                  # only with --with-web-ui (src/ + venv/)

/etc/linux-dual-wan-failover/
├── failover.conf         # main config
└── lm1200.env            # mode 0600, only if you use the LM1200 plugin

/etc/systemd/system/
├── failover-monitor.service
├── nmcli-failover-monitor.service
├── route-guardian.service
├── failover-metrics-collector.service
├── failover-monitor-health-check.service
└── failover-monitor-health-check.timer

/var/lib/linux-dual-wan-failover/    # state (auto-created by systemd StateDirectory=)
/var/log/linux-dual-wan-failover/    # logs (auto-created by systemd LogsDirectory=)
/run/linux-dual-wan-failover/        # runtime (auto-created by systemd RuntimeDirectory=)
```

## Manual install

```bash
git clone https://github.com/fidpa/linux-dual-wan-failover.git
cd linux-dual-wan-failover

# 1. Libraries, services and operator tools.
sudo install -d /usr/local/lib/linux-dual-wan-failover/lib
sudo install -d /usr/local/lib/linux-dual-wan-failover/services
sudo install -d /usr/local/lib/linux-dual-wan-failover/tools
sudo install -m 644 src/lib/*.sh        /usr/local/lib/linux-dual-wan-failover/lib/
sudo install -m 755 src/services/*.sh   /usr/local/lib/linux-dual-wan-failover/services/
sudo install -m 755 src/services/*.py   /usr/local/lib/linux-dual-wan-failover/services/
sudo install -m 755 src/tools/*.sh      /usr/local/lib/linux-dual-wan-failover/tools/

# 2. Plugins.
sudo install -d /usr/local/lib/linux-dual-wan-failover/plugins/alerting
sudo install -m 644 plugins/alerting/*.sh /usr/local/lib/linux-dual-wan-failover/plugins/alerting/

sudo install -d /usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/_schema
sudo install -m 644 plugins/quota-providers/_schema/* \
    /usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/_schema/

# Quota plugins ship per-provider; install only the one you'll use.
# Example for netgear-lm1200:
sudo install -d /usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/netgear-lm1200
sudo install -m 755 \
    plugins/quota-providers/netgear-lm1200/collect-quota.py \
    /usr/local/lib/linux-dual-wan-failover/plugins/quota-providers/netgear-lm1200/

# 3. systemd units.
# Skip failover-web.service unless you also install the optional Web-UI;
# it is easier to let `install.sh --with-web-ui` handle that whole branch
# (venv, failover-web user, sudoers, tmpfiles, logrotate).
sudo install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/

# 4. Config.
sudo install -d -m 755 /etc/linux-dual-wan-failover
sudo install -m 644 config/failover.conf.example /etc/linux-dual-wan-failover/failover.conf
sudo $EDITOR /etc/linux-dual-wan-failover/failover.conf

# 5. Activate.
sudo systemctl daemon-reload
sudo systemctl enable --now \
    failover-monitor.service \
    nmcli-failover-monitor.service \
    route-guardian.service \
    failover-metrics-collector.service \
    failover-monitor-health-check.timer
```

## Verifying the install

```bash
# All four core services should be active.
systemctl is-active failover-monitor nmcli-failover-monitor route-guardian failover-metrics-collector

# Health-check timer should be active and have a NextElapseUSec in the future.
systemctl status failover-monitor-health-check.timer

# Initial state files should exist.
ls /run/linux-dual-wan-failover/
ls /var/lib/linux-dual-wan-failover/

# Logs should be flowing.
journalctl -u failover-monitor -n 50
```

## Uninstalling

```bash
sudo systemctl disable --now \
    failover-monitor.service \
    nmcli-failover-monitor.service \
    route-guardian.service \
    failover-metrics-collector.service \
    failover-monitor-health-check.timer

sudo rm -f /etc/systemd/system/{failover-monitor,nmcli-failover-monitor,route-guardian,failover-metrics-collector,failover-monitor-health-check}.{service,timer}
sudo rm -rf /usr/local/lib/linux-dual-wan-failover
sudo rm -rf /var/lib/linux-dual-wan-failover /var/log/linux-dual-wan-failover

# Optional: also remove your config.
sudo rm -rf /etc/linux-dual-wan-failover

sudo systemctl daemon-reload
```

If you installed the Web-UI, it leaves a few things outside those paths:

```bash
sudo systemctl disable --now failover-web.service
sudo rm -f /etc/systemd/system/failover-web.service \
           /etc/sudoers.d/failover-web \
           /etc/tmpfiles.d/failover-web.conf \
           /etc/logrotate.d/failover-web \
           /usr/local/sbin/install-failover-conf
sudo userdel failover-web
sudo systemctl daemon-reload
```
