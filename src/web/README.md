# `linux-dual-wan-failover` — Web-UI module

Optional Flask + gunicorn dashboard for the failover stack. LAN-only,
auth-less by design — sit it behind your reverse proxy of choice and let
network boundaries plus CSRF/Origin/rate-limit/audit do the heavy lifting.

| | |
|---|---|
| Backend  | Flask 3.1, gunicorn 23 (`gthread` worker, 2 × 4 threads) |
| Frontend | HTMX 1.x, vanilla CSS, no build step |
| Daemon-IPC | atomic JSON file at `${RUNTIME_DIR}/wan-state/manual_action.json` |
| Privileges | `failover-web` system user; sudo only for `systemctl restart` and a root-owned config installer |
| Tests | 70+ pytest unit + integration tests |

The Web-UI is **opt-in**. The core failover stack runs without it; install
it via `sudo ./install.sh --with-web-ui` if you want operator buttons,
config editing, and on-demand diagnostics in a browser.

## Module layout

```
src/web/
├── __init__.py
├── app.py                    # Flask entrypoint, route registry, SSE generator
├── wsgi.py                   # gunicorn shim (re-exports `app`)
├── config.py                 # ENV-driven paths + tunables (no I/O at import)
├── readers/                  # Read-only consumers
│   ├── state_reader.py       # connection_metrics + wan_quality.prom -> snapshot
│   ├── events_reader.py      # SQLite read-only (failover-events.db)
│   └── config_reader.py      # failover.conf parser + 16-key whitelist + range validation
├── writers/                  # Mutation paths
│   ├── manual_action_writer.py  # atomic file-trigger (flock + tempfile+rename)
│   ├── service_controller.py    # NOPASSWD sudo: systemctl restart/is-active
│   └── config_writer.py         # staging -> root validator -> restart
├── middleware/               # Cross-cutting concerns
│   ├── csrf.py               # Double-submit cookie (SameSite=Strict)
│   ├── rate_limit.py         # In-process token bucket per (endpoint, source-IP)
│   ├── audit_log.py          # JSON-Lines per mutation
│   └── sse_limit.py          # Per-IP SSE connection cap
├── diag/
│   └── runner.py             # ping/dig/traceroute/mtr — subprocess shell=False, SSE stream
├── alerts/
│   └── dispatcher.py         # Bash plugin loader (none/mattermost/webhook/custom)
├── templates/                # Jinja2 (HTMX, polling-based)
├── static/{css,js,vendor}/   # Vendor assets — drop htmx.min.js into vendor/
├── install-failover-conf.sh  # Root-owned validating config installer
├── requirements.txt
└── tests/                    # pytest unit + integration suite
```

## Endpoints

### Read-only (no CSRF, no rate-limit)

| Method | Path | Returns |
|--------|------|---------|
| GET | `/` | HTML dashboard (Jinja2) |
| GET | `/api/state` | JSON snapshot (current_wan, scores, counters, freshness) |
| GET | `/api/state-html` | HTML fragment (HTMX poll target, every 5 s) |
| GET | `/api/events/stream` | SSE stream of state events + heartbeats |
| GET | `/api/history?days=30&limit=1000` | Failover events from SQLite |
| GET | `/api/config` | Whitelisted tunables + current values |
| GET | `/health` | Liveness + freshness probe |

### Mutating (CSRF + rate-limit + audit + alert)

| Method | Path | Limit | UI confirm |
|--------|------|-------|------------|
| POST | `/api/failback` | 1 / 60 s | modal |
| POST | `/api/force-failover` | 1 / 120 s | modal |
| PUT | `/api/config` | 1 / 30 s | modal |
| POST | `/api/diag/{ping\|dig\|traceroute\|mtr}` | 1 / 10 s | — (SSE) |

Rate-limits are per `(endpoint, source_ip)`. The reverse-proxy
`X-Forwarded-For` header is honoured (`web/middleware/_common.py`).

## Trigger path

```
Browser POST /api/failback
        |
        v
csrf_protect → rate_limit("failback", 1/60s) → state_reader.read_snapshot()
        |
        | (precondition: snap.current_wan == "backup", freshness != "missing")
        v
manual_action_writer.submit_action("failback")
        |
        | flock(${MANUAL_ACTION_LOCK})
        | tempfile + os.fsync + os.rename → ${MANUAL_ACTION_FILE}
        v
audit_log.emit + dispatcher.send  →  HTTP 202 + request_id
        |
        | Daemon main-loop (≤ CHECK_INTERVAL later, ~15 s)
        v
process_manual_action_request()  ← src/services/failover-monitor.sh
        |
        | jq parse → freshness check (ts ≤ 30 s) → idempotency (request_id)
        v
perform_failover(BACKUP, PRIMARY, "manual_failback")
        |
        | Anti-flapping (ANTI_FLAPPING_DELAY) for failback + manual_* reasons
        | safe_route_change → metric swap → routing.sh::execute_route_change
        v
active_wan = primary  →  state file updated
```

Idempotency store: `${MANUAL_ACTION_PROCESSED_IDS_FILE}` (last 100 IDs).

## Setup + further reading

- **`docs/how-to/configure-web-ui.md`** — install runbook, reverse-proxy
  setup, CSRF host configuration, Mattermost wiring.
- **`docs/reference/web-api.md`** — every endpoint, payload schema, status
  codes, audit-log shape.
- **`docs/explanation/web-ui-architecture.md`** — why a file-trigger
  rather than a Unix socket, the privilege model, the threat model.

## Local development

```bash
# Repo-local virtualenv
python3 -m venv .venv
.venv/bin/pip install -r src/web/requirements.txt

# Run tests
PYTHONPATH=src .venv/bin/pytest src/web/tests -q

# Run the dev server (no gunicorn)
PYTHONPATH=src \
FAILOVER_WEB_CSRF_COOKIE_SECURE=0 \
FAILOVER_WEB_AUDIT_LOG_REQUIRE_FILE=0 \
FAILOVER_WEB_AUDIT_LOG=/tmp/audit.log \
FAILOVER_WEB_APP_LOG=/tmp/app.log \
.venv/bin/flask --app web.app run --port 8091
```
