# Why the Web-UI is shaped the way it is

The Web-UI is an **opt-in** add-on. The four core failover services run
fine without it — `process_manual_action_request` in
`failover-monitor.sh` is a cheap `stat()` per loop iteration when the
file is absent, and nothing else in the stack changes.

When the Web-UI is installed, three deliberate design choices matter
more than the code itself: the file-trigger handshake, the auth-less
LAN-only posture, and the privilege split between `failover-web` and
the root daemon.

## File-trigger, not Unix socket

Manual mutations (failback, force-failover) never touch the routing
table directly. They are written as a JSON file, atomically, into
`${RUNTIME_DIR}/wan-state/manual_action.json`. The daemon polls the
file once per main-loop iteration (`CHECK_INTERVAL`, default 15 s),
processes it, marks the request ID as handled in
`manual_action_processed_ids`, and removes the file.

```
Web-UI  ──► tempfile + os.fsync + os.rename ──► manual_action.json
                                                       │
Daemon  ◄─── jq parse, freshness, idempotency ◄────────┘
                  │
                  └──► perform_failover(BACKUP, PRIMARY, "manual_failback")
```

We could have used a Unix domain socket and gotten sub-second latency.
We chose a file-trigger anyway, for these reasons:

- **Atomicity is trivial.** `os.rename` on the same filesystem is
  atomic by POSIX. A socket protocol needs framing, length prefixes,
  and partial-write handling to reach the same guarantee.
- **Idempotency falls out for free.** A file holds exactly one request.
  Web retries reuse the request ID; the daemon's
  `MANUAL_ACTION_PROCESSED_IDS_FILE` (last 100 IDs) deduplicates without
  a session.
- **The daemon stays the single owner of state.** Routing changes only
  happen inside `perform_failover`, never as a side-effect of the web
  process. If the web process dies mid-write, the temp-rename pattern
  ensures the daemon never sees a partial payload.
- **Operability.** A stuck request is `cat manual_action.json` away
  from being diagnosed. A stuck socket is `ss -x` plus a strace.
- **The web app can be down.** A pending failback file the daemon hasn't
  processed yet survives a `failover-web` crash with no special-case
  code.

The cost is latency: up to one full `CHECK_INTERVAL` (15 s by default)
between the operator clicking "Failback" and the metric demotion. The
daemon's freshness window (30 s) and idempotency store make this safe
without tightening the polling cadence.

## Auth-less by design (and how that is OK)

The dashboard has no login screen. Dropping authentication is not
laziness — it is a recognition of what the threat model actually is:

- **Network boundary.** The Flask process binds to `127.0.0.1:8091`. A
  reverse proxy with an IP allowlist is the first gate. An attacker who
  is already on the LAN can hit the proxy; one who isn't, can't.
- **CSRF + Origin/Referer.** Even an attacker on the same LAN browsing
  a hostile site cannot make their browser POST to the dashboard:
  `SameSite=Strict` cookie, double-submit token, hostname check on
  Origin / Referer. The same-origin gate fails closed when the
  `FAILOVER_WEB_CSRF_HOSTS` env is empty.
- **Rate-limit per (endpoint, source IP).** A scripted attacker who
  sneaks past the proxy still cannot hammer `/api/failback`; the
  bucket is 1 / 60 s. The XFF header is overwritten by the proxy
  (not appended) so the IP cannot be spoofed by upstream clients.
- **Audit log + alerting.** Every mutation produces a JSON-Lines audit
  entry and an alerting-plugin dispatch. A successful intrusion paints
  itself across both layers.
- **Daemon anti-flapping.** Even with all else bypassed, the daemon's
  `ANTI_FLAPPING_DELAY` cooldown limits how fast manual actions can
  oscillate the routing table.

The result is defence-in-depth that fits the deployment shape (homelab
or small-office router with a handful of operators on a trusted LAN).
If your shape is different — multi-tenant, internet-exposed, hostile
LAN — terminate authentication in the reverse proxy. The web app's
contract with the proxy is `X-Forwarded-For = $remote_addr`; anything
else (mTLS, SAML, basic auth) is the proxy's job.

## Privilege split

Three entities, three privilege levels:

