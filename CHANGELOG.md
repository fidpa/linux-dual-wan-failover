# Changelog

All notable changes to `linux-dual-wan-failover` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.1] — 2026-07-16

A field incident in the upstream deployment (a captured function's log line
corrupting a sed expression during a real DSL outage) prompted an audit of the
logging setup here — the code was clean, but the audit surfaced one latent
ordering bug:

### Fixed

- **`src/lib/common.sh`** — the logging defaults (`LOG_FILE`, `LOG_TO_JOURNAL`,
  `LOG_TO_STDOUT`) are now set **before** the toolkit's `logging.sh` is sourced.
  The toolkit initializes these variables with `:=` at source time, so the
  previous assignments after the `source` line were dead code — with the toolkit
  installed, `LOG_TO_STDOUT` silently ran as `true` while the code claimed a
  `false` default. The effective default is now an explicit, documented `true`:
  the systemd units use `StandardOutput=journal`, and stdout is the only path
  into the journal when the toolkit is loaded (the debug guide reads logs via
  `journalctl -u failover-monitor`). No behavior change — this pins the
  behavior the services have always relied on and keeps it stable against
  future toolkit default changes. User overrides via environment/EnvironmentFile
  are respected as before.

## [0.5.0] — 2026-06-29

Failover **Correlation-ID** (Event-ID) tracing. Every failover now carries a
single ID that travels through all four services and the metrics database, so a
single event can be reconstructed end-to-end — the distributed-tracing idea
applied to a four-service failover pipeline.

### Added

