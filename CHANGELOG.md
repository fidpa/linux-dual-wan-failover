# Changelog

All notable changes to `linux-dual-wan-failover` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.7] - 2026-08-29: The README measured against the code

The detailed documentation under `docs/` has been kept honest release by
release. The README had not: it still described the failback design of v0.8.x,
three timings that no code path produces, and a Web-UI security posture that
listed every defence except the missing one. This section is the result of
reading it line by line against `src/`, the way `docs/explanation/` was read in
v0.9.1 and v0.9.3.

Documentation only. No code, configuration or on-disk format changed.

#### Documentation corrected against the code

- **The README told operators to wait for a primary score above 80 that the
  daemon never checks.** Its "Asymmetric thresholds prevent flapping" section
  described a 20-point hysteresis gap: fail over below 60, fail back above 80.

  That path was removed in v0.4.0. It required a primary score above 90 while
  the `MIN_FAILBACK_SCORE` gate above it already returned for every score of 60
  or more, so it was unreachable before it was deleted. Failback is governed by
  `RECOVERY_THRESHOLD` (20), `MIN_BACKUP_TIME` (3600 s), `MIN_STABLE_DURATION`
  (900 s) and `MIN_FAILBACK_SCORE` (60), which the section now lists as a table
  of gates.

  `docs/explanation/anti-flapping.md` was corrected in that same release and has
  described the time-domain gates correctly ever since. The README kept the
  score-domain version through the fifteen tags that followed, so anyone
  debugging a failback that would not fire had two documents in front of them
  and no way to tell which one the daemon agreed with.

- **Three timing claims were faster than the code that produces them.** Event
  detection was described as having "confirmed the link is really down" within
  500 ms. 500 ms is the poll interval of `wait_for_link_down()` in
  `nmcli-failover-monitor.sh`, which polls against a five-second timeout and
  writes the event off as a false alarm if the link returns first.
  `route-guardian` was said to delete duplicate routes "within one second of
  them appearing"; it sweeps once per `ROUTE_GUARDIAN_CHECK_INTERVAL` (10 s by
  default) and removes what it finds in that same pass. The comparison table
  claimed a failover time of under 5 s while the results table two sections
  below reported the measured 4 to 6 s.

- **The Web-UI section listed the dashboard's defences and omitted that it has
  no login.** It enumerated the CSRF check, the rate limit and the audit log,
  which reads as a security posture rather than as what it is: defence in depth
  behind a perimeter the reverse proxy has to provide. The section now states
  that there is no authentication, that the proxy is the boundary, and what to
  terminate there when the deployment is not a trusted LAN. The reasoning was
  already written down in `docs/explanation/web-ui-architecture.md`; the README
  simply never pointed at it. The rate limit was also given as a flat
  "1 / 60 s per source-IP": the buckets are per (endpoint, source IP) and run
  from 10 s on `/api/diag` to 300 s on a monitor restart.

- **Production runtime was stated twice with numbers that contradicted each
  other.** "8+ months" appeared in the introduction and the compatibility
  table, against "12 months (Aug 2025 to Aug 2026)" in the results table. All
  three now derive from the August 2025 start date.

- **The comparison table treated pfSense and UniFi as one closed product.**
  pfSense CE is Apache-2.0 and mwan3 is shell rather than the kernel-tied C the
  table claimed. The failover-time row also mixed one measured column with
  three taken from other projects' documentation without saying so; a sentence
  above the table now says which is which.

#### Editorial

- **Typography and repetition.** Em-dashes, en-dashes, arrows and the
  multiplication sign are gone from the prose, bringing the README in line with
  the changelog convention adopted in v0.9.2. The ASCII-art diagram keeps its
  box-drawing characters, which that convention exempts. Removed with them: the
  maintained `~12.5 kLOC` figure, the "~3x higher" failback failure rate that
  named no counting basis, a duplicated hardware description, and the second of
  two "contributions welcome" closings. The two plugin directory listings now
  show what those directories actually contain.

## [0.9.6] - 2026-08-28: Release titles come from the changelog headings

Every published release carries a headline in its title, but no changelog
heading did. The titles were typed by hand at `gh release create` and existed
only on GitHub, so a corrected section left its title untouched, and nothing in
the repository recorded what the title was supposed to say. The headlines are
now part of the headings they belong to, and a `release.yml` reads them from
there.

Documentation and CI only. No code, configuration or on-disk format changed.

### Added

- **Pushing a version tag publishes the release.** `.github/workflows/release.yml`
  cuts the changelog section for the tag, uses it as the body, and takes the
  title from the same heading, so the two can no longer disagree. It refuses to
  publish when the section is empty, warns in the workflow log when a heading
  carries no headline instead of quietly falling back to the bare tag name, and
  stops at the link-reference block so the oldest section does not paste those
  links into its body.
- **A tag whose number the `VERSION` file does not carry fails the workflow.**
  `VERSION` has been the single source for the running version since 0.7.1;
  the check runs before the release is cut, so a mismatch stops the publication
  rather than shipping a release that reports the previous version at runtime.

### Changed

- **Each section heading carries the headline of its release.** The form is
  `## [X.Y.Z] - YYYY-MM-DD: <headline>`. The headlines are the ones already
  published on the release pages, moved into the repository unchanged; none was
  invented for this release.
- **The 0.7.1 section sits above 0.7.0**, where its date places it. It was the
  only section out of order.

### Upgrade notes

Nothing to do. This release changes changelog text and adds a workflow.

## [0.9.5] - 2026-08-27: Editorial sections state what holds, not how much did not

A release page says what now holds. How long something was wrong and how many
statements a check did not survive address the maintainer, not the reader, and
they push the corrections themselves into the background. The rule this project
follows now is that the tally stays out of the release page and its title, while
every correction keeps its own entry, with its effect and its anchor in the code.

Documentation only. No code, configuration or on-disk format changed.

### Changed

- **The editorial sections open with what was put right, not with a count of
  what was wrong.** The introduction to 0.9.3 no longer carries the number of
  corrected statements or the observation that earlier passes had missed them,
  its entry on code anchors no longer reports how many entries carried one
  before, and the 0.9.2 note about the comparison links drops the aside on where
  the omission came from. Every individual correction stays exactly where it
  was, with its effect and its file, function or tag reference.

- **The published title of v0.9.3 names the pass, not its yield.** It carried a
  count of corrected facts, which made the tally the first thing a visitor read
  in the release list and on the release page. The title now reads
  `v0.9.3: Entries lead with the effect`.

### Upgrade notes

Nothing to do. This release changes changelog text and one release title.

## [0.9.4] - 2026-08-27: Threat-model note no longer names a private repo

Documentation only. One sentence in the web-UI architecture document named a
private predecessor repository by name, which told the reader where a document
they cannot open used to live.

### Fixed

- **A public document no longer points readers at a repository they cannot
  reach.** The threat-model section of
  `docs/explanation/web-ui-architecture.md` named the private predecessor
  repository as the place where the full model lived. It now says the model was
  developed in a predecessor project and is not public: the same information
  without the dead end, and without publishing the name of a repository nobody
  outside can open. The eight scenarios and their mitigations are unchanged,
  and the table below that sentence still carries the ones that matter here.

