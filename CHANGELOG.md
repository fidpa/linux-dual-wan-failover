# Changelog

All notable changes to `linux-dual-wan-failover` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] — 2026-08-08

Four processes mutate the same routing table, and until now nothing actually
stopped them from doing it at the same time. The `failover-in-progress` marker
looked like it did — route-guardian checks it and skips its cycle — but the check
happens once, at the top, and the guardian keeps changing routes for the rest of
that cycle. A failover starting a few milliseconds after the check runs entirely
inside the guardian's window, and the guardian then restores the old metric or
removes the new route as a duplicate, working from state it read before the swap.

This release adds a real `flock` underneath the marker, and fixes three latent
bugs found while auditing the same code paths — latent in the precise sense that
each one is currently masked by an unrelated implementation detail, and would
start firing the moment that detail changed.

None of this was prompted by an incident. It came out of a review of the failover
implementation, which is worth saying plainly: the marker had been described in
this project's own documentation as sufficient, with an argument
(`docs/explanation/state-file-ownership.md`) that was internally consistent and
still wrong. It reasoned about contention over the *file*, where the contention
is over the *routing table*.

### Added

- **A real mutual-exclusion lock, `/run/failover-route.lock`.** Held with `flock`
  on a fixed descriptor. The orchestrator holds it across its whole route
  transaction; route-guardian and the nmcli emergency path take it around each
  `ip route` call. The guardian skips its repair rather than waiting when it
  cannot get the lock.

  The marker file is deliberately kept. It still does the 30-second settle window
  against NetworkManager DHCP stragglers and still carries the failover event id
  that `trace-failover` correlates on. The `flock` is the fine-grained net
  underneath it, not a replacement — and unlike the marker it needs no stale
  detection, because the kernel releases it when the holder dies.

  Two constraints shaped the implementation and are stated as rules in the code:
  regions contain no forks, because `flock` lives on the open file description
  and a `send_alert … &` child inherits it; and delete-then-re-add sits inside one
  region, because locking only the add would let the lock change hands in between
  and leave an interface with no default route at all.

### Fixed

- **`active_wan` is translated on read.** The file holds interface names
  (`eth0`/`lte0`) because route-guardian, `routing.sh`, the metrics collector and
  the shell aliases all expect them. The restart path loaded that value verbatim
  into `current_wan`, where every guard compares against `primary`/`backup`.
  Currently harmless only because `RuntimeDirectory=` wipes the state directory on
  every restart, so the detection branch runs instead — set
  `RuntimeDirectoryPreserve=restart`, an otherwise sensible change, and failback
  plus every manual action go silently dead.
- **An instant failover no longer fires while already on backup.** Every branch of
  the USR1 handler switches primary → backup unconditionally. A second primary
  event after the 60 s instant cooldown re-ran the whole transaction and rewrote
  `last_failover_to_backup`, restarting `MIN_BACKUP_TIME` from zero. The guard
  sits after the both-degraded branch so that alert still fires while on backup.
- **Stale packet loss no longer triggers instant failovers.** `get_interface_packet_loss`
  read `wan_quality.prom` with no age check, unlike every other consumer of that
  file. The value feeds `is_critical_packet_loss`, which bypasses
  `FAILURE_THRESHOLD` — so a frozen collector reading kept forcing immediate
  failovers long after the link had recovered. It now honours
  `WAN_QUALITY_PROM_MAX_AGE` and falls back to live measurement.
- **The emergency path checks ownership before removing the marker.** Its success
  path did; its failure path removed whatever marker happened to be there,
  re-arming route-guardian in the middle of somebody else's transaction.
- **Route repair is rate-limited per interface.** One shared marker meant that
  when both default routes went missing at once — a NetworkManager restart does
  this — repairing the primary locked out repairing the backup for 60 seconds,
  which is exactly the window where the backup path matters.

### Changed

- **`EMERGENCY_FAILBACK_DEGRADED_CHECKS` counts readings, not rounds; default
  20 → 6.** The counter advanced once per orchestrator cycle (15 s) while the DNS
  value it reads is refreshed every ~36–52 s, so the same sample was counted up to
  four times and a single outlier could reach the threshold on its own. The 20
  from 0.6.0 was a workaround for exactly this, chosen to approximate six
  independent samples. The counter now advances only when `wan_quality.prom` has
  actually been rewritten, so the value means what it says. Both defaults encode
  the same intent — roughly five minutes of evidence.
