# Linux Dual-WAN Failover

![CI](https://github.com/fidpa/linux-dual-wan-failover/actions/workflows/ci.yml/badge.svg)
![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=gnu-bash)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Bash 4.0+](https://img.shields.io/badge/Bash-4.0%2B-blue?logo=gnu-bash)
![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-blue?logo=python)
![Release](https://img.shields.io/github/v/tag/fidpa/linux-dual-wan-failover?label=release&sort=semver)
![Status: Beta](https://img.shields.io/badge/Status-Beta-yellow.svg)

**Sub-10s WAN failover for Linux dual-WAN routers, driven by NetworkManager events.**

> Detect a dead primary uplink within a five-second confirmation window, switch
> to the backup without dropping established connections, clean up the stale
> routes NetworkManager leaves behind, and recover automatically when the
> primary comes back. All in pure Bash plus a Python metrics collector, on a
> Linux box with `systemd` and `iproute2`.

## Why this exists

If you self-host a Linux router/gateway with a primary uplink (DSL, fiber,
cable, second wired ISP) plus a backup uplink (LTE/4G/5G modem, second WAN),
you've probably hit one of these problems:

- **`pfSense` / `UniFi UDM`** are mature and well-tested, but they want to own
  the whole router. Bolting one onto an existing Linux box is not the intended
  shape, and consumer LTE modems are a recurring sore spot.
- **`mwan3` (OpenWrt)** is good but tied to OpenWrt's network stack, which
  makes it hard to integrate on a standard Linux box.
- **`keepalived` / `VRRP`** is for active-active HA between _routers_, not
  for steering a single router between two upstream uplinks.
- **Manually scripting it** with `ping` + `ip route` works until the first
  flapping link, where you discover anti-flap, hysteresis, race conditions
  with NetworkManager, and stale `conntrack` state.

This project is what fell out of running a homelab dual-WAN setup (DSL
primary, LTE backup) since August 2025 and writing down every pitfall.

## Comparison

The numbers below describe each project's *default* configuration, taken from
its own documentation. Only the first column is measured here (see
[Real-World Results](#real-world-results)); the others are not, and all of them
can be tuned.

| | linux-dual-wan-failover | pfSense / UniFi | mwan3 (OpenWrt) | DIY shell script |
|---|---|---|---|---|
| Failover time | 4 to 6 s (event-driven) | 30 to 60 s (polling) | 5 to 15 s | depends |
| Linux distro | systemd + NetworkManager | ships its own OS | OpenWrt only | any |
| Cost | free | pfSense CE free, UniFi is hardware | free | free |
| Quota-aware | yes (plugin) | no | no | no |
| Anti-flap and hysteresis | yes | yes | yes | usually broken |
| Last-resort failover | yes (opt-in) | no | no | no |
| Source you can read | Bash + Python, MIT | pfSense CE Apache-2.0, UniFi closed | shell, GPL, OpenWrt-tied | yours |

## Use Cases

**Perfect for:**

- Homelab routers with a DSL/fiber/cable primary uplink and an LTE/4G/5G backup modem.
- Self-hosters running Raspberry Pi OS (or any systemd + NetworkManager distro) as a gateway.
- Network engineers who want a readable, production-tested reference implementation of
  event-driven WAN failover.

**Not recommended for:**

- Enterprise edge with redundant upstream routers. Use BGP or OSPF.
- Cloud-only setups without physical WAN hardware: there are no NetworkManager events to detect.
- Active-active load-balancing across two uplinks. This is active-passive failover only.

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
| Raspberry Pi OS Bookworm | aarch64 | Tested in production (since August 2025) |
| Other systemd + NetworkManager distros | any | Expected to work, untested |
| Alpine Linux | any | Unsupported: no NetworkManager |
| OpenWrt | any | Unsupported, use mwan3 instead |

## How it works

Four cooperating systemd services:

```
┌────────────────────────────┐         ┌──────────────────────────────┐
│ nmcli-failover-monitor     │  USR1   │ failover-monitor             │
│ Link-down poll every 500 ms│────────▶│ Orchestrator: polls every 15s│
│ parses `nmcli monitor`     │         │ Score-based 0-100 logic      │
│ writes lockfile            │         │ Switches default route       │
└────────────────────────────┘         └──────────────────────────────┘
                                                    │
                                                    │ writes active_wan
                                                    ▼
                                       ┌──────────────────────────────┐
                                       │ route-guardian               │
                                       │ Route enforcement (every 10s)│
                                       │ Removes duplicate routes     │
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
  `disconnected` event for the WAN connection; the monitor then polls
  `ip link` every 500 ms until the interface has really left `state UP`, and
  signals the orchestrator (`SIGUSR1`). If the link comes back before the
  five-second timeout, the event is written off as a false alarm and no
  failover happens.
- **`failover-monitor`** is the slow lane. It runs a scoring loop every
  `CHECK_INTERVAL` seconds (latency, packet loss, DNS time, gateway
  reachability), applies anti-flap and the failback gating below, and chooses
  the winner. It's also the orchestrator that the event lane signals.
- **`route-guardian`** is the cleanup crew. NetworkManager has a habit of
  re-adding routes you don't want; the guardian sweeps the routing table every
  `ROUTE_GUARDIAN_CHECK_INTERVAL` seconds (10 s by default) and deletes the
  duplicates it finds in that same pass, unless a failover is in progress.
- **`failover-metrics-collector`** writes Prometheus textfile output for
  Grafana plus a SQLite event log you can query after an incident.

For the rationale behind splitting detection and orchestration, see
[`docs/explanation/why-dual-service.md`](docs/explanation/why-dual-service.md).

## Real-World Results

Measured on one hardware setup: a Raspberry Pi 5 with a DSL primary and a
Netgear LM1200 LTE backup, in continuous use since August 2025. These are
single-deployment numbers, not a benchmark across hardware.

| Metric | Value |
|--------|-------|
| Production runtime | 12 months (August 2025 to August 2026) |
| Failover events recorded | 447 (event DB, August 2025 through April 2026) |
| Typical failover latency (event path) | 4 to 6 s |
| Typical failover latency (polling fallback) | 60 to 90 s |

Failbacks fail noticeably more often than failovers on this deployment, which
is why `route-guardian` carries an `emergency_restore_any_route` path at all.
The reason is structural rather than statistical, and it is spelled out under
[Failback is more dangerous than failover](#failback-is-more-dangerous-than-failover).
See [`docs/explanation/anti-flapping.md`](docs/explanation/anti-flapping.md)
for the full write-up.

## Key Concepts

### Metric demotion, not link toggling

Failover changes the Linux routing metric of the primary interface (`50` to
`500`), not the link state. The backup interface keeps its metric (`200`) and
becomes the lowest-metric default route. This means the primary interface stays
up, DHCP leases are preserved, and recovery is as simple as demoting the metric
back.

### The lockfile is signalling, not locking

`/run/failover-in-progress.lock` is a coordination primitive in `PID_TIMESTAMP`
format, written by `routing.sh::safe_route_change` on every route change (and by
`nmcli-failover-monitor` on the emergency path). Its presence tells
`route-guardian` not to clean up routes during an active failover. It is not a
mutex; there is only ever one writer per state file.
See [`docs/explanation/state-file-ownership.md`](docs/explanation/state-file-ownership.md).

### Every failover has a Correlation-ID

A failover crosses four services (`nmcli-failover-monitor` to
`failover-monitor` to `routing.sh` to `route-guardian`) plus the metrics
collector. Each event gets one **Event-ID**, the `PID_TIMESTAMP` lockfile
content, minted at the earliest detection point and handed across the
USR1/lockfile boundaries.

It is stamped into every service log as `FAILOVER_EVENT_ID=<id>` and written to
the `event_id` column of the events database. This is the same idea as a
distributed-tracing trace ID: it turns per-service logs that each see only their
own slice into one reconstructable timeline.

Trace a single failover end-to-end, from the symptom (a DB row) to the cause (a
service-log waterfall), with:

```bash
src/tools/trace-failover.sh --list 10   # recent events with their Event-IDs
src/tools/trace-failover.sh <PID_TIMESTAMP>
```

See [`docs/how-to/trace-failover.md`](docs/how-to/trace-failover.md).

### Failing over is cheap, failing back is gated

The two directions are deliberately asymmetric. A failover fires once the
primary scores below `FAILOVER_THRESHOLD_DOWN` (60) for `FAILURE_THRESHOLD` (5)
consecutive checks, which at a 15 s `CHECK_INTERVAL` is about 75 s of
tolerance. An emergency score below `EMERGENCY_THRESHOLD` (15) skips the
counter entirely.

Failback has to clear four independent gates, all of them at their default
values here:

| Gate | Default | Meaning |
|---|---|---|
| `RECOVERY_THRESHOLD` | 20 | consecutive healthy checks, about 5 min |
| `MIN_BACKUP_TIME` | 3600 s | minimum time on the backup after a failover |
| `MIN_STABLE_DURATION` | 900 s | uninterrupted primary stability |
| `MIN_FAILBACK_SCORE` | 60 | primary score at the moment of the decision |

Any primary score below `FAILOVER_THRESHOLD_DOWN` restarts the stability
window, so a flapping link never accumulates the 900 s it needs. That is where
the anti-flapping behaviour comes from: not from a score gap, but from a time
gate that a flapping link cannot satisfy.

Earlier releases documented a 20-point hysteresis gap
(`FAILOVER_THRESHOLD_UP=80`, `HYSTERESIS_GAP=20`). That path was unreachable:
it required a primary score above 90, but the `MIN_FAILBACK_SCORE` gate above
it already returned for every score of 60 or more. It was removed, and both
variables survive only as commented-out documentation in
`config/failover.conf.example`. Neither is read anywhere in the daemon, which
you can check for yourself:

```bash
grep -rn 'FAILOVER_THRESHOLD_UP\|HYSTERESIS_GAP' src/services/ src/lib/   # no output
```

If you have them set in an existing config, they do nothing.

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
example file at `config/failover.conf.example` documents every variable with
its default and the reasoning behind it; representative settings:

```bash
# Interfaces (no defaults, you must set these for your setup)
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

# Failback gating (see "Failing over is cheap, failing back is gated")
MIN_FAILBACK_SCORE=60
MIN_BACKUP_TIME=3600
MIN_STABLE_DURATION=900

# Optional plugins
ALERTING_BACKEND=none           # none | mattermost | webhook
QUOTA_PROVIDER=none             # none | netgear-lm1200 | custom
```

See [`docs/reference/config.md`](docs/reference/config.md) for the full
reference.

## Web-UI

If you want operator buttons (manual failback / force-failover) plus
on-demand `ping` / `dig` / `traceroute` / `mtr` and a config editor in
a browser, install the Flask + gunicorn dashboard:

```bash
sudo ./install.sh --with-web-ui
```

This adds a `failover-web.service` that binds to `127.0.0.1:8091`. Sit
your reverse proxy in front of it (the repo ships
[`systemd/failover-web.nginx.example`](systemd/failover-web.nginx.example)
as a starting point), point your browser at it, and you have:

- live state, latency, loss, jitter, DNS/HTTP scores per interface;
- failover event history from the metrics SQLite DB, read-only, 30 days by
  default, with a **Trace** column exposing each event's Correlation-ID for
  cross-service tracing;
- whitelisted config tuning (15 keys, range-validated, root-owned installer
  re-validates before write);
- a per-(endpoint, source-IP) rate limit, CSRF plus Origin/Referer check,
  JSON-Lines audit log, and alerting on every mutation through the same plugin
  contract as the daemon. The limits differ by how expensive the action is:
  `/api/failback` is 1 per 60 s, `force-failover` 1 per 120 s, a monitor
  restart 1 per 300 s.

> [!IMPORTANT]
> **The dashboard has no login screen, and that is a deliberate trade, not an
> oversight.** Its security rests on the reverse proxy in front of it: the
> Flask process binds to `127.0.0.1` only, and anyone who reaches the proxy
> reaches the operator buttons. The CSRF check, the rate limits and the audit
> log raise the cost of an attack from inside that perimeter, but they are not
> the perimeter. If your deployment is multi-tenant, internet-exposed, or on a
> LAN you don't trust, terminate authentication in the proxy (mTLS, SAML, basic
> auth); the web app's only contract with it is
> `X-Forwarded-For = $remote_addr`. The reasoning is laid out in
> [`docs/explanation/web-ui-architecture.md`](docs/explanation/web-ui-architecture.md).

The Web-UI is opt-in. If you don't install it, the daemon's
`process_manual_action_request` is a cheap `stat()` per loop iteration
when the trigger file is absent. See
[`docs/how-to/configure-web-ui.md`](docs/how-to/configure-web-ui.md) for
setup and [`docs/reference/web-api.md`](docs/reference/web-api.md) for the
endpoint surface.

## Plugins

The repo ships two plugin slots so you don't have to fork the core to
support your modem or chat platform.

### Alerting

```
plugins/alerting/
├── README.md       # the plugin contract
├── none.sh         # default: silent
├── mattermost.sh   # forwards to a Mattermost incoming webhook
└── webhook.sh      # generic POST to any URL
```

Selected via `ALERTING_BACKEND=mattermost` in `failover.conf`.

### Quota providers (backup-link data caps)

```
plugins/quota-providers/
├── README.md          # snapshot schema and provider contract
├── _schema/           # JSON Schema for the snapshot file
├── no-op/             # default: no quota awareness
├── netgear-lm1200/    # reference implementation (Sierra Wireless D86)
└── custom-template/   # skeleton for your own modem
```

A quota provider runs as its own systemd timer, queries your modem (or your
ISP's customer portal, or anything else), and writes a JSON snapshot. The
failover scoring logic reads the snapshot and caps the backup-link score
when you're approaching your monthly quota, so you don't pay overage fees
for a flaky-but-not-dead primary.

See [`plugins/quota-providers/README.md`](plugins/quota-providers/README.md)
for the schema and how to write your own.

## Status

**Beta.** The current release is tagged in
[`CHANGELOG.md`](CHANGELOG.md); the latest tag is shown in the release badge
above. Core failover and routing has been running in production on the single
deployment described under [Real-World Results](#real-world-results) since
August 2025, and every release since the first public cut has been driven by
findings from it. The changelog entries are incident write-ups, not feature
lists.

The version is still `0.x`: the config surface and the on-disk contracts may
change between minor releases. Breaking changes and migrations are called out
under *Upgrade notes* in the changelog.

Expect:

- Rough edges in the install path on non-Debian distros
- Limited modem/ISP plugin coverage (currently just LM1200)
- Documentation gaps

See [`CHANGELOG.md`](CHANGELOG.md) and the GitHub issue tracker for the
roadmap.

## Documentation

- [Tutorial: Quickstart](docs/tutorial/01-quickstart.md), 5 minutes, fictional setup
- [How-to: install from source](docs/how-to/install-from-source.md)
- [How-to: configure Mattermost alerting](docs/how-to/configure-mattermost.md)
- [How-to: configure quota tracking](docs/how-to/configure-quota-tracking.md)
- [How-to: configure the Web-UI](docs/how-to/configure-web-ui.md)
- [How-to: debug a failover](docs/how-to/debug-failover.md)
- [How-to: trace one failover by Correlation-ID](docs/how-to/trace-failover.md)
- [How-to: safe failover testing](docs/how-to/safe-failover-testing.md)
- [Reference: architecture overview](docs/reference/architecture-overview.md)
- [Reference: config variables](docs/reference/config.md)
- [Reference: scoring algorithm](docs/reference/scoring.md)
- [Reference: Prometheus metrics](docs/reference/metrics.md)
- [Reference: Web-UI HTTP API](docs/reference/web-api.md)
- [Explanation: anti-flapping and hysteresis](docs/explanation/anti-flapping.md)
- [Explanation: why event-driven](docs/explanation/why-event-driven.md)
- [Explanation: why two services for one job](docs/explanation/why-dual-service.md)
- [Explanation: state-file ownership](docs/explanation/state-file-ownership.md)
- [Explanation: Web-UI architecture](docs/explanation/web-ui-architecture.md)

## Contributing

Bug reports, feature requests, and especially modem/ISP plugin
contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## See Also

- [bash-production-toolkit](https://github.com/fidpa/bash-production-toolkit): production Bash libraries (logging, secure file I/O, alerting) used by this project.
- [netgear-lm1200-sms-gateway](https://github.com/fidpa/netgear-lm1200-sms-gateway): SMS gateway for the same modem family used by the reference quota plugin.
- [linux-monitoring-templates](https://github.com/fidpa/linux-monitoring-templates): Prometheus/Grafana templates that pair with `failover-metrics-collector`.
- [mwan3 (OpenWrt)](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3): the OpenWrt-native equivalent referenced in the comparison table.
- [Diataxis](https://diataxis.fr/): the documentation framework these `docs/` follow.

## License

MIT, see [`LICENSE`](LICENSE).

This project draws on patterns from
[`bash-production-toolkit`](https://github.com/fidpa/bash-production-toolkit)
(MIT). If you bundle the toolkit into a derivative work, see
[`NOTICE`](NOTICE) for the attribution requirement.

## Author

Marc Allgeier ([@fidpa](https://github.com/fidpa))