## [0.9.3] - 2026-08-27: Entries lead with the effect

A second editorial pass, this time against a written style guide rather than by
feel. 0.9.2 had removed the typographic clutter; this one changes what the
sentences say first. It also corrects statements of fact where the code
contradicted them; they are listed below.

The rules now live outside this repo and apply to all of them. They were settled
after reading Common Changelog, the Kubernetes release-notes guide and Keep a
Changelog, and after an external review of a sample section.

### Fixed

#### Statements corrected against the code

- **The 0.7.0 entry claimed four log calls where the code had one.** It read
  "All four of its `log` calls wrote to stdout". Counting them in
  `git show v0.6.0:src/lib/network.sh` gives exactly one, in the branch that
  runs when `get_gateway()` finds no default route. The rewritten entry names
  that branch as the condition, because the failure needed it: the warning line
  and the fallback JSON went to the same stream, and the collector's
  `json.loads()` then saw the warning first.

- **The same entry overstated who was affected.** It implied the failure applied
  wherever `LOG_TO_STDOUT` was active, which is the default. It applied only to
  an interface with no default route. The entry now says so.

### Changed

- **Entries lead with what changed for the operator, not with what changed in
  the code.** The bold first sentence of each entry now states the effect and the
  paragraph below it gives the cause; previously many entries opened with a
  function name and left the consequence to the reader. The clearest case is the
  0.4.0 emergency-recovery entry, which used to begin "Emergency route recovery
  was a silent no-op" and now begins "Emergency route recovery always ended at
  'Could not restore any route'".

- **Tense follows what is being described.** Past tense for what went wrong,
  present tense for what now holds, instead of forcing both into one form.

- **Entries about code name a place in the code.** A file, a function or a config
  variable, with public names before internal ones, so a claim can be checked
  against the source.

- **Three entries in 0.5.0 and 0.2.0 that were bare identifiers got a sentence.**
  "`event_id` column" and "`src/lib/event-id.sh`" said what was added but not
  what it did.

- **The 0.7.0 entry about the metrics collector was folded into the entry above
  it.** It described a defect that existed and was fixed within the same release,
  so measured against 0.6.0 there was nothing to report. New rule: an entry
  describes a difference from the last published tag.

- **New behaviour states its limits.** 0.7.0 now says what happens when no
  `CHECK_IPS` address answers (sentinel values, no fallback to the gateway) and
  gives the `PING_TIMEOUT` default that makes its 50-second worst case add up.

### Upgrade notes

Nothing to do. No code, configuration, on-disk format or documentation outside
`CHANGELOG.md` changed in this release, and all 16 GitHub release bodies were
re-published from the rewritten sections.

## [0.9.2] - 2026-08-27: Changelog and release notes rewritten for readability

Editorial pass over the changelog and every GitHub release. No code, config or
documentation outside this file changed.

### Changed

- **Every changelog entry was rewritten for readability.** The em dash had been
  standing in for colons, parentheses, causal clauses and mid-sentence asides,
  often several times in one paragraph, so a reader had to guess which function
  was meant each time. All of them are gone, along with the remaining
  typographic characters (en dashes, ellipses, arrows), leaving plain ASCII.
  Long sentences were split and passages that restated the preceding line were
  cut. Every measured number, file path, function name and threshold is
  unchanged: this is a rewording, not a revision of the record.

- **Section headings use `## [X.Y.Z] - YYYY-MM-DD`** with a plain hyphen,
  matching the Keep a Changelog examples. They previously used an em dash.

- **All 15 GitHub releases were re-published from the rewritten sections,**
  restoring the convention that a release body is its changelog section
  verbatim. Release titles changed from `vX.Y.Z - Headline` to `vX.Y.Z:
  Headline`, and the two releases that carried no headline at all (0.1.0 and
  0.1.1) got one. The v0.1.0 release had an empty body and now carries its
  section.

  Two releases keep hand-written bodies for reasons that predate this pass:
  v0.2.1 has no changelog section of its own by design, since the feature is
  documented under 0.2.0, and v0.5.1 keeps its note about having been published
  retroactively.

### Fixed

- **The comparison links at the foot of the file skipped 0.9.1.**
  `[Unreleased]` still pointed at `v0.9.0...HEAD` and no `[0.9.1]` line existed.

## [0.9.1] - 2026-08-27: The failback stability window does not survive a dip

Documentation only. An audit of the anti-flapping docs against the code found
that `STABILITY_RESET_THRESHOLD` does not do what the comments, the prose and
the web UI all said it did: it never affects when failback happens. The daemon
behaves exactly as before. Only the descriptions change, and they were wrong in
a way that would have sent an operator tuning the wrong knob mid-incident.

### Fixed

#### Documentation corrected against the code

- **Tuning `STABILITY_RESET_THRESHOLD` never changed when failback happened.**
  The docs described a two-tier design in which scores between the reset
  threshold (50) and `FAILOVER_THRESHOLD_DOWN` (60) kept the failback stability
  window open, so a borderline dip would not cost the primary its accumulated
  stability.

  The code never worked that way. Any round in which the primary scores below 60
  zeroes `consecutive_recoveries`, and that counter is the first gate in
  `is_failback_needed()`. It has to climb back to `RECOVERY_THRESHOLD` (20)
  before the stability window is read at all. Once the primary recovers, the
  window restarts from that moment whatever the threshold did. All the threshold
  decides is whether a warning gets logged.

  The real behaviour is stricter than the old description, since the window
  restarts after every dip below 60 rather than only below 50. That is the safe
  direction, which is why this is documented instead of "fixed": making the
  window genuinely survive a dip would shorten the stability actually required
  before returning to the primary. Corrected in
  `docs/explanation/anti-flapping.md`, in the comment block in
  `failover-monitor.sh`, and in the field description in `config_reader.py` that
  the web UI shows next to the input. The "what not to touch" list now points at
  `MIN_STABLE_DURATION`, which does change failback timing.

- **The journal told operators the stability window survived a dip.** The
  per-round debug line printed `window_kept=yes` whenever the primary scored
  between 50 and 59, which is the one thing that is not true. The field is now
  `reset_warning=` and reports what the comparison actually decides. Log text
  only; no gating or state transition is affected.

- **A code comment still promised a 15-minute emergency cooldown.** The
  preconditions block for `is_emergency_failback_needed()` said `(15min)` while
  `EMERGENCY_FAILBACK_COOLDOWN` has defaulted to 3600 seconds since 0.6.0, which
  raised it from 900. It was the last place in the repo still saying 900. The
  same block now states `EMERGENCY_FAILBACK_DEGRADED_CHECKS` in the unit it
  counts (fresh collector readings, not poll intervals) and gives
  `EMERGENCY_FAILBACK_MIN_BACKUP_TIME` its default of 1800 seconds.

## [0.9.0] - 2026-08-25: Failback guard, dead code removed, restart button

Code quality: one bug fix, dead code removed, some DRY work across the Bash
daemons and the Flask web UI. The only new feature is a restart-monitor button.

### Fixed

- **A service restart could let failback happen immediately.**
  `is_failback_needed()` defaulted `failover_to_backup_time` to `0` when the
  state file was gone, which made "time on backup" the seconds since the Unix
  epoch and satisfied `MIN_BACKUP_TIME` on the spot. The sister function
  `is_emergency_failback_needed()` already guarded against this. Both now share
  the same "unknown means block" logic.