- **Network timeouts are assignable instead of `readonly`.** `PING_TIMEOUT`,
  `DNS_TIMEOUT` and `HTTP_TIMEOUT` were declared `readonly` in `network.sh`, which
  silently overwrote anything the operator set: the units pass `failover.conf`
  through `EnvironmentFile`, so those values arrive as environment variables
  before the script runs. Setting `PING_TIMEOUT=7` in your config had no effect
  and produced no warning. Defaults are unchanged (2/3/5), so runtime behaviour is
  identical — the setting simply works now.

  Note before raising it: `PING_TIMEOUT` acts as a multiplier, not just a wrapper.
  `measure_packet_loss` caps at `PING_TIMEOUT × count` and `measure_path_quality`
  at `samples + PING_TIMEOUT × 2`, both of which push against the metrics
  collector's 30 s subprocess budget.

## [0.7.1] — 2026-08-03

The orchestrator had been announcing `Failover Monitor v0.1.1` on every start
since May — nine releases of drift, because `failover-monitor.sh` carried its own
`readonly SCRIPT_VERSION="0.1.1"` literal that nobody bumped alongside the tag.
A journal that names a version which has not existed for months cannot answer
the first question of any incident review: which code is actually running on
this box?

An audit of the documentation against the code, prompted by the same review,
turned up a wrong path in the stale-lock recovery procedure and a debugging
recipe that reproduced the exact false positive the v0.1.1 DoH migration was
written to eliminate.

### Fixed

- **The version now lives in exactly one place.** A `VERSION` file at the repo
  root is the single source; `common.sh` resolves it into `PROJECT_VERSION` and
  `failover-monitor.sh` derives `SCRIPT_VERSION` from that. `install.sh` ships
  the file into `${LIB_DIR}`. The resolver probes both the repo layout
  (`src/lib/` → `../../`) and the installed layout (`lib/` → `../`), and falls
  back to `unknown` rather than failing: a missing version file must never keep
  the failover daemon from starting.

- **The documented failover-lockfile path was wrong in three places.** README,
  `docs/how-to/debug-failover.md` and `docs/explanation/state-file-ownership.md`
  all gave it as `/run/linux-dual-wan-failover/failover-in-progress.lock`. It is
  `/run/failover-in-progress.lock` — deliberately at `/run` root, because four
  services with four different `RuntimeDirectory=` trees have to see it. The
  stale-lock recovery step in the debugging runbook would have operated on a
  path that never exists. That placement also means the lockfile survives a
  restart, which is what its `PID_TIMESTAMP` staleness check is for; both facts
  are now documented where the path is.

- **The debugging runbook recommended `dig -b` for the DNS probe.** That is the
  measurement error the DoH migration removed in v0.1.1: `dig -b` sets the
  source address but cannot force the outgoing interface, so on a demoted
  primary the packets leave through the active backup and a healthy link reports
  a timeout. Replaced with the `curl --interface` DoH call the scoring actually
  performs, including the `Status`/`Answer` validation that filters captive
  portals.

### Changed (Documentation)

Corrected against the implementation:

- **`state-file-ownership.md` named the wrong lockfile writer.** It credited
  `nmcli-failover-monitor` "only on emergency failover" — true until v0.4.0,
  when `safe_route_change()` began writing the lock on every route change.
- **`web-ui-architecture.md` claimed a 16-key config whitelist.** It is 15, in
  both `config_reader.py` and `install-failover-conf.sh`.
- **`metrics.md` described `wan_quality_score` as a composite "of the five
  metrics above"** while seven rows preceded it. Replaced with the actual
  weights (latency 25 %, loss 25 %, DNS 20 %, jitter 15 %, HTTP 15 %) and an
  explicit note that the gateway metrics are reported but do not feed the score.
- **`architecture-overview.md` predated v0.5.0.** It listed neither the
  Correlation-ID state files nor the optional `failover-web` unit and the
  health-check timer.
- **`web-api.md`'s `/api/history` sample predated the `event_id` column.**
- **`install-from-source.md` omitted `src/tools/`**, so a manual install left
  `trace-failover.sh` absent. Also adds the `_schema` directory and the Web-UI
  leftovers (sudoers, tmpfiles, logrotate, sbin helper, system user) to the
  uninstall procedure.
- **`01-quickstart.md` referred to a Docker simulation** that
  `safe-failover-testing.md` does not contain.
- **`docs/README.md` promised "see Explanation docs below"** with no such list,
  and omitted the Web-UI documentation entirely.
- **`config.md` did not document `DNS_TEST_METHOD`**, which `scoring.md` relies
  on, nor `WAN_QUALITY_PROM_MAX_AGE`. Both added, with a note on why `dig` is a
  rollback path and not a fix.
