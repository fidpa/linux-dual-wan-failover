# Changelog

All notable changes to `linux-dual-wan-failover` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0-alpha] — 2026-04-27

First public alpha cut, extracted from a private homelab dual-WAN failover
stack that has been running in production since 2025-08.

### Added

- **Four-service architecture**: `failover-monitor`, `nmcli-failover-monitor`,
  `route-guardian`, `failover-metrics-collector`.
- **Event-driven detection** via `nmcli monitor` with sub-second `SIGUSR1`
  hand-off to the orchestrator. Polling fallback for environments without
  NetworkManager state changes.
- **Score-based health checks** (0–100 per interface) combining latency,
  packet loss, DNS resolution time, and gateway reachability.
- **Anti-flap & hysteresis** with separate failover and failback thresholds,
  minimum backup-link dwell time, and stable-duration gating.
- **Route guardian** that enforces metric correctness based on
  `active_wan` ground truth (sub-second cleanup of duplicate routes).
- **Lockfile coordination** (`PID_TIMESTAMP` format) preventing the route
  guardian from racing the failover orchestrator during emergency switches.
- **Plugin slots**:
  - `plugins/alerting/`: `none`, `mattermost`, `webhook`.
  - `plugins/quota-providers/`: `no-op`, `netgear-lm1200`, `custom-template`.
- **Prometheus textfile output** + SQLite event history for after-the-fact
  incident analysis.
- **Diataxis documentation**: tutorial, how-to, reference, explanation.
- **Tests**: `bats-core` unit tests with `tests/mocks/` for `ip`, `nmcli`,
  `ping`.
- **CI**: `shellcheck`, `bashate`, `bats`, `ruff`.

### Notes

This release tag is `0.1.0-alpha` rather than `0.1.0` because it has not yet
been validated outside the original homelab environment. The `0.1.0` tag
will follow once the install path has been confirmed on at least one
additional setup beyond the original homelab (Raspberry Pi OS).

[Unreleased]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.1.0-alpha...HEAD
[0.1.0-alpha]: https://github.com/fidpa/linux-dual-wan-failover/releases/tag/v0.1.0-alpha
