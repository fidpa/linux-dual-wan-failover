# Changelog

All notable changes to `linux-dual-wan-failover` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] — 2026-05-02

### Fixed

- **`_backup_quota_cap()` returned non-zero when no cap applied.** The
  function ended in `[[ -n "$result" ]] && echo "$result"`, leaving exit
  code 1 whenever the snapshot percentage was below the lowest tier
  (e.g. 87 %) or `limit_pct` was `null`. Callers running under `set -e`
  would abort. An explicit `return 0` now follows the conditional echo
  so the empty-output path is a clean success. (`src/lib/performance.sh`)

- **DNS test asymmetric-routing bug (DoH migration).** All DNS health checks
  used `dig @8.8.8.8 -b $iface_ip` to "bind" to a specific interface. `dig
  -b` only sets the source IP — it does **not** force the outgoing
  interface. When the primary uplink was demoted (higher metric), the
  kernel's destination-based routing sent DNS packets out via the active
  backup with the primary's source IP, ISPs filtered the asymmetric flow,
  and the test reported a 999 ms timeout for a perfectly healthy primary.
  This blocked failback indefinitely: `_end_to_end_penalty` deducted 25
  points, `test_dns_score` returned 0 instead of 25, the recovery counter
  could never reach its threshold, and the orchestrator stayed pinned to
  the backup. Reproduced live: `dig @8.8.8.8 -b $primary_ip` timed out
  while `curl --interface $primary` answered in <100 ms.

  - `lib/network.sh` — new `measure_dns_doh()` helper that uses `curl
    --interface` (real `SO_BINDTODEVICE` binding) against `dns.google` and
    `cloudflare-dns.com` over DoH (DNS-over-HTTPS), with `--resolve`
    bootstrap on multiple IPs to bypass any system-resolver dependency.
    Response is validated against HTTP 200 + JSON `Status==0` (NOERROR per
    RFC 8484 / Google JSON-API) + `Answer.length>=1`, which also rejects
    captive-portal 200 responses. Old `dig -b` body kept inside a private
    `_measure_dns_dig_legacy()` function for emergency rollback.
  - `lib/network.sh` — `measure_dns_performance`, `measure_dns_time`,
    `test_dns_server`, `measure_dns_detailed` all migrated to call
    `measure_dns_doh`. The nslookup fallback in `test_dns_server` was
    removed because it was a false positive: it ignored the interface
    argument and answered via the active default route, so the backup
    always appeared "DNS-OK" even when source-bound dig had timed out.
    The ISP resolver in `measure_dns_detailed` was dropped (does not speak
    DoH); its SQLite column is now NULL for new rows.
  - `lib/performance.sh` — `test_dns_score` migrated to `measure_dns_doh`.
  - `config/failover.conf.example` — new `DNS_TEST_METHOD=doh|dig` flag.
    Default `doh` (fixes the bug). Set to `dig` for soft rollback.

  Live-verified: failback succeeded within minutes of the deploy; DNS
  latency in `wan_quality.prom` dropped from 999/1500 ms to 80–200 ms.

### Changed

- **`CPUQuota` defaults raised** for all four services. The previous values
  (5–20 %) were tight enough to throttle the bursty subprocess work
  (`ping`, DoH `curl`, `jq`) by 80–98 % on a 4-core Pi 5, even though
  absolute CPU usage was only a few percent. The throttling distorted the
  numbers the metrics collector wrote into `wan_quality.prom` by an order
  of magnitude, which in turn fed back into the orchestrator's end-to-end
  penalty and blocked failback. The bug was only visible because the DoH
  fix exposed how unrealistic the cgroup-throttled measurements were.
  - `failover-metrics-collector.service`: 10 % → 50 % (subprocess-heavy)
  - `route-guardian.service`: 10 % → 50 % (real-time safety net, dense bursts)
  - `failover-monitor.service`: 50 % → 75 % (parallel scoring rounds)
  - `nmcli-failover-monitor.service`: 20 % → 50 % (event handling)
  Each service file now carries an inline comment explaining why; on a
  dedicated router box you can drop `CPUQuota` entirely. `MemoryMax` is
  unchanged — it remains useful as a leak guard.

- **Anti-stall safety net (3-layer)** for the rare edge case where the
  primary loses Layer-1 carrier (cable unplugged, modem powered off) at the
  same time the backup score sits exactly at the "both interfaces degraded"
  threshold (e.g. 25, hit by the end-to-end DNS penalty during an LTE
  throttling window). In that combination, every existing score-based
  failover path classified the backup as "not viable" and `both_degraded`
  pinned the orchestrator on a dead primary, leaving the routing table
  without a default route. Three coordinated patches:

  - `failover-monitor.sh` — **carrier-aware pre-check** in
    `check_failover_conditions()`. When primary `carrier=0`, backup
    `carrier=1`, and backup score > 0 (not quota-blocked), trigger an
    unconditional failover before any score-based path runs. Layer-1
    state is binary and unambiguous, so it overrides the heuristics.
    The score>0 guard preserves the `LAST_RESORT` quota-cap protection.

  - `lib/routing.sh` — **carrier-aware short-circuit in
    `_swap_primary_metric()`**. The metric demotion (`ip route add default
    ... metric 500`) fails with "Network is unreachable" when primary
    carrier=0, which then trips `safe_route_change()` rollback and
    emergency recovery, all of which fail too. Fix: keep the
    NetworkManager metric persist in Step 1 (applied on the next DHCP
    cycle), skip the kernel route add when carrier=0, defensively clean
    up stale routes, and return success. The kernel auto-prefers the
    backup since there is no competing primary route.

  - `route-guardian.sh` — **default-route vacuum detection** as
    independent safety net. After the regular DSL/LTE checks, if
    `total_default_routes == 0`, restore via the backup (preferred when
    primary is Layer-1 dead) or the primary (fallback) and send a
    `ROUTE_VACUUM_RECOVERED` alert. Lockfile coordination unchanged, so
    no race with the orchestrator during legitimate failovers.

  Together these form a defense-in-depth chain (detect → execute →
  safety net). Live-verified against a real DSL outage where the
  pre-check fired and the routing-library short-circuit was needed to
  actually let it succeed.

### Internal

- **CI green across all jobs.** Resolved `bashate` (trailing whitespace
  + two `while …; do true; done` patterns rewritten to multi-line form),
  `ruff check` (unused `time` import, two f-strings without placeholders)
  and `ruff format`, and `shellcheck` warnings (`unset` array-key
  quoting in `lib/performance.sh`, declare/assign separation and
  trap-quote disable in `lib/routing.sh`, `# shellcheck disable=SC2034`
  annotations for public-API constants consumed by sourcing scripts).
  No behavioural changes from these — the only behaviour change in this
  release is the `_backup_quota_cap()` return-code fix above.
- **`bats` suite fully green.** Tests 12 and 17 in
  `tests/unit/test_quota.bats` were red as a symptom of the
  `_backup_quota_cap()` bug; with the fix above the full suite is
  23/23.

## [0.1.0] — 2026-04-27

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

[Unreleased]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/fidpa/linux-dual-wan-failover/releases/tag/v0.1.0