- **`failover.conf.example` carried an unfilled placeholder** ("Default since
  v0.x."); DoH became the default in v0.1.1.
- README: the static `Status: Alpha` badge is replaced by a shields.io tag badge
  that tracks the latest tag, the Status section no longer hardcodes a version
  (it claimed v0.1.1 while contradicting its own runtime table), and the source
  size is corrected from ~8.5 kLOC to ~12.5 kLOC (measured, tests excluded).

### Added

- `.gitignore` now covers the private working files the publishing rules
  require to stay out of the repository (`CLAUDE.md`, `.claude/`, `TODO.md`,
  `*_POST.md`); it previously caught only `LINKEDIN_POST.md`.

### Upgrade notes

No configuration or on-disk format changes. Existing installations keep working
unchanged; re-running `install.sh` is what places the `VERSION` file, and until
then the daemon logs `v unknown` instead of a number. Nothing else reads it.

## [0.7.0] — 2026-08-02

WAN quality was measured against the wrong endpoint. `test_wan_quality()` probed
`get_gateway "$interface"` — one LAN hop — so latency, packet loss and jitter
described an Ethernet cable rather than the uplink. In the upstream deployment
this read 1.32 ms / 0 % / 0.54 ms for the LTE backup and 0.23 ms / 0 % / 0 ms for
the DSL primary, while the same backup link was timing out 5.7 % of its
DNS probes and showing a p95 of 973 ms.

Because latency (25 %), loss (25 %) and jitter (15 %) together make up 65 % of
the composite score, the backup interface scored 90–100 whenever it was idle and
only collapsed after a failover had already put traffic on it.

### Changed

- **`test_wan_quality()` measures the internet path.** Latency, packet loss and
  jitter now probe the first responding `CHECK_IPS` entry instead of the
  interface gateway. New `WAN_QUALITY_TARGET_MODE=internet|gateway` restores the
  old behaviour as a rollback switch.
- **One ping series instead of three.** `measure_path_quality()` derives
  latency, loss and jitter (`mdev`) from a single `ping` run. Previously three
  separate series (5 + 10 + 10 sequential `ping -c 1`) described three different
  moments; the worst case of 25 × `PING_TIMEOUT` could also exceed the metrics
  collector's 30 s subprocess timeout, silently stalling `wan_quality.prom`.
- **The metrics collector sources the operator config.** Its `test_wan_quality()`
  subprocess previously sourced only `common.sh` and `network.sh`, so
  `WAN_QUALITY_TARGET_MODE` and `CHECK_IPS` never reached it — the rollback
  switch would have had no effect.

### Fixed

- **`test_wan_quality()` polluted its own stdout.** All four of its `log` calls
  wrote to stdout, but the function's stdout is parsed by the metrics collector
  with `json.loads()` — the log line landed in the payload and raised
  `JSONDecodeError: Extra data`, silently taking down WAN quality collection
  wherever `LOG_TO_STDOUT` was active (its default). `common.sh` states the rule
  explicitly: *"functions whose stdout is captured via `$(...)` must not log
  without `>&2`"*. All four calls now redirect to stderr. Covered by a
  regression test asserting the payload starts with `{` and carries no log
  markers.

#### Documentation corrected against the code

An audit of the reference docs turned up five claims that did not match the
implementation. All predate this release:

- **`metrics.md` documented a metric namespace that was never implemented.** The
  entire textfile table listed seven `linux_dual_wan_failover_*` metrics — none
  of them exist in the collector. Replaced with the twelve metrics actually
  emitted, grouped by the file each is written to, labels verified against the
  source.
- **`metrics.md` claimed a single `.prom` file.** The collector writes three:
  `wan_quality.prom`, `failover_duration.prom` and `dns_performance.prom`.
- **The suggested alert rules could never have fired** — all three were written
  against the non-existent metric names. Rewritten against the real ones, plus a
  rule for the "gateway reachable but path degraded" case this release makes
  visible.
- **`scoring.md` described the DNS test as `dig` bound to the interface IP.** It
  uses DNS-over-HTTPS via `curl --interface`; `dig -b` only sets the source
  address, which is precisely the false-positive the DoH migration fixed. Noted
  inline so the trap is not reintroduced.
- **`scoring.md` called `wan_quality.prom` an external file "updated by your own
  monitoring".** It is written by `failover-metrics-collector`, which ships with
  this repo.

### Added

- `wan_gateway_latency_milliseconds` and `wan_gateway_reachable` Prometheus
  gauges. The gateway probe is kept, just reported separately, so "modem or
  router dead" stays distinguishable from "uplink degraded".
- `gateway_latency_ms` / `gateway_reachable` columns in `wan_quality_metrics`
  (additive `ALTER TABLE` migration; existing rows stay `NULL`).
- `WAN_QUALITY_PROBE_SAMPLES` (default 10).
- `tests/unit/test_wan_quality.bats` — 13 tests covering summary parsing, the
  total-loss case where `ping` emits no `rtt` line, probe-target fallback, the
  JSON contract consumed by the collector, stdout purity, and the rollback
  switch.
- WAN quality metrics documented in `docs/reference/metrics.md`; they were
  previously undocumented.

### Upgrade notes

`wan_latency_milliseconds`, `wan_packet_loss_percent` and
`wan_jitter_milliseconds` change meaning. Expect a step change in historical
series at the upgrade point and annotate your dashboards. Any alert rule
thresholded against LAN-hop values (single-digit milliseconds) needs revisiting.

## [0.6.0] — 2026-08-02

A flapping primary link in the upstream deployment (repeated WAN-session loss
with layer 1 intact) exposed the emergency-failback path as too eager, and a
manual failback that "did nothing" turned out to be three separate defects
stacked on top of each other. Measurements behind the recalibration: the backup
uplink was not throttled (0.7 % of quota used, 27 Mbit/s down) — its 2.4 Mbit/s
**uplink** saturated under load, and only the uplink direction moved DNS
latency at all (idle 164–244 ms, downlink-saturated 182–252 ms,
uplink-saturated 321–1231 ms).

### Changed

- **Emergency-failback defaults recalibrated.** `EMERGENCY_FAILBACK_MIN_BACKUP_TIME`
  600 → 1800 s, `EMERGENCY_FAILBACK_DEGRADED_CHECKS` 6 → 20,
  `EMERGENCY_FAILBACK_COOLDOWN` 900 → 3600 s. With the old values every cycle on
  a flapping primary ended exactly at the 600 s floor — the escape hatch had
  become the normal failback path, returning traffic to a link that was still
  broken. The original "backup is up but end-to-end dead" case stays covered:
  that degradation ran for over 90 minutes continuously.
- **`EMERGENCY_FAILBACK_DEGRADED_CHECKS` semantics documented.** The counter
  ticks per `CHECK_INTERVAL`, but reads a value refreshed on the collector's
  slower cycle. The old default of 6 checks (nominally 90 s) covered fewer than
  two independent samples in practice.

### Fixed

- **`ANTI_FLAPPING_DELAY` now actually applies to manual actions.** The shipped
  config has always documented the cooldown as covering "failback + manual
  actions", but the code matched only `reason == "failback"` —
  `manual_failback` and `manual_failover_force` bypassed it entirely.
- **Anti-flapping no longer suppresses everything for the first 10 minutes
  after a reboot.** `last_failover_mono` is zero-initialised and
  `get_monotonic_time()` reads `/proc/uptime`, so the daemon computed
  `uptime - 0` when no failover had happened yet. Below `ANTI_FLAPPING_DELAY`
  seconds of uptime that suppressed every failback and manual action while
  logging a misleading "last failover was Ns ago". Guarded with
  `[[ $last_failover_mono -gt 0 ]]`, mirroring the emergency path.
- **Minimum-time-on-backup gates survive a service restart.**
  `RuntimeDirectory=` (without `RuntimeDirectoryPreserve=`) wipes the state
  directory on every restart, including `last_failover_to_backup`. Readers
  defaulted a missing value to `0`, turning "time on backup" into "seconds
  since the epoch" — which silently satisfied `MIN_BACKUP_TIME`,
  `EMERGENCY_FAILBACK_MIN_BACKUP_TIME` and made the prolonged-backup alert fire
  immediately claiming ~496 000 hours. The daemon now reseeds the timestamp at
  startup when it comes up on backup, and the emergency path refuses to act on
  an unknown value.
- **`POST /api/failback` and `POST /api/force-failover` no longer promise what
  the daemon will discard.** Both now return `409 {"status": "cooldown",
  "remaining_seconds": N}` while the anti-flapping cooldown runs, instead of
  `202 "submitted"` for a request the daemon drops with a journal line only.
  The check is advisory (the daemon stays authoritative) and fails open on a
  missing or unreadable timestamp.
- **Web UI shows error responses.** htmx swaps response bodies on 2xx only, and
  the dashboard's handler set a CSS class without ever writing the body — so
  `403` (expired CSRF token), `409` and `429` (rate limit) produced no visible
  reaction at all. The pane now renders the response text for any status
  ≥ 400.

### Added

- `config_reader.effective_int()` — single-key config lookup with the daemon's
  base-then-override precedence, so the web layer reasons about the same
  numbers the daemon uses.
- Three integration tests covering the cooldown branch: active cooldown → 409
  without writing a request file, expired cooldown → 202, unreadable timestamp
  → fails open to 202.

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

[Unreleased]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/fidpa/linux-dual-wan-failover/releases/tag/v0.1.0