- **`src/lib/event-id.sh`** — mints/propagates/persists the failover Event-ID
  (`PID_TIMESTAMP`, identical to the lockfile format). `nmcli-failover-monitor`
  mints it at detection and writes `pending_failover_id` **before** the USR1
  signal (signal-safe: no I/O in the receiver's trap); `failover-monitor` adopts
  it in its main loop or mints fresh for health-check/failback/manual failovers;
  `routing.sh` publishes `last_failover_id` for the collector.
- **`src/tools/trace-failover.sh`** — operator CLI that reconstructs one failover
  from its Event-ID: the event-DB row (symptom) plus a time-merged service-log
  waterfall (cause). `--list`, `--last`, and a specific ID; device-agnostic paths
  overridable via `LOG_DIR` / `STATE_DIR` / `EVENTS_DB`. Installed to
  `${LIB_DIR}/tools/` by `install.sh`.
- **`event_id` column** on `failover_events` (idempotent `ALTER TABLE` migration;
  the web reader degrades gracefully to `NULL` against a not-yet-migrated DB).
- Web-UI event history gains a **Trace** column exposing the Event-ID, with a
  copy-ready `grep` command in the cell tooltip.
- New how-to: [`docs/how-to/trace-failover.md`](docs/how-to/trace-failover.md);
  new README "Key Concepts" section; CI lint coverage extended to `src/tools/`.

### Changed

- `nmcli-failover-monitor`, `failover-monitor`, `routing.sh` and `route-guardian`
  stamp `FAILOVER_EVENT_ID=<id>` into their structured/file logs at the failover
  lifecycle points (detection → orchestration → route change → guardian pause).
- The lockfile content is now the failover Event-ID. The on-disk format is
  unchanged (`PID_TIMESTAMP`), so `route-guardian`'s stale-detection still parses
  it — fully backward compatible.

## [0.4.1] — 2026-06-12

First live run of the v0.4.0 CI pipeline caught two runner-environment
issues in the new jobs themselves (the code checks all passed):

### Fixed

- **CI: logrotate gate failed with `unknown group 'failover-web'`.** The
  unit-verify step created the user with `wan-state` as primary group but
  never created a `failover-web` group, which the logrotate policy's
  `create 0644 failover-web failover-web` line requires. The step now
  creates both groups (matching the real `install.sh` semantics:
  dedicated primary group + `wan-state` supplementary).
- **CI: gitleaks flagged `.gitleaksignore` itself.** The v0.4.0 revision
  of the allowlist quoted the placeholder-credentials example verbatim in
  its own comment and thereby matched the `curl-auth-user` rule. The
  comment now describes the example without reproducing the matchable
  pattern, and a fingerprint covers the old blob that remains in git
  history. (The local pre-push scan had run before the file was
  committed, so the history scan never saw it — lesson: verify
  `gitleaks` against the actual commit, not the working tree.)

## [0.4.0] — 2026-06-12

Findings from a full code review of the upstream production deployment,
ported here. Three of the fixes concern paths that had **never worked** —
the unit tests mocked `subprocess.run`/route changes, so only a live
end-to-end test could expose them.

### Fixed

- **Emergency route recovery was a silent no-op.**
  `emergency_restore_any_route()` (routing.sh) called
  `check_interface_status()`, which is defined only in `route-guardian.sh`
  — a *different process*. Inside the orchestrator that meant
  `command not found`, both restore attempts were skipped, and the
  function always ended at "Could not restore any route". It now uses a
  local `_interface_link_up()` helper (`ip link` + sysfs carrier).

- **Web-UI config editor could never install.** The root helper
  (`install-failover-conf`) requires every line of the staged file to be
  a whitelisted integer tunable — but the staged file was the *full*
  `failover.conf`, whose non-whitelisted lines (interfaces, test targets,
  …) always failed validation. Fixed via the override design (see
  *Changed*).

- **sudo from the Web-UI was blocked by implicit `NoNewPrivileges`.**
  The unit's seccomp-implying hardening options
  (`SystemCallArchitectures`, `MemoryDenyWriteExecute`, …) force
  `NoNewPrivileges=yes` for non-root services, silently overriding the
  explicit `NoNewPrivileges=false` — every `sudo` call (config install,
  daemon restart) failed with "no new privileges". Those options are
  removed (the mount-based sandbox stays; escalation remains scoped to
  two commands via sudoers). `ReadWritePaths=/etc/<project>` is added
  because sudo children inherit the unit's mount namespace, where
  `ProtectSystem=strict` made `/etc` read-only for the root helper too.

- **Web-UI log could go permanently dead.** `RotatingFileHandler` from two
  gunicorn workers sharing one file is not multiprocess-safe: once the
  10 MB cap was hit, `doRollover()` failed on every record (observed
  upstream: 1076 logging errors in 3 days, log frozen). Additionally,
  gunicorn's `--access-logfile`/`--error-logfile` pointed at the *same*
  file as the app handler. Now: `WatchedFileHandler` + logrotate policy
  (`systemd/failover-web.logrotate`, installed by
  `install.sh --with-web-ui`); gunicorn logs to stderr → journald.

- **Route-guardian could fight an in-flight failover.** The lockfile
  (`/run/failover-in-progress.lock`) was only ever created by the nmcli
  *emergency* path — regular score-based/manual failovers ran without
  pausing the guardian, which could revert a fresh metric swap in the
  window before `active_wan` is persisted. `safe_route_change()` now
  creates the lock (PID_TIMESTAMP, 30 s hold with ownership check,
  immediate release on error). The guardian check also moved from
  `monitor_default_routes()` to the top of
  `comprehensive_route_health_check()`: duplicate-cleanup, NM-metric
  repair and conflict resolution also mutate routes and previously kept
  running during a failover.

- **USR1 "instant" failover could wait a full check interval.** Bash runs
  traps only after the current foreground command finishes, so a USR1
  arriving during `sleep 15` waited up to 15 s. The main loop now uses
  `sleep … & wait $!`, which returns immediately on any trapped signal —
  the same pattern route-guardian already used.

- **`systemctl stop route-guardian` ran into a 90 s timeout + SIGKILL.**
  The SIGTERM trap returned without ending the `while true` loop. A
  shutdown flag now ends the loop at the top of the next iteration.

- **Double rollback on route-change errors.** `safe_route_change()` had an
  ERR trap *in addition to* explicit `rollback_route_change` calls — on an
  empty gateway lookup both fired, the second against an already-deleted
  backup file, escalating into a false-positive "manual intervention
  required" cascade. The ERR trap is removed; the explicit error paths
  cover every failure mode.

- **Rollback could fail with "File exists".**
  `restore_routes_from_backup()` deleted only *one* default route before
  `ip route restore`; with both WAN routes present the restore collided
  with the remaining one. All default routes are removed first now.

- **nmcli fallback never found the daemon.** The `pgrep -f` fallback
  matched against the install path while the process cmdline shows the
  path systemd actually executed. On a stale PID file the trigger fell
  straight through to the raw emergency path. The emergency path also
  added the backup route with metric 100 — a pre-metric-demotion relic
  that created a duplicate route the guardian had to clean up. It now
  only adds the route if missing, with metric 200.

- **Dead DHCP-lease gateway fallback.** `get_gateway_from_dhcp()` parsed
  `/var/lib/dhcp/dhclient.<iface>.leases`, which never exists on
  NetworkManager systems (internal DHCP client). Replaced with
  `get_gateway_from_nm()` (`nmcli -g IP4.GATEWAY`).

- **Web test suite had a built-in time bomb.** The seeded history events
  used hardcoded dates that fall out of the default `days=30` query
  window; fixtures now seed relative to "now".

- **`diag` timeout now covers the whole run.** Previously it applied only
  to `proc.wait()` after the read loop — a slowly-dripping `traceroute`
  could stream for 60–90 s despite the 30 s limit.

### Changed

- **Config override design.** The Web-UI no longer patches
  `failover.conf`. Operator edits land in
  `/etc/<project>/failover-overrides.conf` (integer tunables only,
  root-validated), which the daemon sources *after* the base config
  (bash last-wins). The base config stays pristine; `GET /api/config`
  reports the effective (merged) values plus both paths.
  New env knob: `FAILOVER_WEB_OVERRIDE_CONFIG_PATH`.

- **`FAILOVER_THRESHOLD_DOWN` is now actually wired up.** The degraded
  threshold was hardcoded to 60 in three places; the config value (and
  the web UI field) had no effect. `CHECK_IPS`/`DNS_SERVERS` similarly
  no longer overwrite config-provided values.

- **Freshness thresholds match the collector cadence.** The shipped unit
  sets `FAILOVER_WEB_STATE_STALE_SECONDS=75` /
  `FAILOVER_WEB_STATE_MISSING_SECONDS=180` — with ~60 s prom writes the
  30 s default flagged "stale" in steady state.

- **gunicorn 25.x control socket**: the unit sets
  `HOME=/var/lib/failover-web` (the user's real home is read-only under
  `ProtectHome`, which produced a "Control server error" on every start).

### Added

- **CI: web-UI test suite finally runs in CI.** A new `pytest` job runs all
  136 tests on Python 3.10 (the documented floor) and 3.12 — none of the
  web-UI fixes in this release would have been caught by the previous
  pipeline, which never executed `src/web/tests/`.
- **CI: secret scanning.** `gitleaks` scans the full git history on every
  push/PR (`.gitleaksignore` carries the one audited false positive — the
  placeholder `admin:secret` example in the quota custom-template docs).
- **CI: config syntax gates.** `visudo -cf` for the sudoers fragment,
  `logrotate -d` for the new logrotate policy, and `bash -n` for the
  sourced config examples (a syntax error in `failover.conf` bricks the
  daemon at startup).

### Changed (CI)

- **The systemd unit check can actually fail now.** It previously ran
  `systemd-analyze verify || true` — a check that can never fail is a fake
  check. The job now stubs the `Exec*` binary paths referenced by the
  units (the only legitimately-missing pieces on a runner) and treats any
  remaining verify error as a hard failure.
- **ruff lints `src/web/`** (the two pre-existing unused-import findings
  are fixed in this release). `ruff format --check` stays scoped to the
  two standalone scripts — reformatting 31 web files wholesale would bury
  the diff history for zero behavioral gain.
- **shellcheck covers the full bash surface**: now also `install.sh`, the
  root-side config installer (`src/web/install-failover-conf.sh`), and the
  bats helpers/mocks.
- Workflow hygiene: `permissions: contents: read` (least privilege) and a
  concurrency group that cancels superseded runs.

### Removed

- **`FAILOVER_THRESHOLD_UP` / `HYSTERESIS_GAP`.** The daemon never
  evaluated either: failback is governed by `MIN_FAILBACK_SCORE` +
  `MIN_BACKUP_TIME` + `MIN_STABLE_DURATION`, and the score-hysteresis
  code path below the `MIN_FAILBACK_SCORE` gate was unreachable dead
  code (it required a score >90 on a path only reachable with <60).
  The web UI field is gone (a knob without effect fakes control);
  the config example keeps both names commented out as historical
  documentation. The dead branch in `is_failback_needed()` is removed —
  behavior is unchanged.

- Dead code: `restore_missing_backup_route()` (monitoring-only stub with
  inverted log logic, no callers), the events-module signal-handler
  remnants in `common.sh` (`setup_signal_handlers`,
  `handle_event_signal`, `graceful_shutdown`, `cleanup_temp_files` —
  they referenced functions that no longer exist), the always-zero
  performance-stats log line (its counters live in command-substitution
  subshells and can never accumulate; documented in `performance.sh`).

## [0.3.0] — 2026-06-10

### Fixed

- **Web-UI write path: `failover-web` could not write `manual_action.json`.**
  The `chgrp wan-state` on `/run/<project>/wan-state` ran inside the
  orchestrator unit's sandbox, where `CapabilityBoundingSet` drops
  `CAP_CHOWN` — so the group ownership silently stayed `root`, the
  group-writable bit was useless, and the dashboard's failback /
  force-failover buttons returned a write error. The `ExecStartPre`
  chgrp now uses the systemd `+` prefix to run with full privileges
  outside the sandbox, and the directory is `02775` (setgid) so
  `manual_action.json` inherits the `wan-state` group.

### Changed

- **Anti-flapping docs now match the implementation.** `ANTI_FLAPPING_DELAY`
  (600 s) is the cooldown for *failback and manual actions only* —
  score-based failover has no cooldown (it is covered by
  `FAILURE_THRESHOLD`, `MIN_BACKUP_TIME`, `MIN_STABLE_DURATION`, and the
  emergency exemption). Corrected the config-example comments,
  `docs/explanation/anti-flapping.md`, and a stale daemon log line that
  printed "300s cooldown" while enforcing 600 s.

## [0.2.0] — 2026-05-05

### Added

- **Optional Flask + gunicorn Web-UI** under `src/web/`. `install.sh
  --with-web-ui` provisions a dedicated `failover-web` system user (in
  group `wan-state`), a venv at `/usr/local/lib/.../web/venv`, and a
  `failover-web.service` systemd unit binding `127.0.0.1:8091`. The
  dashboard surfaces live state, latency / loss / DNS / HTTP metrics per
  interface, a 30-day failover-event table, three operator buttons
  (manual failback, force-failover, monitor restart), a whitelisted
  16-key config editor, and on-demand `ping` / `dig` / `traceroute` /
  `mtr` streamed via Server-Sent Events. Documentation lives at
  `docs/how-to/configure-web-ui.md`,
  `docs/reference/web-api.md`, and
  `docs/explanation/web-ui-architecture.md`.
- **`process_manual_action_request()` in `failover-monitor.sh`.** The
  orchestrator now polls `${RUNTIME_DIR}/wan-state/manual_action.json`
  once per main-loop iteration, validates the JSON payload (action,
  request_id, ts), enforces a 30 s freshness window and idempotency
  through `manual_action_processed_ids`, and dispatches to
  `perform_failover` with `manual_failback` / `manual_failover_force`
  reasons that bypass the score-based decision gates while still
  honouring `ANTI_FLAPPING_DELAY`. The function is a cheap `stat()`
  per loop iteration when the file is absent — installations without
  the Web-UI pay nothing.
- **`systemd/failover-web.{service,sudoers,tmpfiles,nginx.example}`.**
  Hardened systemd unit (gunicorn, 2 × 4 threads, full set of
  `Protect*` knobs), minimal sudoers fragment (`systemctl restart
  failover-monitor.service` + the root-owned config installer only),
  tmpfiles directives for `/var/lib/failover-web` and the audit log,
  and an nginx upstream sample with the X-Forwarded-For overwrite
  rule the source-IP extractor relies on.
- **Root-owned validating config installer.**
  `src/web/install-failover-conf.sh` re-validates every line of the
  staged `failover.conf` in root context against the same 16-key
  schema the web app enforces, then atomically renames it into
  `/etc/<project>/failover.conf`. Eliminates the
  attacker-controlled-source LPE class that any "sudo cp" rule would
  expose.
- **Alerting plugin dispatcher** (`src/web/alerts/dispatcher.py`).
  The Web-UI shares the same `send_alert <type> <message>` plugin
  contract documented in `plugins/alerting/README.md` — `none`,
  `mattermost`, `webhook`, or any custom plugin work without code
  changes. Default backend is `none` (silent).
- **`failover.conf.example` Web-UI block** with commented-out
  `FAILOVER_WEB_CSRF_HOSTS`, `FAILOVER_WEB_LABEL_PRIMARY`,
  `FAILOVER_WEB_LABEL_BACKUP`, and `FAILOVER_WEB_PROM_URL` so operators
  can tune the dashboard without grepping for env-var names.

### Changed

- **`failover-monitor.service` provisions the `wan-state` subdirectory**
  with mode `0775` and group `wan-state` via `ExecStartPre=`. The
  `chgrp` is best-effort (the leading `-` makes it no-op when the group
  doesn't exist), so an install without the Web-UI keeps the previous
  semantics. Restart `failover-monitor.service` once after installing
  the Web-UI so the group flips into place.

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
  - two `while …; do true; done` patterns rewritten to multi-line form),
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

[Unreleased]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/fidpa/linux-dual-wan-failover/releases/tag/v0.1.0