- **`is_numeric()` accepted or rejected trailing dots depending on which file
  was sourced last.** Two definitions coexisted, one in `common.sh` and one in
  `network.sh`, with different semantics. Unified into a single definition in
  `common.sh`.

- **A `chmod` failure was reported as an unset `STATE_FILE`.**
  `[[ ... ]] && { mkdir; chmod; } || log_warning` fires the warning branch when
  anything inside the group fails, not only when the test fails (SC2015).
  Replaced with a plain `if/then/else`.

### Added

- **Restarting the monitor no longer requires an SSH session.**
  `POST /api/restart-monitor` with rate limiting (one call per 5 minutes), CSRF
  protection and audit logging, plus a dashboard button. Replaces the previous
  "run `systemctl` on the CLI" instruction.

### Removed

- **The cache framework had never cached anything.** Its functions
  (`cached_ping`, `init_cache_structures`, `invalidate_cache` and the rest) ran
  inside `$(...)` subshells, so every write to the in-memory cache was discarded
  when the subshell exited. Verified in production: a permanent "0% hit rate
  (0/0), 0 entries". Callers now use `perform_ping_test` directly, and
  `performance.sh` lost 349 lines.

- **Four functions in `network.sh` had no callers** outside their own
  definitions: `compare_interfaces`, `measure_dns_time`, `measure_http_time`,
  `test_bandwidth`.

### Changed

- **`_lock()` became `flock_path()`** and moved out of `config_writer.py` and
  `manual_action_writer.py` into `writers/__init__.py`.

- **SSE slot reservation lives in one place.** `_try_reserve_sse()` in `app.py`
  replaces two identical ten-line blocks.

## [0.8.1] - 2026-08-11: Executable bit restored on install.sh and the service scripts

Ten scripts had lost their executable bit. Mode-only change, no content diff.

### Fixed

- **A fresh clone could not run `install.sh`.** It is meant to be started
  directly (`sudo ./install.sh`, as the README says) and would have failed with
  "Permission denied". `chmod 755` is restored on it, on the four
  systemd-invoked service scripts (`failover-monitor.sh`,
  `nmcli-failover-monitor.sh`, `route-guardian.sh`,
  `failover-monitor-health-check.sh`), on `failover-metrics-collector.py`, on
  `plugins/quota-providers/netgear-lm1200/collect-quota.py` and on the three
  `tests/mocks/{ip,nmcli,ping}` stand-ins. Confirmed with `git diff --summary`:
  `mode change 100644 => 100755` only.

## [0.8.0] - 2026-08-08: Real mutual exclusion for route changes

Four processes mutate the same routing table, and until now nothing actually
stopped them doing it at the same time. The `failover-in-progress` marker looked
like it did, since route-guardian checks it and skips its cycle. But the check
happens once, at the top, and the guardian keeps changing routes for the rest of
that cycle. A failover starting a few milliseconds after the check runs inside
the guardian's window, and the guardian then restores the old metric or deletes
the new route as a duplicate, working from state it read before the swap.

This release puts a real `flock` underneath the marker and fixes three latent
bugs found while auditing the same code paths. Latent in the precise sense: each
one is currently masked by an unrelated implementation detail and would start
firing the moment that detail changed.

No incident prompted this. It came out of a review, which is worth saying
plainly, because the project's own documentation had described the marker as
sufficient. The argument in `docs/explanation/state-file-ownership.md` was
internally consistent and still wrong: it reasoned about contention over the
file, where the contention is over the routing table.

### Added

- **Route changes are now mutually exclusive across all four services.**
  `/run/failover-route.lock` is held with `flock` on a fixed descriptor. The
  orchestrator holds it across its whole route transaction; route-guardian and
  the nmcli emergency path take it around each `ip route` call. A guardian that
  cannot get the lock skips its repair rather than waiting, so a stuck holder
  delays repairs instead of queueing them.

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

- **Setting `RuntimeDirectoryPreserve=restart` would have killed failback and
  every manual action.** The `active_wan` file holds interface names (`eth0`,
  `lte0`), because route-guardian, `routing.sh`, the metrics collector and the
  shell aliases all expect them. The restart path loaded that value verbatim
  into `current_wan`, where every guard compares against `primary` and `backup`.
  Today this stays harmless only because `RuntimeDirectory=` wipes the state
  directory on every restart, so the detection branch runs instead. The value is
  now translated on read.

- **A second primary event could restart `MIN_BACKUP_TIME` from zero while
  already on backup.** Every branch of the USR1 handler switched primary to
  backup unconditionally, so an event arriving after the 60-second instant
  cooldown re-ran the whole transaction and rewrote `last_failover_to_backup`.
  The new guard sits after the both-degraded branch, so that alert still fires
  while on backup.

- **A frozen collector reading kept forcing instant failovers after the link had
  recovered.** `get_interface_packet_loss` read `wan_quality.prom` with no age
  check, unlike every other consumer of that file, and its value feeds
  `is_critical_packet_loss`, which bypasses `FAILURE_THRESHOLD`. It now honours
  `WAN_QUALITY_PROM_MAX_AGE` and falls back to live measurement.

- **A failed emergency route change re-armed route-guardian mid-transaction.**
  The success path checked marker ownership before removing it; the failure path
  removed whatever marker happened to be there, including one belonging to
  another process.

- **Losing both default routes at once left the backup unrepaired for 60
  seconds.** A NetworkManager restart does exactly that, and with one shared
  marker, repairing the primary locked out repairing the backup, which is the
  window where the backup path matters. Rate limiting is now per interface.

### Changed

- **`EMERGENCY_FAILBACK_DEGRADED_CHECKS` counts collector readings, not
  orchestrator rounds. Default 20 becomes 6.** The counter advanced once per
  cycle (15 s) while the DNS value it reads refreshes every 36 to 52 seconds, so
  the same sample was counted up to four times and a single outlier could reach
  the threshold alone. The 20 from 0.6.0 was a workaround for exactly this,
  picked to approximate six independent samples. The counter now advances only
  when `wan_quality.prom` has been rewritten, so the number means what it says.
  Both defaults encode the same intent: roughly five minutes of evidence.

- **Setting `PING_TIMEOUT` in the config finally has an effect.** It,
  `DNS_TIMEOUT` and `HTTP_TIMEOUT` were declared `readonly` in `network.sh`,
  which silently overwrote whatever the operator set, because the units pass
  `failover.conf` through `EnvironmentFile` and those values arrive as
  environment variables before the script runs. Setting `PING_TIMEOUT=7`
  produced no warning and no change. Defaults are unchanged (2, 3 and 5
  seconds), so runtime behaviour is identical.

  One caveat before raising it: `PING_TIMEOUT` acts as a multiplier, not a
  wrapper. `measure_packet_loss` caps at `PING_TIMEOUT` times the count and
  `measure_path_quality` at samples plus twice `PING_TIMEOUT`, both of which push
  against the metrics collector's 30-second subprocess budget.

## [0.7.1] - 2026-08-03: Version single-sourced, documentation corrected against the code

