# Changelog

All notable changes to `linux-dual-wan-failover` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.2] - 2026-08-27

Editorial pass over the changelog and every GitHub release. No code, config or
documentation outside this file changed, and nothing about the daemon behaves
differently.

### Changed

- **Every changelog entry rewritten for readability.** The em dash was doing far
  too much work: it stood in for colons, parentheses, causal "because" clauses
  and mid-sentence asides, often several times in one paragraph. All of them are
  gone, replaced by ordinary punctuation or by the words the dash was hiding.
  Along with them went the remaining typographic characters (en dashes,
  ellipses, arrows), so the file is now plain ASCII throughout. Long sentences
  were split, and passages that restated the preceding line were cut. Every
  measured number, file path, function name and threshold is unchanged; this is
  a rewording, not a revision of the record.

- **Section headings use `## [X.Y.Z] - YYYY-MM-DD`,** a plain hyphen, matching
  the Keep a Changelog examples. They previously used an em dash.

- **All 15 GitHub releases re-published from the rewritten sections,** restoring
  the convention that a release body is its changelog section verbatim. Release
  titles switched from `vX.Y.Z - Headline` to `vX.Y.Z: Headline`, and the two
  releases that had no real headline (0.1.0 and 0.1.1) got one. The v0.1.0
  release had an empty body and now carries its section.

  Two releases keep hand-written bodies for reasons that predate this pass:
  v0.2.1 has no changelog section of its own by design, since the feature is
  documented under 0.2.0, and v0.5.1 keeps its note about having been published
  retroactively.

### Fixed

- **The comparison links at the foot of the file skipped 0.9.1.** `[Unreleased]`
  still pointed at `v0.9.0...HEAD` and no `[0.9.1]` line existed, an oversight
  from the 0.9.1 release itself.

## [0.9.1] - 2026-08-27

Documentation only. An audit of the anti-flapping docs against the code found
that `STABILITY_RESET_THRESHOLD` does not do what the comments, the prose and
the web UI all said it did: it never affects when failback happens. The daemon
behaves exactly as before. Only the descriptions change, and they were wrong in
a way that would have sent an operator tuning the wrong knob mid-incident.

### Fixed

#### Documentation corrected against the code

- **`STABILITY_RESET_THRESHOLD` does not gate failback timing.** The docs
  described a two-tier design: scores between the reset threshold (50) and the
  failover threshold (60) were supposed to keep the failback stability window
  open, so a borderline dip would not cost the primary its accumulated
  stability.

  The code never worked that way. Any round where the primary scores below 60
  zeroes `consecutive_recoveries`, and that counter is the first gate in
  `is_failback_needed()`. It has to climb back to `RECOVERY_THRESHOLD` (20)
  before the stability window is even read. Once the primary recovers, the
  window restarts from that moment no matter what the threshold did. All the
  threshold decides is whether a warning gets logged.

  The real behaviour is stricter than the old description, since the window
  restarts after every dip below 60 rather than only below 50. That is the safe
  direction, which is why this is documented instead of "fixed": making the
  window genuinely survive a dip would shorten the stability actually required
  before going back to the primary. Corrected in
  `docs/explanation/anti-flapping.md`, the comment block in
  `failover-monitor.sh`, and the field description in `config_reader.py` that
  the web UI shows next to the input. The "what not to touch" list now points
  at `MIN_STABLE_DURATION`, which does change failback timing.

- **Debug field `window_kept=` renamed to `reset_warning=`.** The per-round
  debug line printed `window_kept=yes` whenever the score sat between 50 and
  59, telling anyone reading the journal during an incident the one thing that
  is not true. The field now reports what the comparison actually decides.
  Log text only; no gating or state transition is affected.

- **Stale cooldown value in a code comment.** The preconditions block for
  `is_emergency_failback_needed()` still claimed `EMERGENCY_FAILBACK_COOLDOWN`
  was 15 minutes. Version 0.6.0 raised the default from 900 to 3600 seconds
  and left the comment behind; it was the last place in the repo still saying
  900. The same block now also states `EMERGENCY_FAILBACK_DEGRADED_CHECKS` in
  the unit it actually counts (fresh collector readings, not poll intervals)
  and gives `EMERGENCY_FAILBACK_MIN_BACKUP_TIME` its default of 1800 seconds.

## [0.9.0] - 2026-08-25

Code quality: one bug fix, dead code removed, some DRY work across the Bash
daemons and the Flask web UI. The only new feature is a restart-monitor button.

### Fixed

- **Failback guard against an unknown timestamp.** After a service restart,
  `is_failback_needed()` defaulted `failover_to_backup_time` to `0`. That made
  "time on backup" equal to the Unix epoch, roughly 1.7 billion seconds, which
  satisfied `MIN_BACKUP_TIME` instantly and allowed a premature failback. The
  sister function `is_emergency_failback_needed()` already had this guard.
  Both now share the same "unknown means block" logic.

- **`is_numeric()` had two different definitions.** One rejected trailing dots,
  the other accepted them, and they lived in `common.sh` and `network.sh`
  respectively. Unified into a single definition in `common.sh`.

- **SC2015 false error path.** `[[ ... ]] && { mkdir; chmod; } || log_warning`
  fired the warning branch when `chmod` failed inside the group, not when
  `STATE_FILE` was unset as intended. Replaced with a plain `if/then/else`.

### Added

- **`POST /api/restart-monitor`** with rate limiting (one call per 5 minutes),
  CSRF protection and audit logging, plus a dashboard button. Replaces the
  previous "run `systemctl` on the CLI" instruction.

### Removed

- **The cache framework, about 350 lines in `performance.sh`.** Every cache
  function (`cached_ping`, `init_cache_structures`, `invalidate_cache` and the
  rest) ran inside `$(...)` subshells, so every write to the in-memory cache was
  thrown away immediately. Verified live: a permanent "0% hit rate (0/0), 0
  entries". Callers now use `perform_ping_test` directly.

- **Four dead functions** in `network.sh` with no callers outside their own
  definitions: `compare_interfaces`, `measure_dns_time`, `measure_http_time`,
  `test_bandwidth`.

### Changed

- **`_lock()` became `flock_path()`**, moved out of `config_writer.py` and
  `manual_action_writer.py` into `writers/__init__.py`.

- **SSE slot reservation** folded into a `_try_reserve_sse()` helper in
  `app.py`, replacing two identical ten-line blocks.

