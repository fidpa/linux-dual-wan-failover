# linux-dual-wan-failover

![CI](https://github.com/fidpa/linux-dual-wan-failover/actions/workflows/ci.yml/badge.svg)
![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=gnu-bash)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Bash 4.0+](https://img.shields.io/badge/Bash-4.0%2B-blue?logo=gnu-bash)
![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-blue?logo=python)
![Status: Alpha](https://img.shields.io/badge/Status-Alpha-orange.svg)

**Sub-10s WAN failover for Linux dual-WAN routers, driven by NetworkManager events.**

> Detect a dead primary uplink in under five seconds, switch to the backup
> without dropping established connections, clean up stale routes in under one
> second, and recover automatically when the primary comes back. All in pure
> Bash + a Python metrics collector, on any Linux box with `systemd` and
> `iproute2`.

## Why this exists

If you self-host a Linux router/gateway with a primary uplink (DSL, fiber,
cable, second wired ISP) plus a backup uplink (LTE/4G/5G modem, second WAN),
you've probably hit one of these problems:

- **`pfSense` / `UniFi UDM`** are excellent but proprietary, expensive, and
  failover takes 30–60 s. They also don't play nicely with consumer LTE
  modems.
- **`mwan3` (OpenWrt)** is good but tied to OpenWrt's network stack —
  hard to integrate on a standard Linux box.
- **`keepalived` / `VRRP`** is for active-active HA between *routers*, not
  for steering a single router between two upstream uplinks.
- **Manually scripting it** with `ping` + `ip route` works until the first
  flapping link, where you discover anti-flap, hysteresis, race conditions
  with NetworkManager, and stale `conntrack` state.

This project is what fell out of running a homelab dual-WAN setup (DSL
primary, LTE backup) for 8+ months and writing down every pitfall.

## Comparison

| | linux-dual-wan-failover | pfSense / UniFi | mwan3 (OpenWrt) | DIY shell script |
|---|---|---|---|---|
| Failover time | **< 5 s** (event-driven) | 30–60 s (polling) | 5–15 s | depends |
| Linux distro | any with systemd + NetworkManager | proprietary | OpenWrt only | any |
| Cost | free | $300–500 / device | free | free |
| Quota-aware | yes (plugin) | no | no | no |
| Anti-flap & hysteresis | yes | yes | yes | usually broken |
| Last-resort failover | yes (opt-in) | no | no | no |
| Source you can read | ~8.5 kLOC Bash + Python, MIT | closed | C, kernel-tied | yours |

## Use Cases

**Perfect for:**

- Homelab routers with a DSL/fiber/cable primary uplink and an LTE/4G/5G backup modem.
- Self-hosters running Raspberry Pi OS (or any systemd + NetworkManager distro) as a gateway.
- Network engineers who want a readable, production-tested reference implementation of
  event-driven WAN failover.

**Not recommended for:**

- Enterprise edge with redundant upstream routers — use BGP or OSPF.
- Cloud-only setups without physical WAN hardware — there are no NetworkManager events to detect.
- Active-active load-balancing across two uplinks — this is active-passive failover only.

## Requirements

| Component | Minimum | Notes |
|-----------|---------|-------|
| Linux | any | Debian 12, Ubuntu 22.04+, Raspberry Pi OS Bookworm tested |
| systemd | 245+ | `RuntimeDirectory=`, `StateDirectory=`, `LogsDirectory=` used |
| Bash | 4.0+ | associative arrays required |
| NetworkManager + `nmcli` | any | for event-driven monitor; polling-only mode works without NM |
| `iproute2` (`ip`) | any | route manipulation |
| `iputils` (`ping`) | any | connectivity scoring |
| `bind9-utils` (`dig`) | any | DNS scoring |
| `curl` | any | HTTP scoring |
| Python | 3.10+ | metrics collector + LM1200 quota provider only |
| `sqlite3` | any | metrics history DB; optional if you only want Prometheus |

## Compatibility

| Distribution | Architecture | Status |
|---|---|---|
| Raspberry Pi OS Bookworm | aarch64 | Tested in production (8+ months) |
| Other systemd + NetworkManager distros | any | Expected to work, untested |
| Alpine Linux | any | Unsupported — no NetworkManager |
| OpenWrt | any | Unsupported — use mwan3 instead |

## How it works

Four cooperating systemd services:

```
┌────────────────────────────┐         ┌──────────────────────────────┐
│ nmcli-failover-monitor     │  USR1   │ failover-monitor             │
│ Event Detection (<500 ms)  │────────▶│ Orchestrator (polling 15-30s)│
│ parses `nmcli monitor`     │         │ Score-based 0-100 logic      │
│ writes lockfile            │         │ Switches default route       │
└────────────────────────────┘         └──────────────────────────────┘
                                                    │
                                                    │ writes active_wan
                                                    ▼
                                       ┌──────────────────────────────┐
                                       │ route-guardian               │
                                       │ Route enforcement (every 10s)│
                                       │ Cleans stale duplicates < 1s │
                                       │ Respects failover lockfile   │
                                       └──────────────────────────────┘
                                                    │
                                                    │ reads metrics
                                                    ▼
                                       ┌──────────────────────────────┐
                                       │ failover-metrics-collector   │
                                       │ Prometheus + SQLite history  │
                                       └──────────────────────────────┘
```

- **`nmcli-failover-monitor`** is the fast lane. NetworkManager emits a
  `disconnected` event for the WAN connection, and within 500 ms the monitor
  has confirmed the link is really down and signalled the orchestrator
  (`SIGUSR1`).
- **`failover-monitor`** is the slow lane. It runs a periodic scoring loop
  (latency, packet loss, DNS time, gateway reachability), applies anti-flap
  and hysteresis, and chooses the winner. It's also the orchestrator that
  the event lane signals.
- **`route-guardian`** is the cleanup crew. NetworkManager has a habit of
  re-adding routes you don't want; the guardian deletes duplicates within
  one second of them appearing.
- **`failover-metrics-collector`** is observability. Prometheus textfile
  output for Grafana, plus a SQLite event log you can query after an
  incident.

For the rationale behind splitting detection and orchestration, see
[`docs/explanation/why-dual-service.md`](docs/explanation/why-dual-service.md).

## Real-World Results

Running on a single hardware setup (Raspberry Pi 5, DSL primary + Netgear LM1200 LTE backup)
since August 2025:

| Metric | Value |
|--------|-------|
| Production runtime | 8+ months (Aug 2025 – Apr 2026) |
| Failover events recorded | 447 |
| Typical failover latency (event path) | 4–6 s |
| Typical failover latency (polling fallback) | 60–90 s |
| Failback failure rate | ~3× higher than failover failure rate |

The higher failback failure rate is a known asymmetry — the `route-guardian`'s
`emergency_restore_any_route` exists specifically to recover from failed failbacks.
See [`docs/explanation/anti-flapping.md`](docs/explanation/anti-flapping.md) for details.

## Key Concepts

### Metric demotion, not link toggling

Failover changes the Linux routing metric of the primary interface (`50 → 500`),
not the link state. The backup interface keeps its metric (`200`) and becomes the
lowest-metric default route. This means the primary interface stays up, DHCP leases
are preserved, and recovery is as simple as demoting the metric back.

### The lockfile is signalling, not locking

`/run/linux-dual-wan-failover/failover-in-progress.lock` is a coordination primitive
in `PID_TIMESTAMP` format. Its presence tells `route-guardian` not to clean up routes
during an active failover. It is not a mutex; there is only ever one writer per state file.
See [`docs/explanation/state-file-ownership.md`](docs/explanation/state-file-ownership.md).

### Asymmetric thresholds prevent flapping

The orchestrator uses a 20-point hysteresis gap: fail over when the primary drops below
60, fail back only when it recovers above 80. Combined with a consecutive-check requirement
(5 failures to trigger failover, 20 successes to trigger failback), this makes the system
immune to transient link-quality oscillations.

### Failback is more dangerous than failover

During failback, the active backup route is deleted before the primary route is confirmed.
If the primary-route add fails, the system briefly has zero default routes.
`route-guardian` runs on a tighter interval than `failover-monitor` precisely to catch
and recover from this window.

## Quick Start

```bash
git clone https://github.com/fidpa/linux-dual-wan-failover.git
cd linux-dual-wan-failover

# Install (creates /usr/local/lib/linux-dual-wan-failover, /etc/linux-dual-wan-failover, systemd units)
sudo ./install.sh

# Configure your interfaces and gateways
sudo cp config/examples/dual-wan-dsl-lte.conf /etc/linux-dual-wan-failover/failover.conf
sudo $EDITOR /etc/linux-dual-wan-failover/failover.conf
# At minimum, set: PRIMARY_IFACE, BACKUP_IFACE, PRIMARY_NM_CONNECTION, BACKUP_NM_CONNECTION

# Enable the services
sudo systemctl enable --now \
    failover-monitor.service \
    nmcli-failover-monitor.service \
    route-guardian.service \
    failover-metrics-collector.service

# Verify
systemctl is-active failover-monitor nmcli-failover-monitor route-guardian failover-metrics-collector
journalctl -u failover-monitor -f
```

For a five-minute walk-through with a fictional setup, see
[`docs/tutorial/01-quickstart.md`](docs/tutorial/01-quickstart.md).

## Configuration

All configuration lives in `/etc/linux-dual-wan-failover/failover.conf`. The
example file at `config/failover.conf.example` documents every variable;
representative settings:

```bash
# Interfaces (no defaults — you must set these for your setup)
PRIMARY_IFACE=eth0
BACKUP_IFACE=lte0

# NetworkManager connection names
PRIMARY_NM_CONNECTION="WAN-Primary"
BACKUP_NM_CONNECTION="LTE-Backup"

# Routing metrics
PRIMARY_METRIC_NORMAL=50
PRIMARY_METRIC_DEMOTED=500
BACKUP_METRIC=200

# Health-check targets
CHECK_IPS=("8.8.8.8" "1.1.1.1" "9.9.9.9" "208.67.222.222")

# Optional plugins
ALERTING_BACKEND=none           # none | mattermost | webhook
QUOTA_PROVIDER=none             # none | netgear-lm1200 | custom
```

See [`docs/reference/config.md`](docs/reference/config.md) for the full
reference.

## Plugins

The repo ships two plugin slots so you don't have to fork the core to
support your modem or chat platform.

### Alerting

```
plugins/alerting/
├── none.sh         # default: silent
├── mattermost.sh   # forwards to a Mattermost incoming webhook
└── webhook.sh      # generic POST to any URL
```

Selected via `ALERTING_BACKEND=mattermost` in `failover.conf`.

### Quota providers (backup-link data caps)

```
plugins/quota-providers/
├── no-op/             # default: no quota awareness
├── netgear-lm1200/    # reference implementation (Sierra Wireless D86)
└── custom-template/   # skeleton for your own modem
```

A quota provider runs as its own systemd timer, queries your modem (or your
ISP's customer portal, or anything else), and writes a JSON snapshot. The
failover scoring logic reads the snapshot and caps the backup-link score
when you're approaching your monthly quota — so you don't pay overage fees
for a flaky-but-not-dead primary.

See [`plugins/quota-providers/README.md`](plugins/quota-providers/README.md)
for the schema and how to write your own.

## Status

This is **v0.1.0-alpha**. Core failover and routing has been running in
production on a single hardware setup (Raspberry Pi 5 + DSL + Netgear LM1200)
for over a year, but the public release is a first sanitised cut.

Expect:

- Rough edges in the install path on non-Debian distros
- Limited modem/ISP plugin coverage (currently just LM1200)
- Documentation gaps; PRs welcome

See [`CHANGELOG.md`](CHANGELOG.md) and the GitHub issue tracker for the
roadmap.

## Documentation

- [Tutorial: Quickstart](docs/tutorial/01-quickstart.md) — 5 minutes, fictional setup
- [How-to: install from source](docs/how-to/install-from-source.md)
- [How-to: configure Mattermost alerting](docs/how-to/configure-mattermost.md)
- [How-to: configure quota tracking](docs/how-to/configure-quota-tracking.md)
- [How-to: debug a failover](docs/how-to/debug-failover.md)
- [How-to: safe failover testing](docs/how-to/safe-failover-testing.md)
- [Reference: config variables](docs/reference/config.md)
- [Reference: scoring algorithm](docs/reference/scoring.md)
- [Reference: Prometheus metrics](docs/reference/metrics.md)
- [Explanation: why event-driven](docs/explanation/why-event-driven.md)
- [Explanation: why two services for one job](docs/explanation/why-dual-service.md)
- [Explanation: state-file ownership](docs/explanation/state-file-ownership.md)

## Contributing

Bug reports, feature requests, and especially modem/ISP plugin
contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## See Also

- [bash-production-toolkit](https://github.com/fidpa/bash-production-toolkit) — Production Bash libraries (logging, secure file I/O, alerting) used by this project.
- [netgear-lm1200-sms-gateway](https://github.com/fidpa/netgear-lm1200-sms-gateway) — SMS gateway for the same modem family used by the reference quota plugin.
- [linux-monitoring-templates](https://github.com/fidpa/linux-monitoring-templates) — Prometheus/Grafana templates that pair with `failover-metrics-collector`.
- [mwan3 (OpenWrt)](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3) — The OpenWrt-native equivalent referenced in the comparison table.
- [Diataxis](https://diataxis.fr/) — The documentation framework these `docs/` follow.

## License

MIT — see [`LICENSE`](LICENSE).

This project draws on patterns from
[`bash-production-toolkit`](https://github.com/fidpa/bash-production-toolkit)
(MIT). If you bundle the toolkit into a derivative work, see
[`NOTICE`](NOTICE) for the attribution requirement.

## Author

Marc Allgeier ([@fidpa](https://github.com/fidpa))