The orchestrator had been announcing `Failover Monitor v0.1.1` on every start
since May. Nine releases of drift, because `failover-monitor.sh` carried its own
`readonly SCRIPT_VERSION="0.1.1"` literal that nobody bumped alongside the tag.
A journal naming a version that has not existed for months cannot answer the
first question of any incident review: which code is running here?

The same review prompted an audit of the docs against the code. It turned up a
wrong path in the stale-lock recovery procedure and a debugging recipe that
reproduced the exact false positive the 0.1.1 DoH migration was written to
eliminate.

### Fixed

- **The daemon now logs the version it actually is.** A `VERSION` file at the
  repo root is the single source; `common.sh` resolves it into
  `PROJECT_VERSION`, `failover-monitor.sh` derives `SCRIPT_VERSION` from that,
  and `install.sh` ships the file into `${LIB_DIR}`. The resolver probes the
  repo layout and the installed layout, and falls back to `unknown` rather than
  failing, because a missing version file must never stop the failover daemon
  from starting.

- **The stale-lock recovery step in the runbook operated on a path that never
  exists.** README, `docs/how-to/debug-failover.md` and
  `docs/explanation/state-file-ownership.md` all gave the lockfile as
  `/run/linux-dual-wan-failover/failover-in-progress.lock`. It is
  `/run/failover-in-progress.lock`, deliberately at the `/run` root, because four
  services with four different `RuntimeDirectory=` trees have to see it. That
  placement also means the lockfile survives a restart, which is what its
  `PID_TIMESTAMP` staleness check is for. Both facts are now documented where the
  path is.

- **The runbook's DNS probe would have reported a healthy primary as dead.** It
  recommended `dig -b`, the measurement error the DoH migration removed in 0.1.1:
  `dig -b` sets the source address but cannot force the outgoing interface, so on
  a demoted primary the packets leave through the active backup and time out.
  Replaced with the `curl --interface` DoH call the scoring actually performs,
  including the `Status` and `Answer` validation that filters captive portals.

### Changed (documentation)

Corrected against the implementation:

- `state-file-ownership.md` credited the lockfile to `nmcli-failover-monitor`
  "only on emergency failover", true until 0.4.0, when `safe_route_change()`
  began writing the lock on every route change.
- `web-ui-architecture.md` claimed a 16-key config whitelist. It is 15, in both
  `config_reader.py` and `install-failover-conf.sh`.
- `metrics.md` described `wan_quality_score` as a composite "of the five metrics
  above" while seven rows preceded it. Replaced with the configured weights
  (latency 25 %, loss 25 %, DNS 20 %, jitter 15 %, HTTP 15 %) and a note that the
  gateway metrics are reported but do not feed the score.
- `architecture-overview.md` predated 0.5.0 and listed neither the
  correlation-id state files nor the optional `failover-web` unit and
  health-check timer.
- The `/api/history` sample in `web-api.md` predated the `event_id` column.
- `install-from-source.md` omitted `src/tools/`, so a manual install left
  `trace-failover.sh` absent. It now also covers the `_schema` directory and the
  web UI leftovers (sudoers, tmpfiles, logrotate, sbin helper, system user) in
  the uninstall procedure.
- `01-quickstart.md` referred to a Docker simulation that
  `safe-failover-testing.md` does not contain.
- `docs/README.md` promised "see Explanation docs below" with no such list and
  omitted the web UI documentation entirely.
- `config.md` documented neither `DNS_TEST_METHOD`, which `scoring.md` relies on,
  nor `WAN_QUALITY_PROM_MAX_AGE`. Both added, with a note on why `dig` is a
  rollback path and not a fix.