## [0.8.1] - 2026-08-11

Ten scripts had lost their executable bit. Mode-only change, no content diff.
`install.sh` is meant to run directly (`sudo ./install.sh`, as the README says)
and would have failed with "Permission denied" on a fresh clone.

### Fixed

- **Restored `chmod 755`** on `install.sh`, the four systemd-invoked service
  scripts (`failover-monitor.sh`, `nmcli-failover-monitor.sh`,
  `route-guardian.sh`, `failover-monitor-health-check.sh`),
  `failover-metrics-collector.py`,
  `plugins/quota-providers/netgear-lm1200/collect-quota.py` and the three
  `tests/mocks/{ip,nmcli,ping}` stand-ins. Confirmed with `git diff --summary`:
  `mode change 100644 => 100755` only.

## [0.8.0] - 2026-08-08

Four processes mutate the same routing table, and until now nothing actually
stopped them doing it at the same time. The `failover-in-progress` marker looked
like it did, since route-guardian checks it and skips its cycle. But the check
happens once, at the top, and the guardian keeps changing routes for the rest of
that cycle. A failover starting a few milliseconds after the check runs entirely
inside the guardian's window, and the guardian then restores the old metric or
deletes the new route as a duplicate, working from state it read before the swap.

This release puts a real `flock` underneath the marker and fixes three latent
bugs found while auditing the same code paths. Latent in the precise sense:
each one is currently masked by an unrelated implementation detail and would
start firing the moment that detail changed.

No incident prompted this. It came out of a review, which is worth saying
plainly, because the project's own documentation had described the marker as
sufficient. The argument in `docs/explanation/state-file-ownership.md` was
internally consistent and still wrong: it reasoned about contention over the
file, where the contention is over the routing table.

### Added

- **A real mutual-exclusion lock at `/run/failover-route.lock`,** held with
  `flock` on a fixed descriptor. The orchestrator holds it across its whole
  route transaction; route-guardian and the nmcli emergency path take it around
  each `ip route` call. The guardian skips its repair rather than waiting when
  it cannot get the lock.

  The marker file stays. It still runs the 30-second settle window against
  NetworkManager DHCP stragglers and still carries the failover event id that
  `trace-failover` correlates on. The `flock` is the fine-grained net underneath
  it, not a replacement, and unlike the marker it needs no stale detection
  because the kernel releases it when the holder dies.

  Two constraints shaped the implementation and are written into the code as
  rules. Locked regions contain no forks, because `flock` lives on the open file
  description and a backgrounded `send_alert` child would inherit it. And
  delete-then-re-add sits inside one region, because locking only the add would
  let the lock change hands in between and leave an interface with no default
  route at all.

### Fixed

- **`active_wan` is now translated on read.** The file holds interface names
  (`eth0`, `lte0`) because route-guardian, `routing.sh`, the metrics collector
  and the shell aliases all expect them. The restart path loaded that value
  verbatim into `current_wan`, where every guard compares against `primary` and
  `backup`. This is harmless today only because `RuntimeDirectory=` wipes the
  state directory on every restart, so the detection branch runs instead. Set
  `RuntimeDirectoryPreserve=restart`, an otherwise sensible change, and failback
  plus every manual action go silently dead.

- **No more instant failover while already on backup.** Every branch of the USR1
  handler switched primary to backup unconditionally. A second primary event
  after the 60-second instant cooldown re-ran the whole transaction and rewrote
  `last_failover_to_backup`, restarting `MIN_BACKUP_TIME` from zero. The new
  guard sits after the both-degraded branch so that alert still fires while on
  backup.

- **Stale packet loss no longer triggers instant failovers.**
  `get_interface_packet_loss` read `wan_quality.prom` with no age check, unlike
  every other consumer of that file. That value feeds `is_critical_packet_loss`,
  which bypasses `FAILURE_THRESHOLD`, so a frozen collector reading kept forcing
  immediate failovers long after the link had recovered. It now honours
  `WAN_QUALITY_PROM_MAX_AGE` and falls back to live measurement.

- **The emergency path checks ownership before removing the marker.** Its
  success path did; its failure path removed whatever marker happened to be
  there, re-arming route-guardian in the middle of someone else's transaction.

- **Route repair is rate-limited per interface.** With one shared marker, both
  default routes going missing at once (a NetworkManager restart does this)
  meant repairing the primary locked out repairing the backup for 60 seconds,
  which is exactly the window where the backup path matters.

### Changed

- **`EMERGENCY_FAILBACK_DEGRADED_CHECKS` counts readings, not rounds. Default
  20 becomes 6.** The counter advanced once per orchestrator cycle (15 s) while
  the DNS value it reads refreshes every 36 to 52 seconds, so the same sample
  got counted up to four times and a single outlier could reach the threshold on
  its own. The 20 from 0.6.0 was a workaround for exactly this, picked to
  approximate six independent samples. The counter now advances only when
  `wan_quality.prom` has actually been rewritten, so the number means what it
  says. Both defaults encode the same intent: roughly five minutes of evidence.

- **Network timeouts are assignable again instead of `readonly`.**
  `PING_TIMEOUT`, `DNS_TIMEOUT` and `HTTP_TIMEOUT` were declared `readonly` in
  `network.sh`, which silently overwrote whatever the operator set. The units
  pass `failover.conf` through `EnvironmentFile`, so those values arrive as
  environment variables before the script runs. Setting `PING_TIMEOUT=7` in your
  config had no effect and produced no warning. Defaults are unchanged (2, 3 and
  5 seconds), so runtime behaviour is identical. The setting simply works now.

  One caveat before raising it: `PING_TIMEOUT` acts as a multiplier, not just a
  wrapper. `measure_packet_loss` caps at `PING_TIMEOUT` times the count, and
  `measure_path_quality` at samples plus twice `PING_TIMEOUT`. Both push against
  the metrics collector's 30-second subprocess budget.

## [0.7.1] - 2026-08-03

The orchestrator had been announcing `Failover Monitor v0.1.1` on every start
since May. Nine releases of drift, because `failover-monitor.sh` carried its own
`readonly SCRIPT_VERSION="0.1.1"` literal that nobody bumped alongside the tag.
A journal naming a version that has not existed for months cannot answer the
first question of any incident review: which code is actually running here?

The same review prompted an audit of the docs against the code. It turned up a
wrong path in the stale-lock recovery procedure and a debugging recipe that
reproduced the exact false positive the 0.1.1 DoH migration was written to
eliminate.