| Component | UID | Powers |
|-----------|-----|--------|
| `failover-monitor.service` | root | Owns `/run/<project>/wan-state/`. Reads `failover.conf` and `source`s it as Bash. Manipulates `ip route`. |
| `failover-web.service` | failover-web (in group `wan-state`) | Writes `manual_action.json` into the daemon's runtime dir. Reads the read-only state files + SQLite events. |
| `install-failover-conf` | root (invoked via `sudo -n`) | Re-validates the staged config in root context, atomically renames it into `/etc/<project>/failover.conf`. |

The web app's sudoers fragment grants exactly two NOPASSWD rules:

```
failover-web ALL=(ALL)  NOPASSWD: /usr/bin/systemctl restart failover-monitor.service
failover-web ALL=(root) NOPASSWD: /usr/local/sbin/install-failover-conf
```

The second rule used to be `sudo /usr/bin/install` with arguments —
which copied attacker-controlled bytes verbatim into a file the daemon
later `source`s. We replaced that with the root-owned, argument-free
helper. The helper re-parses every line in root context against the
same 16-key whitelist the web app enforces. Anything unknown, anything
with shell metacharacters, anything non-integer aborts. The web app
has no way to talk into `/etc/<project>/` except through this single
choke point.

### Runtime-dir permissions are fiddlier than they look

`failover-web` writes `manual_action.json` into
`/run/<project>/wan-state/`, so that directory must be group `wan-state`
and group-writable (`2775`). Getting there reliably is harder than it
looks, because up to three mechanisms touch the directory and the last
writer wins:

- **systemd `RuntimeDirectory=`** recreates the runtime tree on every
  (re)start and re-applies its own owner/mode, overriding anything an
  earlier `ExecStartPre` set.
- **`CapabilityBoundingSet`** on the orchestrator drops `CAP_CHOWN`, so
  a `chgrp` that runs inside that sandbox fails silently. It needs the
  systemd `+` prefix to run with full privileges outside the sandbox.
- **The daemon itself** may `chmod` its state directory during init. If
  that path overlaps the IPC directory it clobbers the group bits back.
  Keep the daemon's state dir and the Web-UI IPC dir distinct (as we do:
  `/var/lib/<project>` vs `/run/<project>/wan-state`), or make the daemon
  the authoritative last-writer for the shared dir.

Verify after install — and again after a daemon restart, which is when
these interactions usually bite:

```
stat -c '%a %U:%G' /run/<project>/wan-state   # want: 2775 root:wan-state
sudo -u failover-web test -w /run/<project>/wan-state && echo writable
```

## What we did not build

- **No charts.** The dashboard surfaces live numbers and a 30-day
  failover-event table. Long-window analytics belong in Grafana,
  reading the same `wan_quality.prom` textfile the dashboard reads.
- **No multi-router fleet view.** The app speaks to one daemon. Run
  one instance per router and aggregate at the proxy or in Grafana.
- **No background scheduler.** Mutations are operator-driven only.
  Cron-style automation belongs in a separate timer that posts to
  the same endpoints with its own credentials.

These are not "TODOs" — they are scope decisions that keep the surface
small enough to audit.

## Threat model summary

The full threat model lived in the original Pi-Router-internal repo
(8 scenarios, mitigations enumerated). The shipped Web-UI inherits the
same mitigations, with the relevant bits compressed into:

| Threat | Mitigation |
|--------|------------|
| Browser CSRF from a hostile LAN site | SameSite=Strict cookie + double-submit + Origin/Referer |
| LAN-host curl bypass | Rate-limit per IP + audit log + alert on every mutation |
| Spoofed `X-Forwarded-For` | Proxy overwrites (not appends); right-most token is trusted |
| Privilege escalation via attacker-controlled config | Root-owned validating helper, no path arguments, schema re-check in root |
| Audit-log tampering | Append-only `JSON-Lines`, refuse-to-start on unwritable path |
| Replay / double-submit | Daemon-side `request_id` deduplication (last 100 IDs) |
| Stale request after operator left the page | 30 s freshness window enforced by the daemon |
| Resource exhaustion via SSE | Per-IP cap on long-lived streams, tight subprocess timeouts |

The cumulative property: a successful exploit needs to defeat at least
two independent layers, and every successful mutation is observable in
the audit log and the alerting channel.