- `failover.conf.example` carried an unfilled placeholder ("Default since
  v0.x."). DoH became the default in 0.1.1.
- README: the static `Status: Alpha` badge became a shields.io badge tracking the
  latest tag, the Status section no longer hardcodes a version (it claimed 0.1.1
  while contradicting its own runtime table), and the source size was corrected
  from about 8.5 to about 12.5 kLOC, tests excluded.

### Added

- `.gitignore` now covers the private working files the publishing rules require
  to stay out of the repository (`CLAUDE.md`, `.claude/`, `TODO.md`, `*_POST.md`).
  It previously caught only `LINKEDIN_POST.md`.

### Upgrade notes

No configuration or on-disk format changes. Existing installations keep working.
Re-running `install.sh` is what places the `VERSION` file; until then the daemon
logs `v unknown` instead of a number, and nothing else reads it.

## [0.7.0] - 2026-08-02: WAN quality measured on the real internet path

WAN quality was measured against the wrong endpoint. `test_wan_quality()` probed
the interface gateway, which on this router is the DSL modem or the LTE stick one
hop away, so latency, packet loss and jitter described the link to that device
rather than the uplink behind it.

Measured on the production router: the LTE backup reported 1.32 ms, 0 % loss and
0.54 ms jitter, the DSL primary 0.23 ms, 0 % and 0 ms. Over the same period the
DNS probe, which does traverse the uplink, timed out on 5.7 % of its attempts
against that same backup and showed a p95 of 973 ms.

Latency, loss and jitter are configured at 25 %, 25 % and 15 % of the composite
score, so those three inputs decide 65 % of it. An idle backup could therefore
sit near the top of the scale until a failover put real traffic on it.

### Changed

- **The backup link no longer scores near 100 while its uplink is degraded.**
  `test_wan_quality()` now probes the first responding `CHECK_IPS` entry instead
  of the interface gateway, so latency, loss and jitter describe the internet
  path. `WAN_QUALITY_TARGET_MODE` accepts `internet` (new default) or `gateway`
  and restores the old target selection; it does not restore the other two
  changes in this section. The metrics collector now sources the operator config,
  without which neither that switch nor a custom `CHECK_IPS` would have reached
  its measuring subprocess.

  If no `CHECK_IPS` address answers, `_pick_probe_target()` returns empty and
  `measure_path_quality()` reports its sentinel values (999.99 ms, 100 % loss)
  rather than falling back to the gateway. An interface that cannot reach any
  probe target scores as unreachable, which is the safe direction but will look
  like an outage on a link that only blocks ICMP.

- **A slow link no longer risks stalling the metrics collector.**
  `measure_path_quality()` derives latency, loss and jitter (`mdev`) from one
  `ping` run against the chosen target. The three previous series (5, 10 and 10
  sequential `ping -c 1` calls) described three different moments, and at the
  default `PING_TIMEOUT` of 2 seconds their worst case of 25 timeouts came to
  50 seconds, past the collector's 30-second subprocess budget. When that budget
  was exceeded the run produced nothing and `wan_quality.prom` kept its previous
  contents until the next successful pass.

### Fixed

- **WAN quality metrics were dropped for any interface whose gateway could not
  be determined.** In that branch `test_wan_quality()` logged a warning to stdout
  and then emitted its fallback JSON on the same stream. The metrics collector
  parses that stdout with `json.loads()`, so the warning line preceded the
  document and raised `JSONDecodeError: Extra data`. The branch is reached
  whenever `get_gateway()` finds no default route on the interface. `common.sh`
  states the rule this broke: a function whose stdout is captured must not log
  without `>&2`. All log calls on this path now redirect to stderr, covered by a
  regression test that asserts the payload starts with `{` and carries no log
  markers.

## [0.6.0] - 2026-08-02: Emergency-failback recalibration and manual-failback feedback

A flapping primary link in production, meaning repeated WAN-session loss with
layer 1 intact, exposed the emergency-failback path as far too eager. Separately,
a manual failback that "did nothing" turned out to be three defects stacked on
top of each other.

The measurements behind the recalibration: the backup uplink was not throttled
(0.7 % of quota used, 27 Mbit/s down). Its 2.4 Mbit/s upstream saturated under
load, and only the upstream direction moved DNS latency at all. Idle it ran 164
to 244 ms, downlink-saturated 182 to 252 ms, uplink-saturated 321 to 1231 ms.

### Changed

- **The emergency escape hatch had become the normal failback path.** With the
  old defaults every cycle on a flapping primary ended exactly at the 600-second
  floor, handing traffic back to a link that was still broken.
  `EMERGENCY_FAILBACK_MIN_BACKUP_TIME` goes from 600 to 1800 s,
  `EMERGENCY_FAILBACK_DEGRADED_CHECKS` from 6 to 20 and
  `EMERGENCY_FAILBACK_COOLDOWN` from 900 to 3600 s. The original "backup is up
  but end-to-end dead" case stays covered: that degradation ran for over 90
  minutes without a break.

- **`EMERGENCY_FAILBACK_DEGRADED_CHECKS` did not mean what its name suggested.**
  The counter ticks once per `CHECK_INTERVAL` but reads a value refreshed on the
  collector's slower cycle, so the old default of 6 checks, nominally 90 seconds,
  covered fewer than two independent samples. Documented here; corrected in
  0.8.0.

### Fixed

- **Manual failback and force-failover ignored the anti-flapping cooldown.** The
  shipped config had always documented `ANTI_FLAPPING_DELAY` as covering failback
  and manual actions, but the code matched only `reason == "failback"`, so
  `manual_failback` and `manual_failover_force` bypassed it.

- **For ten minutes after a reboot, every failback and manual action was
  suppressed.** `last_failover_mono` starts at zero and `get_monotonic_time()`
  reads `/proc/uptime`, so with no failover yet the daemon computed `uptime - 0`
  and logged a misleading "last failover was N seconds ago". Now guarded with
  `[[ $last_failover_mono -gt 0 ]]`, mirroring the emergency path.

- **A service restart satisfied every minimum-time-on-backup gate at once.**
  `RuntimeDirectory=`, without `RuntimeDirectoryPreserve=`, wipes the state
  directory including `last_failover_to_backup`, and readers defaulted the
  missing value to `0`, turning "time on backup" into "seconds since the epoch".
  That cleared both `MIN_BACKUP_TIME` and `EMERGENCY_FAILBACK_MIN_BACKUP_TIME`
  and made the prolonged-backup alert fire immediately claiming roughly 496 000
  hours. The daemon now reseeds the timestamp at startup when it comes up on
  backup, and the emergency path refuses to act on an unknown value.

- **The web UI promised actions the daemon then discarded.** `POST /api/failback`
  and `POST /api/force-failover` returned `202 "submitted"` for requests the
  daemon dropped with nothing but a journal line. Both now return
  `409 {"status": "cooldown", "remaining_seconds": N}` while the cooldown runs.
  The check is advisory, the daemon stays authoritative, and it fails open on a
  missing or unreadable timestamp.

- **Error responses produced no visible reaction in the dashboard.** htmx swaps
  response bodies on 2xx only, and the handler set a CSS class without writing
  the body, so `403` (expired CSRF token), `409` and `429` looked like nothing
  had happened. The pane now renders the response text for any status of 400 or
  above.

### Added

- `config_reader.effective_int()`, a single-key config lookup with the daemon's
  base-then-override precedence, so the web layer reasons about the same numbers
  the daemon uses.
- Three integration tests covering the cooldown branch: active cooldown returns
  409 without writing a request file, expired cooldown returns 202, unreadable
  timestamp fails open to 202.

## [0.5.1] - 2026-07-16: Logging defaults ordering fix

A field incident in production, where a captured function's log line corrupted a
`sed` expression during a real DSL outage, prompted an audit of the logging setup
here. The code was clean, but the audit surfaced one latent ordering bug.

### Fixed

- **`LOG_TO_STDOUT` ran as `true` while the code claimed a `false` default.** In
  `common.sh` the logging defaults (`LOG_FILE`, `LOG_TO_JOURNAL`,
  `LOG_TO_STDOUT`) were assigned after the toolkit's `logging.sh` was sourced,
  and the toolkit initialises them with `:=` at source time, so those assignments
  were dead code wherever the toolkit was installed. They now run before the
  `source` line.

  The effective default is now an explicit, documented `true`. The systemd units
  use `StandardOutput=journal`, and stdout is the only path into the journal when
  the toolkit is loaded, which is how the debug guide reads logs. No behaviour
  change: this pins what the services have always relied on and keeps it stable
  against future toolkit defaults. Overrides via environment or `EnvironmentFile`
  work as before.

## [0.5.0] - 2026-06-29: Failover correlation-id tracing

Correlation-id tracing for failovers. Every failover now carries a single id that
travels through all four services and the metrics database, so one event can be
reconstructed end to end.

### Added

- **One failover can now be reconstructed from a single id.**
  `src/tools/trace-failover.sh` takes an event id and prints the event-DB row for
  the symptom plus a time-merged service-log waterfall for the cause. It supports
  `--list`, `--last` and a specific id, with device-agnostic paths overridable
  through `LOG_DIR`, `STATE_DIR` and `EVENTS_DB`. `install.sh` places it in
  `${LIB_DIR}/tools/`.

- **The id survives the signal hand-off between two daemons.**
  `src/lib/event-id.sh` mints, propagates and persists it in
  `PID_TIMESTAMP` form, identical to the lockfile format.
  `nmcli-failover-monitor` mints it at detection and writes `pending_failover_id`
  before sending USR1, which keeps the receiver's trap free of I/O.
  `failover-monitor` adopts it in its main loop, or mints a fresh one for
  health-check, failback and manual failovers. `routing.sh` publishes
  `last_failover_id` for the collector.

- **Past failovers carry their id in the events database.** An `event_id`
  column on `failover_events`, added by an idempotent `ALTER TABLE` migration.
  The web reader degrades to `NULL` against a not-yet-migrated database rather
  than failing.

- A **Trace column** in the web UI event history exposing the id, with a
  copy-ready `grep` command in the cell tooltip.

- New how-to at [`docs/how-to/trace-failover.md`](docs/how-to/trace-failover.md),
  a "Key Concepts" section in the README, and CI lint coverage for `src/tools/`.

### Changed

- `nmcli-failover-monitor`, `failover-monitor`, `routing.sh` and `route-guardian`
  stamp `FAILOVER_EVENT_ID=<id>` into their logs at the four lifecycle points:
  detection, orchestration, route change, guardian pause.
- The lockfile now contains the event id. The on-disk format stays
  `PID_TIMESTAMP`, so route-guardian's stale detection still parses it. Fully
  backward compatible.

## [0.4.1] - 2026-06-12: Production-review fixes and CI overhaul

The first live run of the 0.4.0 CI pipeline caught two runner-environment issues
in the new jobs themselves. All the code checks had passed.

### Fixed

- **The logrotate gate failed with `unknown group 'failover-web'`.** The
  unit-verify step created the user with `wan-state` as primary group but never
  created a `failover-web` group, which the logrotate policy's
  `create 0644 failover-web failover-web` line requires. The step now creates
  both groups, matching what `install.sh` does: a dedicated primary group plus
  `wan-state` as supplementary.

- **gitleaks flagged `.gitleaksignore` itself.** The 0.4.0 revision of the
  allowlist quoted the placeholder-credentials example verbatim in its own
  comment and thereby matched the `curl-auth-user` rule. The comment now
  describes the example without reproducing the matchable pattern, and a
  fingerprint covers the old blob still in git history.

  The local pre-push scan had run before the file was committed, so the history
  scan never saw it. The lesson: verify gitleaks against the actual commit, not
  the working tree.

## [0.4.0] - 2026-06-12: Code-review fixes across routing, systemd and the web UI

Findings from a full code review of the production deployment, ported here. Three
of these fixes concern paths that had never worked: the unit tests mocked
`subprocess.run` and route changes, so only a live end-to-end test could expose
them.

### Fixed

- **Emergency route recovery always ended at "Could not restore any route".**
  `emergency_restore_any_route()` in `routing.sh` called
  `check_interface_status()`, which is defined only in `route-guardian.sh`, a
  different process. Inside the orchestrator that meant `command not found` and
  both restore attempts were skipped. It now uses a local `_interface_link_up()`
  helper based on `ip link` and the sysfs carrier.

- **The web UI config editor could never install a config.** The root helper
  `install-failover-conf` requires every line of the staged file to be a
  whitelisted integer tunable, but the staged file was the full `failover.conf`,
  whose interfaces, test targets and other lines always failed validation. Fixed
  by the override design, see Changed below.

- **Every `sudo` call from the web UI failed with "no new privileges".** The
  unit's seccomp-implying hardening options (`SystemCallArchitectures`,
  `MemoryDenyWriteExecute` and friends) force `NoNewPrivileges=yes` for non-root
  services, overriding the explicit `NoNewPrivileges=false`. Those options are
  removed; the mount-based sandbox stays and escalation remains scoped to two
  commands via sudoers. `ReadWritePaths=/etc/<project>` is added because sudo
  children inherit the unit's mount namespace, where `ProtectSystem=strict` made
  `/etc` read-only for the root helper too.