### Fixed

- **The version now lives in exactly one place.** A `VERSION` file at the repo
  root is the single source. `common.sh` resolves it into `PROJECT_VERSION` and
  `failover-monitor.sh` derives `SCRIPT_VERSION` from that; `install.sh` ships
  the file into `${LIB_DIR}`. The resolver probes both the repo layout and the
  installed layout, and falls back to `unknown` rather than failing, because a
  missing version file must never stop the failover daemon from starting.

- **The documented lockfile path was wrong in three places.** README,
  `docs/how-to/debug-failover.md` and `docs/explanation/state-file-ownership.md`
  all gave it as `/run/linux-dual-wan-failover/failover-in-progress.lock`. It is
  `/run/failover-in-progress.lock`, deliberately at the `/run` root, because
  four services with four different `RuntimeDirectory=` trees have to see it.
  The stale-lock recovery step in the runbook would have operated on a path that
  never exists. That placement also means the lockfile survives a restart, which
  is what its `PID_TIMESTAMP` staleness check is for. Both facts are now
  documented where the path is.

- **The runbook recommended `dig -b` for the DNS probe.** That is the very
  measurement error the DoH migration removed in 0.1.1. `dig -b` sets the source
  address but cannot force the outgoing interface, so on a demoted primary the
  packets leave through the active backup and a healthy link reports a timeout.
  Replaced with the `curl --interface` DoH call the scoring actually performs,
  including the `Status` and `Answer` validation that filters captive portals.

### Changed (documentation)

Corrected against the implementation:

- `state-file-ownership.md` named the wrong lockfile writer. It credited
  `nmcli-failover-monitor` "only on emergency failover", true until 0.4.0, when
  `safe_route_change()` began writing the lock on every route change.
- `web-ui-architecture.md` claimed a 16-key config whitelist. It is 15, in both
  `config_reader.py` and `install-failover-conf.sh`.
- `metrics.md` described `wan_quality_score` as a composite "of the five metrics
  above" while seven rows preceded it. Replaced with the actual weights (latency
  25 %, loss 25 %, DNS 20 %, jitter 15 %, HTTP 15 %) and a note that the gateway
  metrics are reported but do not feed the score.
- `architecture-overview.md` predated 0.5.0 and listed neither the correlation-id
  state files nor the optional `failover-web` unit and health-check timer.
- The `/api/history` sample in `web-api.md` predated the `event_id` column.
- `install-from-source.md` omitted `src/tools/`, so a manual install left
  `trace-failover.sh` absent. It now also covers the `_schema` directory and the
  web UI leftovers (sudoers, tmpfiles, logrotate, sbin helper, system user) in
  the uninstall procedure.
- `01-quickstart.md` referred to a Docker simulation that
  `safe-failover-testing.md` does not contain.
- `docs/README.md` promised "see Explanation docs below" with no such list, and
  omitted the web UI documentation entirely.
- `config.md` documented neither `DNS_TEST_METHOD`, which `scoring.md` relies
  on, nor `WAN_QUALITY_PROM_MAX_AGE`. Both added, with a note on why `dig` is a
  rollback path and not a fix.
- `failover.conf.example` carried an unfilled placeholder ("Default since
  v0.x."). DoH became the default in 0.1.1.
- README: the static `Status: Alpha` badge is now a shields.io badge tracking
  the latest tag, the Status section no longer hardcodes a version (it claimed
  0.1.1 while contradicting its own runtime table), and the source size is
  corrected from about 8.5 to about 12.5 kLOC, measured, tests excluded.

### Added

- `.gitignore` now covers the private working files the publishing rules require
  to stay out of the repository (`CLAUDE.md`, `.claude/`, `TODO.md`,
  `*_POST.md`). It previously caught only `LINKEDIN_POST.md`.

### Upgrade notes

No configuration or on-disk format changes. Existing installations keep working.
Re-running `install.sh` is what places the `VERSION` file; until then the daemon
logs `v unknown` instead of a number, and nothing else reads it.

## [0.7.0] - 2026-08-02

WAN quality was measured against the wrong endpoint. `test_wan_quality()` probed
`get_gateway "$interface"`, one LAN hop away, so latency, packet loss and jitter
described an Ethernet cable rather than the uplink. In the upstream deployment
this read 1.32 ms, 0 % and 0.54 ms for the LTE backup, and 0.23 ms, 0 % and 0 ms
for the DSL primary, while that same backup link was timing out 5.7 % of its DNS
probes with a p95 of 973 ms.

Latency (25 %), loss (25 %) and jitter (15 %) together make up 65 % of the
composite score, so the backup scored 90 to 100 whenever it was idle and only
collapsed once a failover had already put traffic on it.

### Changed

- **`test_wan_quality()` measures the internet path.** Latency, packet loss and
  jitter now probe the first responding `CHECK_IPS` entry instead of the
  interface gateway. The new `WAN_QUALITY_TARGET_MODE=internet|gateway` restores
  the old behaviour as a rollback switch.

- **One ping series instead of three.** `measure_path_quality()` derives
  latency, loss and jitter (`mdev`) from a single `ping` run. Three separate
  series (5, 10 and 10 sequential `ping -c 1` calls) described three different
  moments, and the worst case of 25 times `PING_TIMEOUT` could exceed the
  collector's 30-second subprocess timeout, silently stalling `wan_quality.prom`.

- **The metrics collector now sources the operator config.** Its
  `test_wan_quality()` subprocess sourced only `common.sh` and `network.sh`, so
  `WAN_QUALITY_TARGET_MODE` and `CHECK_IPS` never reached it and the rollback
  switch would have had no effect.

### Fixed

- **`test_wan_quality()` polluted its own stdout.** All four of its `log` calls
  wrote to stdout, but that stdout is parsed by the metrics collector with
  `json.loads()`. The log line landed in the payload and raised
  `JSONDecodeError: Extra data`, silently taking down WAN quality collection
  wherever `LOG_TO_STDOUT` was active, which is its default. `common.sh` states
  the rule outright: functions whose stdout is captured must not log without
  `>&2`. All four calls now redirect to stderr, covered by a regression test
  asserting the payload starts with `{` and carries no log markers.

#### Documentation corrected against the code

An audit of the reference docs turned up five claims that did not match the
implementation. All predate this release.

- **`metrics.md` documented a metric namespace that was never implemented.** The
  entire textfile table listed seven `linux_dual_wan_failover_*` metrics and not
  one of them exists in the collector. Replaced with the twelve metrics actually
  emitted, grouped by the file each is written to, labels verified against the
  source.
- **`metrics.md` claimed a single `.prom` file.** The collector writes three:
  `wan_quality.prom`, `failover_duration.prom` and `dns_performance.prom`.
- **The suggested alert rules could never have fired,** since all three were
  written against the non-existent metric names. Rewritten against the real
  ones, plus a rule for the "gateway reachable but path degraded" case this
  release makes visible.
- **`scoring.md` described the DNS test as `dig` bound to the interface IP.** It
  uses DNS-over-HTTPS via `curl --interface`. `dig -b` only sets the source
  address, which is precisely the false positive the DoH migration fixed. Noted
  inline so the trap is not reintroduced.
- **`scoring.md` called `wan_quality.prom` an external file** "updated by your
  own monitoring". It is written by `failover-metrics-collector`, which ships
  with this repo.

### Added

- `wan_gateway_latency_milliseconds` and `wan_gateway_reachable` Prometheus
  gauges. The gateway probe is kept, just reported separately, so "modem or
  router dead" stays distinguishable from "uplink degraded".
- `gateway_latency_ms` and `gateway_reachable` columns in `wan_quality_metrics`
  via an additive `ALTER TABLE` migration; existing rows stay `NULL`.
- `WAN_QUALITY_PROBE_SAMPLES`, default 10.
- `tests/unit/test_wan_quality.bats`, 13 tests covering summary parsing, the
  total-loss case where `ping` emits no `rtt` line, probe-target fallback, the
  JSON contract the collector consumes, stdout purity and the rollback switch.
- WAN quality metrics documented in `docs/reference/metrics.md`, where they were
  previously missing.

### Upgrade notes

`wan_latency_milliseconds`, `wan_packet_loss_percent` and
`wan_jitter_milliseconds` change meaning. Expect a step change in historical
series at the upgrade point and annotate your dashboards. Any alert rule
thresholded against LAN-hop values, meaning single-digit milliseconds, needs
revisiting.

## [0.6.0] - 2026-08-02

A flapping primary link in the upstream deployment, meaning repeated WAN-session
loss with layer 1 intact, exposed the emergency-failback path as far too eager.
Separately, a manual failback that "did nothing" turned out to be three defects
stacked on top of each other.

The measurements behind the recalibration: the backup uplink was not throttled
(0.7 % of quota used, 27 Mbit/s down). Its 2.4 Mbit/s upstream saturated under
load, and only the upstream direction moved DNS latency at all. Idle it ran 164
to 244 ms, downlink-saturated 182 to 252 ms, uplink-saturated 321 to 1231 ms.

### Changed

- **Emergency-failback defaults recalibrated.**
  `EMERGENCY_FAILBACK_MIN_BACKUP_TIME` goes from 600 to 1800 s,
  `EMERGENCY_FAILBACK_DEGRADED_CHECKS` from 6 to 20, and
  `EMERGENCY_FAILBACK_COOLDOWN` from 900 to 3600 s. With the old values every
  cycle on a flapping primary ended exactly at the 600-second floor: the escape
  hatch had become the normal failback path, handing traffic back to a link that
  was still broken. The original "backup is up but end-to-end dead" case stays
  covered, since that degradation ran for over 90 minutes without a break.

- **`EMERGENCY_FAILBACK_DEGRADED_CHECKS` semantics documented.** The counter
  ticks once per `CHECK_INTERVAL` but reads a value refreshed on the collector's
  slower cycle. The old default of 6 checks, nominally 90 seconds, covered fewer
  than two independent samples in practice.

### Fixed

- **`ANTI_FLAPPING_DELAY` now actually applies to manual actions.** The shipped
  config had always documented the cooldown as covering failback and manual
  actions, but the code matched only `reason == "failback"`. Both
  `manual_failback` and `manual_failover_force` bypassed it entirely.

- **Anti-flapping no longer suppresses everything for ten minutes after a
  reboot.** `last_failover_mono` starts at zero and `get_monotonic_time()` reads
  `/proc/uptime`, so with no failover yet the daemon computed `uptime - 0`.
  Below `ANTI_FLAPPING_DELAY` seconds of uptime that suppressed every failback
  and manual action while logging a misleading "last failover was N seconds
  ago". Now guarded with `[[ $last_failover_mono -gt 0 ]]`, mirroring the
  emergency path.

- **Minimum-time-on-backup gates survive a service restart.**
  `RuntimeDirectory=`, without `RuntimeDirectoryPreserve=`, wipes the state
  directory on every restart, `last_failover_to_backup` included. Readers
  defaulted a missing value to `0`, turning "time on backup" into "seconds since
  the epoch". That silently satisfied both `MIN_BACKUP_TIME` and
  `EMERGENCY_FAILBACK_MIN_BACKUP_TIME`, and made the prolonged-backup alert fire
  immediately claiming roughly 496 000 hours. The daemon now reseeds the
  timestamp at startup when it comes up on backup, and the emergency path
  refuses to act on an unknown value.

- **`POST /api/failback` and `POST /api/force-failover` no longer promise what
  the daemon will discard.** Both now return `409 {"status": "cooldown",
  "remaining_seconds": N}` while the anti-flapping cooldown runs, instead of
  `202 "submitted"` for a request the daemon drops with nothing but a journal
  line. The check is advisory, the daemon stays authoritative, and it fails open
  on a missing or unreadable timestamp.

- **The web UI shows error responses.** htmx swaps response bodies on 2xx only,
  and the dashboard's handler set a CSS class without ever writing the body. So
  `403` (expired CSRF token), `409` and `429` (rate limit) produced no visible
  reaction at all. The pane now renders the response text for any status of 400
  or above.

### Added

- `config_reader.effective_int()`, a single-key config lookup with the daemon's
  base-then-override precedence, so the web layer reasons about the same numbers
  the daemon uses.
- Three integration tests covering the cooldown branch: active cooldown returns
  409 without writing a request file, expired cooldown returns 202, and an
  unreadable timestamp fails open to 202.

## [0.5.1] - 2026-07-16

A field incident in the upstream deployment, where a captured function's log
line corrupted a `sed` expression during a real DSL outage, prompted an audit of
the logging setup here. The code was clean, but the audit surfaced one latent
ordering bug.

### Fixed

- **Logging defaults are set before the toolkit is sourced.** In `common.sh`,
  `LOG_FILE`, `LOG_TO_JOURNAL` and `LOG_TO_STDOUT` now get their values before
  the toolkit's `logging.sh` is sourced. The toolkit initialises these with `:=`
  at source time, so the previous assignments after the `source` line were dead
  code: with the toolkit installed, `LOG_TO_STDOUT` silently ran as `true` while
  the code claimed a `false` default.

  The effective default is now an explicit, documented `true`. The systemd units
  use `StandardOutput=journal`, and stdout is the only path into the journal
  when the toolkit is loaded, which is how the debug guide reads logs. No
  behaviour change: this pins what the services have always relied on and keeps
  it stable against future toolkit defaults. Overrides via environment or
  `EnvironmentFile` work as before.

## [0.5.0] - 2026-06-29

Correlation-id tracing for failovers. Every failover now carries a single id
that travels through all four services and the metrics database, so one event
can be reconstructed end to end.

### Added

- **`src/lib/event-id.sh`** mints, propagates and persists the failover event id
  in `PID_TIMESTAMP` form, identical to the lockfile format.
  `nmcli-failover-monitor` mints it at detection and writes `pending_failover_id`
  before sending USR1, which keeps the receiver's trap free of I/O.
  `failover-monitor` adopts it in its main loop, or mints a fresh one for
  health-check, failback and manual failovers. `routing.sh` publishes
  `last_failover_id` for the collector.
- **`src/tools/trace-failover.sh`,** an operator CLI that reconstructs one
  failover from its event id: the event-DB row for the symptom, plus a
  time-merged service-log waterfall for the cause. Supports `--list`, `--last`
  and a specific id, with device-agnostic paths overridable through `LOG_DIR`,
  `STATE_DIR` and `EVENTS_DB`. `install.sh` places it in `${LIB_DIR}/tools/`.
- **`event_id` column** on `failover_events`, via an idempotent `ALTER TABLE`
  migration. The web reader degrades gracefully to `NULL` against a
  not-yet-migrated database.
- A **Trace column** in the web UI event history exposing the event id, with a
  copy-ready `grep` command in the cell tooltip.
- New how-to at [`docs/how-to/trace-failover.md`](docs/how-to/trace-failover.md),
  a "Key Concepts" section in the README, and CI lint coverage for `src/tools/`.

### Changed

- `nmcli-failover-monitor`, `failover-monitor`, `routing.sh` and
  `route-guardian` stamp `FAILOVER_EVENT_ID=<id>` into their logs at the four
  lifecycle points: detection, orchestration, route change, guardian pause.
- The lockfile now contains the failover event id. The on-disk format stays
  `PID_TIMESTAMP`, so route-guardian's stale detection still parses it. Fully
  backward compatible.

## [0.4.1] - 2026-06-12

The first live run of the 0.4.0 CI pipeline caught two runner-environment issues
in the new jobs themselves. All the code checks had passed.

### Fixed

- **The logrotate gate failed with `unknown group 'failover-web'`.** The
  unit-verify step created the user with `wan-state` as primary group but never
  created a `failover-web` group, which the logrotate policy's
  `create 0644 failover-web failover-web` line requires. The step now creates
  both groups, matching what `install.sh` really does: a dedicated primary group
  plus `wan-state` as supplementary.

- **gitleaks flagged `.gitleaksignore` itself.** The 0.4.0 revision of the
  allowlist quoted the placeholder-credentials example verbatim in its own
  comment and thereby matched the `curl-auth-user` rule. The comment now
  describes the example without reproducing the matchable pattern, and a
  fingerprint covers the old blob still in git history.

  The local pre-push scan had run before the file was committed, so the history
  scan never saw it. The lesson: verify gitleaks against the actual commit, not
  the working tree.

## [0.4.0] - 2026-06-12

Findings from a full code review of the upstream production deployment, ported
here. Three of these fixes concern paths that had never worked: the unit tests
mocked `subprocess.run` and route changes, so only a live end-to-end test could
expose them.

### Fixed

- **Emergency route recovery was a silent no-op.**
  `emergency_restore_any_route()` in `routing.sh` called
  `check_interface_status()`, which is defined only in `route-guardian.sh`, a
  different process. Inside the orchestrator that meant `command not found`,
  both restore attempts were skipped, and the function always ended at "Could
  not restore any route". It now uses a local `_interface_link_up()` helper
  based on `ip link` and the sysfs carrier.

- **The web UI config editor could never install.** The root helper
  `install-failover-conf` requires every line of the staged file to be a
  whitelisted integer tunable, but the staged file was the full `failover.conf`,
  whose interfaces, test targets and other non-whitelisted lines always failed
  validation. Fixed by the override design, see Changed below.

- **sudo from the web UI was blocked by implicit `NoNewPrivileges`.** The unit's
  seccomp-implying hardening options (`SystemCallArchitectures`,
  `MemoryDenyWriteExecute` and friends) force `NoNewPrivileges=yes` for non-root
  services, silently overriding the explicit `NoNewPrivileges=false`. Every
  `sudo` call, config install and daemon restart alike, failed with "no new
  privileges". Those options are removed; the mount-based sandbox stays and
  escalation remains scoped to two commands via sudoers.
  `ReadWritePaths=/etc/<project>` is added because sudo children inherit the
  unit's mount namespace, where `ProtectSystem=strict` made `/etc` read-only for
  the root helper too.

- **The web UI log could go permanently dead.** `RotatingFileHandler` with two
  gunicorn workers sharing one file is not multiprocess-safe: once the 10 MB cap
  was hit, `doRollover()` failed on every record. Observed upstream: 1076
  logging errors in 3 days with the log frozen. On top of that, gunicorn's
  `--access-logfile` and `--error-logfile` pointed at the same file as the app
  handler. Now it uses `WatchedFileHandler` plus a logrotate policy
  (`systemd/failover-web.logrotate`, installed by `install.sh --with-web-ui`),
  and gunicorn logs to stderr and on to journald.

- **Route-guardian could fight an in-flight failover.** The lockfile
  `/run/failover-in-progress.lock` was only ever created by the nmcli emergency
  path, so regular score-based and manual failovers ran without pausing the
  guardian, which could revert a fresh metric swap in the window before
  `active_wan` is persisted. `safe_route_change()` now creates the lock
  (`PID_TIMESTAMP`, 30-second hold with an ownership check, immediate release on
  error). The guardian check also moved from `monitor_default_routes()` to the
  top of `comprehensive_route_health_check()`, because duplicate cleanup,
  NM-metric repair and conflict resolution also mutate routes and previously
  kept running during a failover.

- **The USR1 instant failover could wait a full check interval.** Bash runs
  traps only after the current foreground command finishes, so a USR1 arriving
  during `sleep 15` waited up to 15 seconds. The main loop now uses
  `sleep ... & wait $!`, which returns immediately on any trapped signal, the
  same pattern route-guardian already used.

- **`systemctl stop route-guardian` ran into a 90-second timeout and SIGKILL.**
  The SIGTERM trap returned without ending the `while true` loop. A shutdown
  flag now ends the loop at the top of the next iteration.

- **Double rollback on route-change errors.** `safe_route_change()` had an ERR
  trap in addition to explicit `rollback_route_change` calls. On an empty
  gateway lookup both fired, the second against an already-deleted backup file,
  escalating into a false "manual intervention required" cascade. The ERR trap
  is gone; the explicit error paths cover every failure mode.

- **Rollback could fail with "File exists".**
  `restore_routes_from_backup()` deleted only one default route before
  `ip route restore`, so with both WAN routes present the restore collided with
  the remaining one. All default routes are removed first now.

- **The nmcli fallback never found the daemon.** Its `pgrep -f` fallback matched
  against the install path while the process cmdline shows the path systemd
  actually executed, so on a stale PID file the trigger fell straight through to
  the raw emergency path. That path also added the backup route with metric 100,
  a pre-metric-demotion relic that created a duplicate route the guardian had to
  clean up. It now only adds the route if missing, with metric 200.

- **Dead DHCP-lease gateway fallback.** `get_gateway_from_dhcp()` parsed
  `/var/lib/dhcp/dhclient.<iface>.leases`, which never exists on NetworkManager
  systems because of its internal DHCP client. Replaced with
  `get_gateway_from_nm()` using `nmcli -g IP4.GATEWAY`.

- **The web test suite had a built-in time bomb.** Seeded history events used
  hardcoded dates that fall out of the default 30-day query window. Fixtures now
  seed relative to now.

- **The `diag` timeout now covers the whole run.** It previously applied only to
  `proc.wait()` after the read loop, so a slowly dripping `traceroute` could
  stream for 60 to 90 seconds despite the 30-second limit.

### Changed

- **Config override design.** The web UI no longer patches `failover.conf`.
  Operator edits land in `/etc/<project>/failover-overrides.conf`, integer
  tunables only and root-validated, which the daemon sources after the base
  config so bash last-wins applies. The base config stays pristine, and
  `GET /api/config` reports the effective merged values plus both paths. New env
  knob: `FAILOVER_WEB_OVERRIDE_CONFIG_PATH`.

- **`FAILOVER_THRESHOLD_DOWN` is actually wired up now.** The degraded threshold
  was hardcoded to 60 in three places, so the config value and the web UI field
  had no effect. `CHECK_IPS` and `DNS_SERVERS` similarly no longer overwrite
  config-provided values.

- **Freshness thresholds match the collector cadence.** The shipped unit sets
  `FAILOVER_WEB_STATE_STALE_SECONDS=75` and
  `FAILOVER_WEB_STATE_MISSING_SECONDS=180`. With prom writes around every 60
  seconds, the 30-second default flagged "stale" in steady state.

- **gunicorn 25.x control socket.** The unit sets `HOME=/var/lib/failover-web`,
  because the user's real home is read-only under `ProtectHome`, which produced
  a "Control server error" on every start.

### Added

- **The web UI test suite finally runs in CI.** A new pytest job runs all 136
  tests on Python 3.10, the documented floor, and 3.12. None of the web UI fixes
  in this release would have been caught by the previous pipeline, which never
  executed `src/web/tests/`.
- **Secret scanning in CI.** gitleaks scans the full git history on every push
  and PR. `.gitleaksignore` carries the one audited false positive, the
  placeholder `admin:secret` example in the quota custom-template docs.
- **Config syntax gates in CI:** `visudo -cf` for the sudoers fragment,
  `logrotate -d` for the new policy, and `bash -n` for the sourced config
  examples, since a syntax error in `failover.conf` bricks the daemon at
  startup.

### Changed (CI)

- **The systemd unit check can actually fail now.** It previously ran
  `systemd-analyze verify || true`, and a check that cannot fail is not a check.
  The job now stubs the `Exec*` binary paths the units reference, which are the
  only legitimately missing pieces on a runner, and treats any remaining verify
  error as a hard failure.
- **ruff lints `src/web/`.** The two pre-existing unused-import findings are
  fixed in this release. `ruff format --check` stays scoped to the two
  standalone scripts, since reformatting 31 web files wholesale would bury the
  diff history for no behavioural gain.
- **shellcheck covers the full bash surface,** now including `install.sh`, the
  root-side config installer `src/web/install-failover-conf.sh`, and the bats
  helpers and mocks.
- Workflow hygiene: `permissions: contents: read` for least privilege, and a
  concurrency group that cancels superseded runs.

### Removed

- **`FAILOVER_THRESHOLD_UP` and `HYSTERESIS_GAP`.** The daemon never evaluated
  either. Failback is governed by `MIN_FAILBACK_SCORE`, `MIN_BACKUP_TIME` and
  `MIN_STABLE_DURATION`, and the score-hysteresis code path below the
  `MIN_FAILBACK_SCORE` gate was unreachable: it required a score above 90 on a
  path only reachable below 60. The web UI field is gone, because a knob without
  effect fakes control. The config example keeps both names commented out as
  historical documentation. The dead branch in `is_failback_needed()` is
  removed, and behaviour is unchanged.

- Dead code: `restore_missing_backup_route()`, a monitoring-only stub with
  inverted log logic and no callers; the events-module signal-handler remnants
  in `common.sh` (`setup_signal_handlers`, `handle_event_signal`,
  `graceful_shutdown`, `cleanup_temp_files`), which referenced functions that no
  longer exist; and the always-zero performance-stats log line, whose counters
  live in command-substitution subshells and can never accumulate, now
  documented in `performance.sh`.

## [0.3.0] - 2026-06-10

### Fixed

- **The web UI could not write `manual_action.json`.** The `chgrp wan-state` on
  `/run/<project>/wan-state` ran inside the orchestrator unit's sandbox, where
  `CapabilityBoundingSet` drops `CAP_CHOWN`. So the group ownership silently
  stayed `root`, the group-writable bit was useless, and the dashboard's
  failback and force-failover buttons returned a write error. The `ExecStartPre`
  chgrp now uses the systemd `+` prefix to run with full privileges outside the
  sandbox, and the directory is `02775` (setgid) so `manual_action.json`
  inherits the `wan-state` group.

### Changed

- **Anti-flapping docs now match the implementation.** `ANTI_FLAPPING_DELAY`
  (600 s) is the cooldown for failback and manual actions only. Score-based
  failover has no cooldown; it is covered by `FAILURE_THRESHOLD`,
  `MIN_BACKUP_TIME`, `MIN_STABLE_DURATION` and the emergency exemption.
  Corrected in the config example comments, in
  `docs/explanation/anti-flapping.md`, and in a stale daemon log line that
  printed "300s cooldown" while enforcing 600.

## [0.2.0] - 2026-05-05

### Added

- **Optional Flask and gunicorn web UI** under `src/web/`. `install.sh
  --with-web-ui` provisions a dedicated `failover-web` system user in group
  `wan-state`, a venv at `/usr/local/lib/.../web/venv`, and a
  `failover-web.service` unit binding `127.0.0.1:8091`. The dashboard shows live
  state, per-interface latency, loss, DNS and HTTP metrics, a 30-day event
  table, three operator buttons (manual failback, force failover, monitor
  restart), a whitelisted 16-key config editor, and on-demand `ping`, `dig`,
  `traceroute` and `mtr` streamed over Server-Sent Events. Documented in
  `docs/how-to/configure-web-ui.md`, `docs/reference/web-api.md` and
  `docs/explanation/web-ui-architecture.md`.

- **`process_manual_action_request()` in `failover-monitor.sh`.** The
  orchestrator polls `${RUNTIME_DIR}/wan-state/manual_action.json` once per main
  loop iteration, validates the payload (action, request_id, ts), enforces a
  30-second freshness window and idempotency through
  `manual_action_processed_ids`, and dispatches to `perform_failover` with
  `manual_failback` or `manual_failover_force` reasons. Those bypass the
  score-based decision gates while still honouring `ANTI_FLAPPING_DELAY`. When
  the file is absent the function costs one `stat()` per iteration, so
  installations without the web UI pay nothing.

- **`systemd/failover-web.{service,sudoers,tmpfiles,nginx.example}`:** a
  hardened unit (gunicorn, 2 workers with 4 threads, the full set of `Protect*`
  knobs), a minimal sudoers fragment covering only
  `systemctl restart failover-monitor.service` and the root-owned config
  installer, tmpfiles directives for `/var/lib/failover-web` and the audit log,
  and an nginx upstream sample with the X-Forwarded-For overwrite rule the
  source-IP extractor relies on.

- **A root-owned validating config installer,**
  `src/web/install-failover-conf.sh`, which re-validates every line of the
  staged `failover.conf` in root context against the same 16-key schema the web
  app enforces, then atomically renames it into `/etc/<project>/failover.conf`.
  This eliminates the attacker-controlled-source privilege-escalation class that
  any "sudo cp" rule would expose.

- **An alerting plugin dispatcher** at `src/web/alerts/dispatcher.py`. The web
  UI shares the same `send_alert <type> <message>` contract documented in
  `plugins/alerting/README.md`, so `none`, `mattermost`, `webhook` or any custom
  plugin work without code changes. The default backend is `none`, which is
  silent.

- **A web UI block in `failover.conf.example`** with commented-out
  `FAILOVER_WEB_CSRF_HOSTS`, `FAILOVER_WEB_LABEL_PRIMARY`,
  `FAILOVER_WEB_LABEL_BACKUP` and `FAILOVER_WEB_PROM_URL`, so operators can tune
  the dashboard without grepping for env var names.

### Changed

- **`failover-monitor.service` provisions the `wan-state` subdirectory** with
  mode `0775` and group `wan-state` through `ExecStartPre=`. The `chgrp` is
  best-effort, since the leading `-` makes it a no-op when the group does not
  exist, so an install without the web UI keeps the previous semantics. Restart
  `failover-monitor.service` once after installing the web UI so the group flips
  into place.

## [0.1.1] - 2026-05-02

### Fixed

- **`_backup_quota_cap()` returned non-zero when no cap applied.** The function
  ended in `[[ -n "$result" ]] && echo "$result"`, leaving exit code 1 whenever
  the snapshot percentage was below the lowest tier (87 %, for instance) or
  `limit_pct` was `null`. Callers running under `set -e` would abort. An
  explicit `return 0` now follows the conditional echo, so the empty-output path
  is a clean success. (`src/lib/performance.sh`)

- **DNS tests were broken by asymmetric routing, fixed by moving to DoH.** All
  DNS health checks used `dig @8.8.8.8 -b $iface_ip` to "bind" to an interface.
  But `dig -b` only sets the source IP; it does not force the outgoing
  interface. With the primary uplink demoted to a higher metric, the kernel's
  destination-based routing sent DNS packets out through the active backup
  carrying the primary's source IP, ISPs filtered the asymmetric flow, and the
  test reported a 999 ms timeout for a perfectly healthy primary.

  That blocked failback indefinitely. `_end_to_end_penalty` deducted 25 points,
  `test_dns_score` returned 0 instead of 25, the recovery counter could never
  reach its threshold, and the orchestrator stayed pinned to the backup.
  Reproduced live: `dig @8.8.8.8 -b $primary_ip` timed out while
  `curl --interface $primary` answered in under 100 ms.

  - `lib/network.sh` gains `measure_dns_doh()`, which uses `curl --interface`
    for real `SO_BINDTODEVICE` binding against `dns.google` and
    `cloudflare-dns.com` over DNS-over-HTTPS, with `--resolve` bootstrap on
    multiple IPs to avoid any system-resolver dependency. Responses are
    validated against HTTP 200, JSON `Status==0` (NOERROR per RFC 8484 and the
    Google JSON API) and `Answer.length>=1`, which also rejects captive-portal
    200s. The old `dig -b` body is kept in a private
    `_measure_dns_dig_legacy()` for emergency rollback.
  - `measure_dns_performance`, `measure_dns_time`, `test_dns_server` and
    `measure_dns_detailed` all now call `measure_dns_doh`. The nslookup fallback
    in `test_dns_server` was removed as a false positive: it ignored the
    interface argument and answered over the active default route, so the backup
    always looked "DNS-OK" even when source-bound dig had timed out. The ISP
    resolver in `measure_dns_detailed` was dropped because it does not speak
    DoH, and its SQLite column is now NULL for new rows.
  - `lib/performance.sh`: `test_dns_score` migrated to `measure_dns_doh`.
  - `config/failover.conf.example` gains `DNS_TEST_METHOD=doh|dig`, defaulting
    to `doh`, which is the fix. Set it to `dig` for a soft rollback.

  Verified live: failback succeeded within minutes of the deploy, and DNS
  latency in `wan_quality.prom` dropped from 999 and 1500 ms to 80 to 200 ms.

### Changed

- **`CPUQuota` defaults raised** for all four services. The previous 5 to 20 %
  was tight enough to throttle the bursty subprocess work (`ping`, DoH `curl`,
  `jq`) by 80 to 98 % on a 4-core Pi 5, even though absolute CPU usage was only
  a few percent. That throttling distorted the numbers the metrics collector
  wrote into `wan_quality.prom` by an order of magnitude, which fed back into
  the orchestrator's end-to-end penalty and blocked failback. The bug was only
  visible because the DoH fix exposed how unrealistic the throttled
  measurements were.

  - `failover-metrics-collector.service`: 10 to 50 %, subprocess-heavy
  - `route-guardian.service`: 10 to 50 %, a real-time safety net with dense bursts
  - `failover-monitor.service`: 50 to 75 %, parallel scoring rounds
  - `nmcli-failover-monitor.service`: 20 to 50 %, event handling

  Each service file carries an inline comment explaining why. On a dedicated
  router box you can drop `CPUQuota` entirely. `MemoryMax` is unchanged and
  still useful as a leak guard.

- **A three-layer anti-stall safety net** for the rare case where the primary
  loses layer-1 carrier (cable unplugged, modem powered off) at the same moment
  the backup score sits exactly at the both-degraded threshold, for example 25,
  hit by the end-to-end DNS penalty during an LTE throttling window. In that
  combination every score-based failover path classified the backup as not
  viable, and `both_degraded` pinned the orchestrator on a dead primary, leaving
  the routing table without a default route. Three coordinated patches:

  - `failover-monitor.sh` gains a **carrier-aware pre-check** in
    `check_failover_conditions()`. When the primary has `carrier=0`, the backup
    has `carrier=1` and the backup score is above 0 (so not quota-blocked), it
    triggers an unconditional failover before any score-based path runs.
    Layer-1 state is binary and unambiguous, so it overrides the heuristics. The
    score-above-zero guard preserves the `LAST_RESORT` quota-cap protection.
  - `lib/routing.sh` gains a **carrier-aware short-circuit** in
    `_swap_primary_metric()`. The metric demotion fails with "Network is
    unreachable" when the primary has `carrier=0`, which trips
    `safe_route_change()` rollback and emergency recovery, all of which fail
    too. It now keeps the NetworkManager metric persist in step 1, applied on
    the next DHCP cycle, skips the kernel route add when carrier is 0, cleans up
    stale routes defensively and returns success. The kernel auto-prefers the
    backup since there is no competing primary route.
  - `route-guardian.sh` gains **default-route vacuum detection** as an
    independent safety net. After the regular checks, if
    `total_default_routes == 0`, it restores via the backup (preferred when the
    primary is layer-1 dead) or the primary as fallback, and sends a
    `ROUTE_VACUUM_RECOVERED` alert. Lockfile coordination is unchanged, so there
    is no race with the orchestrator during legitimate failovers.

  Together these form a detect, execute, safety-net chain. Verified against a
  real DSL outage where the pre-check fired and the routing-library
  short-circuit was needed to let it succeed.

### Internal

- **CI green across all jobs.** Resolved bashate trailing whitespace (two
  `while ...; do true; done` patterns rewritten to multi-line form), `ruff check`
  (an unused `time` import and two f-strings without placeholders), `ruff
  format`, and shellcheck warnings (`unset` array-key quoting in
  `lib/performance.sh`, declare/assign separation and a trap-quote disable in
  `lib/routing.sh`, and `# shellcheck disable=SC2034` for public-API constants
  consumed by sourcing scripts). No behaviour changes from any of these. The
  only behaviour change in this release is the `_backup_quota_cap()` return-code
  fix above.
- **The bats suite is fully green.** Tests 12 and 17 in
  `tests/unit/test_quota.bats` were red as a symptom of the
  `_backup_quota_cap()` bug. With the fix the suite is 23 of 23.

## [0.1.0] - 2026-04-27

First public alpha, extracted from a private homelab dual-WAN failover stack
that has been running in production since August 2025.

### Added

- **Four-service architecture:** `failover-monitor`, `nmcli-failover-monitor`,
  `route-guardian`, `failover-metrics-collector`.
- **Event-driven detection** through `nmcli monitor` with sub-second `SIGUSR1`
  hand-off to the orchestrator, plus a polling fallback for environments without
  NetworkManager state changes.
- **Score-based health checks,** 0 to 100 per interface, combining latency,
  packet loss, DNS resolution time and gateway reachability.
- **Anti-flap and hysteresis** with separate failover and failback thresholds,
  a minimum backup-link dwell time and stable-duration gating.
- **A route guardian** that enforces metric correctness against `active_wan` as
  ground truth, with sub-second cleanup of duplicate routes.
- **Lockfile coordination** in `PID_TIMESTAMP` format, keeping the route
  guardian from racing the failover orchestrator during emergency switches.
- **Plugin slots:** `plugins/alerting/` with `none`, `mattermost` and `webhook`;
  `plugins/quota-providers/` with `no-op`, `netgear-lm1200` and
  `custom-template`.
- **Prometheus textfile output** plus a SQLite event history for after-the-fact
  incident analysis.
- **Diataxis documentation:** tutorial, how-to, reference, explanation.
- **Tests:** bats-core unit tests with `tests/mocks/` for `ip`, `nmcli` and
  `ping`.
- **CI:** shellcheck, bashate, bats, ruff.

[Unreleased]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.2...HEAD
[0.9.2]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.8.0...v0.8.1
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