- **The web UI log froze permanently once it hit 10 MB.**
  `RotatingFileHandler` with two gunicorn workers sharing one file is not
  multiprocess-safe, so `doRollover()` failed on every subsequent record.
  Observed in production: 1076 logging errors in 3 days with the log frozen. On
  top of that, gunicorn's `--access-logfile` and `--error-logfile` pointed at the
  same file as the app handler. Now `WatchedFileHandler` plus a logrotate policy
  (`systemd/failover-web.logrotate`, installed by `install.sh --with-web-ui`),
  and gunicorn logs to stderr and on to journald.

- **Route-guardian could revert a fresh metric swap.** The lockfile
  `/run/failover-in-progress.lock` was only ever created by the nmcli emergency
  path, so regular score-based and manual failovers ran without pausing the
  guardian in the window before `active_wan` is persisted. `safe_route_change()`
  now creates the lock (`PID_TIMESTAMP`, 30-second hold with an ownership check,
  immediate release on error). The guardian check also moved from
  `monitor_default_routes()` to the top of
  `comprehensive_route_health_check()`, because duplicate cleanup, NM-metric
  repair and conflict resolution also mutate routes and previously kept running
  during a failover.

- **The USR1 instant failover could wait a full check interval.** Bash runs traps
  only after the current foreground command finishes, so a USR1 arriving during
  `sleep 15` waited up to 15 seconds. The main loop now uses `sleep ... & wait
  $!`, which returns immediately on any trapped signal, the same pattern
  route-guardian already used.

- **`systemctl stop route-guardian` took 90 seconds and ended in SIGKILL.** The
  SIGTERM trap returned without ending the `while true` loop. A shutdown flag now
  ends the loop at the top of the next iteration.

- **An empty gateway lookup escalated into a false "manual intervention
  required" cascade.** `safe_route_change()` had an ERR trap in addition to
  explicit `rollback_route_change` calls, so both fired, the second against an
  already-deleted backup file. The ERR trap is gone; the explicit error paths
  cover every failure mode.

- **Rollback could fail with "File exists".**
  `restore_routes_from_backup()` deleted only one default route before
  `ip route restore`, so with both WAN routes present the restore collided with
  the remaining one. All default routes are removed first now.

- **A stale PID file sent the nmcli trigger straight to the raw emergency
  path.** Its `pgrep -f` fallback matched against the install path while the
  process cmdline shows the path systemd executed. That emergency path also added
  the backup route with metric 100, a pre-metric-demotion relic that created a
  duplicate route the guardian had to clean up. It now only adds the route if
  missing, with metric 200.

- **The DHCP-lease gateway fallback never found a lease.**
  `get_gateway_from_dhcp()` parsed `/var/lib/dhcp/dhclient.<iface>.leases`, which
  does not exist on NetworkManager systems because of its internal DHCP client.
  Replaced with `get_gateway_from_nm()` using `nmcli -g IP4.GATEWAY`.

- **The web test suite would have started failing on a fixed date.** Seeded
  history events used hardcoded dates that fall out of the default 30-day query
  window. Fixtures now seed relative to now.

- **A slowly dripping `traceroute` could stream for 60 to 90 seconds despite the
  30-second limit.** The `diag` timeout applied only to `proc.wait()` after the
  read loop; it now covers the whole run.

### Changed

- **Operator edits no longer touch `failover.conf`.** They land in
  `/etc/<project>/failover-overrides.conf`, integer tunables only and
  root-validated, which the daemon sources after the base config so bash
  last-wins applies. The base config stays pristine, and `GET /api/config`
  reports the effective merged values plus both paths. New env knob:
  `FAILOVER_WEB_OVERRIDE_CONFIG_PATH`.

- **`FAILOVER_THRESHOLD_DOWN` from the config finally reaches the code.** The
  degraded threshold was hardcoded to 60 in three places, so the config value and
  the web UI field had no effect. `CHECK_IPS` and `DNS_SERVERS` similarly no
  longer overwrite config-provided values.

- **The dashboard stopped reporting "stale" in steady state.** The shipped unit
  sets `FAILOVER_WEB_STATE_STALE_SECONDS=75` and
  `FAILOVER_WEB_STATE_MISSING_SECONDS=180`; with prom writes around every 60
  seconds the 30-second default was below the normal interval.

- **gunicorn 25.x produced a "Control server error" on every start.** The unit
  now sets `HOME=/var/lib/failover-web`, because the user's real home is
  read-only under `ProtectHome`.

### Added

- **The web UI test suite runs in CI.** A new pytest job runs all 136 tests on
  Python 3.10, the documented floor, and 3.12. None of the web UI fixes in this
  release would have been caught by the previous pipeline, which never executed
  `src/web/tests/`.
- **Secret scanning in CI.** gitleaks scans the full git history on every push
  and PR. `.gitleaksignore` carries the one audited false positive, the
  placeholder `admin:secret` example in the quota custom-template docs.
- **Config syntax gates in CI:** `visudo -cf` for the sudoers fragment,
  `logrotate -d` for the new policy, and `bash -n` for the sourced config
  examples, since a syntax error in `failover.conf` bricks the daemon at startup.

### Changed (CI)

- **The systemd unit check can actually fail now.** It previously ran
  `systemd-analyze verify || true`, and a check that cannot fail is not a check.
  The job now stubs the `Exec*` binary paths the units reference, which are the
  only legitimately missing pieces on a runner, and treats any remaining verify
  error as a hard failure.
- **ruff lints `src/web/`.** The two pre-existing unused-import findings are
  fixed in this release. `ruff format --check` stays scoped to the two standalone
  scripts, since reformatting 31 web files wholesale would bury the diff history
  for no behavioural gain.
- **shellcheck covers the full bash surface,** now including `install.sh`, the
  root-side config installer `src/web/install-failover-conf.sh`, and the bats
  helpers and mocks.
- Workflow hygiene: `permissions: contents: read` for least privilege, and a
  concurrency group that cancels superseded runs.

### Removed

- **`FAILOVER_THRESHOLD_UP` and `HYSTERESIS_GAP` were knobs without effect.** The
  daemon never evaluated either. Failback is governed by `MIN_FAILBACK_SCORE`,
  `MIN_BACKUP_TIME` and `MIN_STABLE_DURATION`, and the score-hysteresis path
  below the `MIN_FAILBACK_SCORE` gate was unreachable: it required a score above
  90 on a path only reachable below 60. The web UI field is gone, the config
  example keeps both names commented out as historical documentation, and the
  dead branch in `is_failback_needed()` is removed. Behaviour is unchanged.

- Dead code: `restore_missing_backup_route()`, a monitoring-only stub with
  inverted log logic and no callers; the events-module signal-handler remnants in
  `common.sh` (`setup_signal_handlers`, `handle_event_signal`,
  `graceful_shutdown`, `cleanup_temp_files`), which referenced functions that no
  longer exist; and the always-zero performance-stats log line, whose counters
  live in command-substitution subshells and can never accumulate, now documented
  in `performance.sh`.

## [0.3.0] - 2026-06-10: Web UI write-path fix and anti-flapping docs

### Fixed

- **The dashboard's failback and force-failover buttons returned a write
  error.** The `chgrp wan-state` on `/run/<project>/wan-state` ran inside the
  orchestrator unit's sandbox, where `CapabilityBoundingSet` drops `CAP_CHOWN`,
  so group ownership silently stayed `root` and the group-writable bit was
  useless. The `ExecStartPre` chgrp now uses the systemd `+` prefix to run with
  full privileges outside the sandbox, and the directory is `02775` (setgid) so
  `manual_action.json` inherits the `wan-state` group.

### Changed

- **The anti-flapping docs described a cooldown that does not exist for
  failover.** `ANTI_FLAPPING_DELAY` (600 s) covers failback and manual actions
  only; score-based failover is governed by `FAILURE_THRESHOLD`,
  `MIN_BACKUP_TIME`, `MIN_STABLE_DURATION` and the emergency exemption.
  Corrected in the config example comments, in
  `docs/explanation/anti-flapping.md`, and in a daemon log line that printed
  "300s cooldown" while enforcing 600.

## [0.2.0] - 2026-05-05: Optional Flask web UI

### Added

- **Live state in a browser instead of `journalctl -f`.** An optional Flask and
  gunicorn web UI under `src/web/`, enabled with `install.sh --with-web-ui`. It
  provisions a dedicated `failover-web` system user in group `wan-state`, a venv
  at `/usr/local/lib/.../web/venv`, and a `failover-web.service` unit binding
  `127.0.0.1:8091`. The dashboard shows live state, per-interface latency, loss,
  DNS and HTTP metrics, a 30-day event table, three operator buttons (manual
  failback, force failover, monitor restart), a whitelisted 16-key config editor,
  and on-demand `ping`, `dig`, `traceroute` and `mtr` streamed over Server-Sent
  Events. Documented in `docs/how-to/configure-web-ui.md`,
  `docs/reference/web-api.md` and `docs/explanation/web-ui-architecture.md`.

- **Manual actions reach the daemon through a file, not a socket.**
  `process_manual_action_request()` in `failover-monitor.sh` polls
  `${RUNTIME_DIR}/wan-state/manual_action.json` once per main loop iteration,
  validates the payload (action, request_id, ts), enforces a 30-second freshness
  window and idempotency through `manual_action_processed_ids`, and dispatches to
  `perform_failover` with `manual_failback` or `manual_failover_force` reasons.
  Those bypass the score-based decision gates while still honouring
  `ANTI_FLAPPING_DELAY`. When the file is absent the function costs one `stat()`
  per iteration, so installations without the web UI pay nothing.

- **Everything the web UI needs to run confined ships with it,** as
  `systemd/failover-web.{service,sudoers,tmpfiles,nginx.example}`: a hardened
  unit (gunicorn, 2 workers with 4 threads, the full set of `Protect*` knobs), a
  minimal sudoers fragment covering only `systemctl restart
  failover-monitor.service` and the root-owned config installer, tmpfiles
  directives for `/var/lib/failover-web` and the audit log, and an nginx upstream
  sample with the X-Forwarded-For overwrite rule the source-IP extractor relies
  on.

- **A root-owned validating config installer** closes the
  attacker-controlled-source privilege-escalation class that any "sudo cp" rule
  would open. `src/web/install-failover-conf.sh` re-validates every line of the
  staged `failover.conf` in root context against the same 16-key schema the web
  app enforces, then atomically renames it into `/etc/<project>/failover.conf`.

- **The web UI uses the same alerting plugins as the daemon.**
  `src/web/alerts/dispatcher.py` implements the `send_alert <type> <message>`
  contract documented in `plugins/alerting/README.md`, so `none`, `mattermost`,
  `webhook` or any custom plugin work without code changes. The default backend
  is `none`, which is silent.

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

## [0.1.1] - 2026-05-02: DNS over HTTPS unblocks failback

### Fixed

- **A healthy primary reported a 999 ms DNS timeout and failback never
  happened.** All DNS health checks used `dig @8.8.8.8 -b $iface_ip` to "bind" to
  an interface, but `dig -b` only sets the source IP; it does not force the
  outgoing interface. With the primary demoted to a higher metric, the kernel's
  destination-based routing sent DNS packets out through the active backup
  carrying the primary's source IP, ISPs filtered the asymmetric flow, and the
  probe timed out.

  The consequences chained: `_end_to_end_penalty` deducted 25 points,
  `test_dns_score` returned 0 instead of 25, the recovery counter could never
  reach its threshold, and the orchestrator stayed pinned to the backup.
  Reproduced live: `dig @8.8.8.8 -b $primary_ip` timed out while
  `curl --interface $primary` answered in under 100 ms.

  - `lib/network.sh` gains `measure_dns_doh()`, which uses `curl --interface` for
    real `SO_BINDTODEVICE` binding against `dns.google` and `cloudflare-dns.com`
    over DNS-over-HTTPS, with `--resolve` bootstrap on multiple IPs to avoid any
    system-resolver dependency. Responses are validated against HTTP 200, JSON
    `Status==0` (NOERROR per RFC 8484 and the Google JSON API) and
    `Answer.length>=1`, which also rejects captive-portal 200s. The old `dig -b`
    body is kept in a private `_measure_dns_dig_legacy()` for emergency rollback.
  - `measure_dns_performance`, `measure_dns_time`, `test_dns_server` and
    `measure_dns_detailed` all now call `measure_dns_doh`. The nslookup fallback
    in `test_dns_server` was removed as a false positive: it ignored the
    interface argument and answered over the active default route, so the backup
    always looked "DNS-OK" even when source-bound dig had timed out. The ISP
    resolver in `measure_dns_detailed` was dropped because it does not speak DoH,
    and its SQLite column is now NULL for new rows.
  - `lib/performance.sh`: `test_dns_score` migrated to `measure_dns_doh`.
  - `config/failover.conf.example` gains `DNS_TEST_METHOD=doh|dig`, defaulting to
    `doh`, which is the fix. Set it to `dig` for a soft rollback.

  Verified live: failback succeeded within minutes of the deploy, and DNS latency
  in `wan_quality.prom` dropped from 999 and 1500 ms to 80 to 200 ms.

- **`_backup_quota_cap()` returned exit code 1 when no cap applied,** which
  aborts callers running under `set -e`. The function ended in
  `[[ -n "$result" ]] && echo "$result"`, so the empty-output path inherited the
  test's failure: it triggered whenever the snapshot percentage was below the
  lowest tier (87 %, for instance) or `limit_pct` was `null`. An explicit
  `return 0` now follows the conditional echo. (`src/lib/performance.sh`)

### Changed

- **cgroup throttling distorted the metrics by an order of magnitude.**
  `CPUQuota` was 5 to 20 % for the four services, tight enough to throttle the
  bursty subprocess work (`ping`, DoH `curl`, `jq`) by 80 to 98 % on a 4-core
  Pi 5, even though absolute CPU usage was only a few percent. The distorted
  numbers went into `wan_quality.prom`, fed the orchestrator's end-to-end penalty
  and blocked failback. The bug was only visible because the DoH fix exposed how
  unrealistic the throttled measurements were.

  - `failover-metrics-collector.service`: 10 to 50 %, subprocess-heavy
  - `route-guardian.service`: 10 to 50 %, a real-time safety net with dense bursts
  - `failover-monitor.service`: 50 to 75 %, parallel scoring rounds
  - `nmcli-failover-monitor.service`: 20 to 50 %, event handling

  Each service file carries an inline comment explaining why. On a dedicated
  router box you can drop `CPUQuota` entirely. `MemoryMax` is unchanged and still
  useful as a leak guard.

- **A dead primary plus a borderline backup left the routing table with no
  default route.** The combination is narrow: the primary loses layer-1 carrier
  (cable unplugged, modem powered off) at the same moment the backup score sits
  exactly at the both-degraded threshold, for example 25, hit by the end-to-end
  DNS penalty during an LTE throttling window. Every score-based path then
  classified the backup as not viable and `both_degraded` pinned the orchestrator
  on the dead primary. Three coordinated patches:

  - `failover-monitor.sh` gains a **carrier-aware pre-check** in
    `check_failover_conditions()`. When the primary has `carrier=0`, the backup
    has `carrier=1` and the backup score is above 0 (so not quota-blocked), it
    triggers an unconditional failover before any score-based path runs. Layer-1
    state is binary and unambiguous, so it overrides the heuristics. The
    score-above-zero guard preserves the `LAST_RESORT` quota-cap protection.
  - `lib/routing.sh` gains a **carrier-aware short-circuit** in
    `_swap_primary_metric()`. The metric demotion fails with "Network is
    unreachable" when the primary has `carrier=0`, which trips
    `safe_route_change()` rollback and emergency recovery, all of which fail too.
    It now keeps the NetworkManager metric persist in step 1, applied on the next
    DHCP cycle, skips the kernel route add when carrier is 0, cleans up stale
    routes defensively and returns success. The kernel auto-prefers the backup
    since there is no competing primary route.
  - `route-guardian.sh` gains **default-route vacuum detection** as an
    independent safety net. After the regular checks, if `total_default_routes ==
    0`, it restores via the backup (preferred when the primary is layer-1 dead)
    or the primary as fallback, and sends a `ROUTE_VACUUM_RECOVERED` alert.
    Lockfile coordination is unchanged, so there is no race with the orchestrator
    during legitimate failovers.

  Together these form a detect, execute, safety-net chain. Verified against a
  real DSL outage where the pre-check fired and the routing-library short-circuit
  was needed to let it succeed.

### Internal

- **CI is green across all jobs.** Resolved bashate trailing whitespace (two
  `while ...; do true; done` patterns rewritten to multi-line form), `ruff check`
  (an unused `time` import and two f-strings without placeholders), `ruff format`,
  and shellcheck warnings (`unset` array-key quoting in `lib/performance.sh`,
  declare/assign separation and a trap-quote disable in `lib/routing.sh`, and
  `# shellcheck disable=SC2034` for public-API constants consumed by sourcing
  scripts). None of these change behaviour; the only behaviour change in this
  release is the `_backup_quota_cap()` return-code fix above.
- **The bats suite is green at 23 of 23.** Tests 12 and 17 in
  `tests/unit/test_quota.bats` were red as a symptom of the
  `_backup_quota_cap()` bug.

## [0.1.0] - 2026-04-27: First public alpha

First public alpha, extracted from a private homelab dual-WAN failover stack that
has been running in production since August 2025.

### Added

- **Four-service architecture:** `failover-monitor`, `nmcli-failover-monitor`,
  `route-guardian`, `failover-metrics-collector`.
- **Event-driven detection** through `nmcli monitor` with sub-second `SIGUSR1`
  hand-off to the orchestrator, plus a polling fallback for environments without
  NetworkManager state changes.
- **Score-based health checks,** 0 to 100 per interface, combining latency,
  packet loss, DNS resolution time and gateway reachability.
- **Anti-flap and hysteresis** with separate failover and failback thresholds, a
  minimum backup-link dwell time and stable-duration gating.
- **A route guardian** that enforces metric correctness against `active_wan` as
  ground truth, with sub-second cleanup of duplicate routes.
- **Lockfile coordination** in `PID_TIMESTAMP` format, keeping the route guardian
  from racing the failover orchestrator during emergency switches.
- **Plugin slots:** `plugins/alerting/` with `none`, `mattermost` and `webhook`;
  `plugins/quota-providers/` with `no-op`, `netgear-lm1200` and
  `custom-template`.
- **Prometheus textfile output** plus a SQLite event history for after-the-fact
  incident analysis.
- **Diataxis documentation:** tutorial, how-to, reference, explanation.
- **Tests:** bats-core unit tests with `tests/mocks/` for `ip`, `nmcli` and
  `ping`.
- **CI:** shellcheck, bashate, bats, ruff.

[Unreleased]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.7...HEAD
[0.9.7]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.6...v0.9.7
[0.9.6]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/fidpa/linux-dual-wan-failover/compare/v0.9.2...v0.9.3
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
