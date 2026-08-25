# Web-UI HTTP API reference

This document is the source of truth for the HTTP surface of the optional
Web-UI (`failover-web.service`). All paths are relative to the bind
address; production deployments terminate TLS in a reverse proxy and
route to the `127.0.0.1:8091` upstream.

## Conventions

- Every read-only endpoint returns JSON unless explicitly noted.
- Every mutating endpoint requires:
  - a matching CSRF token (cookie + `X-CSRF-Token` header), and
  - an `Origin` or `Referer` whose hostname is in
    `FAILOVER_WEB_CSRF_HOSTS` (see
    [`docs/how-to/configure-web-ui.md`](../how-to/configure-web-ui.md)).
- Mutations are rate-limited per `(endpoint, source-IP)`. Replies on
  rate-limit hit are HTTP 429 with `Retry-After` and a JSON body.
- Every mutation generates an entry in
  `/var/log/linux-dual-wan-failover/failover-web-audit.log` (JSON-Lines)
  and dispatches an alert through the configured alerting plugin.

## Read-only endpoints

### `GET /`

Renders the HTML dashboard. The first response sets the `csrf_token`
cookie if one is not present.

### `GET /api/state`

Returns the current snapshot as JSON.

```json
{
  "timestamp": 1746522305,
  "current_wan": "primary",
  "primary_interface": "eth0",
  "backup_interface": "lte0",
  "freshness": "fresh",
  "state_age_seconds": 2,
  "prom_age_seconds": 3,
  "thresholds": {"failure": 5, "recovery": 20},
  "interfaces": {
    "eth0": {
      "interface": "eth0",
      "score": 95,
      "failures": 0,
      "recoveries": 200,
      "latency_ms": 0.42,
      "packet_loss_pct": 0.0,
      "jitter_ms": 0.0,
      "dns_time_ms": 80.0,
      "http_time_ms": 45.0,
      "quality_score": 78,
      "role": "primary"
    },
    "lte0": { ... }
  }
}
```

`freshness` is `fresh` when neither source file is older than
`FAILOVER_WEB_STATE_STALE_SECONDS` (default 30 s), `stale` between that
and `FAILOVER_WEB_STATE_MISSING_SECONDS` (default 60 s), and `missing`
beyond that.

### `GET /api/state-html`

HTML fragment of the interface cards + freshness banner. The dashboard
polls this every 5 s via HTMX; clients other than the dashboard rarely
need it.

### `GET /api/events/stream`

Server-Sent Events stream. Yields one `state` event every
`FAILOVER_WEB_SSE_TICK_SECONDS` (default 5) and a `: heartbeat` comment
every `FAILOVER_WEB_SSE_HEARTBEAT_SECONDS` (default 15). 429 when the
per-IP cap (`FAILOVER_WEB_SSE_MAX_PER_IP`, default 3) is exhausted.

### `GET /api/history?days=N&limit=M`

Returns recent failover events from the SQLite event store.

- `days` clamped to `[1, 365]`, default 30.
- `limit` clamped to `[1, 5000]`, default 1000.

```json
{
  "days": 30,
  "count": 3,
  "events": [
    {
      "id": 1,
      "timestamp": "2026-04-29 10:15:00",
      "event_type": "failover",
      "from_interface": "eth0",
      "to_interface": "lte0",
      "primary_score_before": 25,
      "backup_score_before": 80,
      "reason": "score_based",
      "actual_failover_duration_ms": 4500,
      "inter_event_duration_seconds": 0,
      "event_id": "3741608_1782676271"
    },
    ...
  ]
}
```

`event_id` is the failover Correlation-ID (see
[`../how-to/trace-failover.md`](../how-to/trace-failover.md)). It is `null` for
events recorded before v0.5.0, and the reader also degrades to `null` against a
database whose `event_id` column has not been migrated yet.

### `GET /api/config`

Returns the whitelisted tunables with their current EFFECTIVE values
(base config overlaid with the operator override file — mirroring the
daemon's source order).

```json
{
  "config_path": "/etc/linux-dual-wan-failover/failover.conf",
  "override_config_path": "/etc/linux-dual-wan-failover/failover-overrides.conf",
  "fields": {
    "FAILOVER_THRESHOLD_DOWN": {
      "type": "int", "min": 0, "max": 100, "current": 60,
      "help": "Failover when primary score falls below this value"
    },
    ...
  }
}
```

### `GET /health`

```json
{
  "status": "ok",
  "freshness": "fresh",
  "state_age_seconds": 2,
  "prom_age_seconds": 3
}
```

`status` flips to `degraded` when the snapshot is `missing`.

## Mutating endpoints

### `POST /api/failback`

Manual failback (`backup → primary`). Only valid when the daemon is
currently on backup; otherwise returns 409. Rejected with 503 when the
daemon state is not readable.

Request: empty body.
Response (success): HTTP 202.

```json
{
  "status": "submitted",
  "request_id": "5d72d8ce0ba84b9c9a7b7f7e9c8e1f23",
  "ts": 1746522345,
  "detail": "Daemon will process within next check interval (15s)."
}
```

Rate-limit: 1 / 60 s per source-IP.
Response (anti-flapping cooldown active): HTTP 409.

```json
{
  "status": "cooldown",
  "detail": "Anti-flapping cooldown active — 344s remaining. The daemon would discard this request.",
  "remaining_seconds": 344
}
```

The daemon enforces `ANTI_FLAPPING_DELAY` on manual actions too, and a
suppressed request is dropped with a journal line only. Without this
pre-check the API answered 202 "submitted" for a request that was
guaranteed to be discarded, which reads to the operator as a dead button.
The check is advisory — the daemon remains authoritative — and fails open
if the timestamp is missing or unreadable.

Audit event: `failback_submitted` (success), `failback_rejected` /
`failback_noop` / `failback_cooldown` / `failback_failed` (otherwise).
Alert: `WARN_FAILOVER`.

> Clients must render the response body on non-2xx as well. `403` (CSRF
> token expired), `409` (noop/cooldown) and `429` (rate limit) all carry a
> `detail` field; htmx only swaps 2xx bodies by default, so an
> `htmx:responseError`-style handler is required or the UI shows nothing.

### `POST /api/force-failover`

Mirror of `/api/failback` for the opposite direction. 409 unless current
WAN is primary.

Rate-limit: 1 / 120 s.
Audit event: `force_failover_submitted` etc.
Alert: `CRIT_FAILOVER`.

### `POST /api/restart-monitor`

Restart the failover-monitor daemon. Rate-limited to one call per 5 minutes.

| Aspect       | Detail                                    |
|-------------|-------------------------------------------|
| Auth         | CSRF token (double-submit cookie)         |
| Rate limit   | 1 call / 300 s per IP                     |
| Audit log    | `restart_monitor_requested`, `restart_monitor_succeeded` / `restart_monitor_failed` |

**Success (200)**
```json
{"status": "ok", "detail": "failover-monitor.service restarted."}
```

**Error (500)**
```json
{"error": "restart_failed", "status": "...", "error": "..."}
```

### `PUT /api/config`

Apply whitelisted config updates. Body is a JSON object mapping
schema-known keys to integer values.

```bash
curl -X PUT https://failover.local/api/config \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $(awk -F= '/^csrf_token/ {print $2}' /tmp/cookies)" \
    -b /tmp/cookies \
    -d '{"FAILOVER_THRESHOLD_DOWN": 55, "RECOVERY_THRESHOLD": 25}'
```

Response statuses:

| HTTP | `status` field | Meaning |
|------|---------------|---------|
| 200 | `applied` | All accepted keys patched; daemon restarted; daemon active. |
| 200 | `noop` | Submitted values are already current. |
| 207 | `installed_but_restart_failed` | Config persisted, daemon restart failed — operator action required. |
| 422 | `validation_failed` | Range / type / unknown-key errors; nothing applied. |
| 500 | `error` | Read/patch/install failure; nothing applied. |

The 15-key whitelist is defined in
[`src/web/readers/config_reader.py`](../../src/web/readers/config_reader.py)
and re-enforced by
[`src/web/install-failover-conf.sh`](../../src/web/install-failover-conf.sh)
in root context.

Writes land exclusively in `failover-overrides.conf` — the base
`failover.conf` is never touched by the API. The daemon sources the
override file after the base config (bash last-wins), so a `PUT` takes
effect on the restart that follows it. Resetting a value to the base
default leaves an explicit override line behind (harmless; remove it from
the override file manually if you want the base value to track future
base-config changes).

### `POST /api/diag/{tool}`

Tool ∈ `{ping, dig, traceroute, mtr}`. Body:

```json
{"target": "8.8.8.8", "iface": "eth0", "count": 4}
```

- `target` must match `^[A-Za-z0-9][A-Za-z0-9._\-:]{0,253}$` (no shell
  metacharacters).
- `iface` is optional; it must be in `FAILOVER_WEB_DIAG_INTERFACES`
  (defaults to `(PRIMARY_IFACE, BACKUP_IFACE)`).
- `count` clamped to `[1, 10]`.

Response is a Server-Sent Events stream:

```
event: start
data: /bin/ping -c 4 -W 2 -I eth0 8.8.8.8

data: PING 8.8.8.8 (8.8.8.8) ...
data: 64 bytes from 8.8.8.8: ...
...
event: end
data: 0
```

Special events: `event: error` (timeout, spawn failure, output cap),
`event: truncated` (output exceeded `DIAG_MAX_OUTPUT_BYTES`, default 64 KB).
Process is killed after `DIAG_TIMEOUT_SECONDS` (default 30).

## Audit log shape

One JSON record per line, written to
`/var/log/linux-dual-wan-failover/failover-web-audit.log`:

```json
{
  "ts": 1746522345,
  "iso": "2026-05-06T11:25:45+0200",
  "src_ip": "10.0.0.42",
  "method": "POST",
  "path": "/api/failback",
  "event": "failback_submitted",
  "result": "ok",
  "payload": {"request_id": "5d72d8ce...", "ts": 1746522345}
}
```

The audit logger refuses to start when the configured path is not
writable (`FAILOVER_WEB_AUDIT_LOG_REQUIRE_FILE=1`, the default). Set the
env to `0` only in tests / dev.

## Status code summary

| Code | When |
|------|------|
| 200 | Success (read, applied mutation, or restart-monitor). |
| 202 | Mutation accepted; daemon will pick it up. |
| 207 | Partial success (mutation persisted, side-effect failed). |
| 400 | Empty/malformed body. |
| 403 | CSRF / Origin / Referer rejected. |
| 409 | State precondition not met (failback while on primary, or anti-flapping cooldown still running — `status` distinguishes `noop` from `cooldown`). |
| 422 | Validation failed (range, type, unknown field). |
| 429 | Rate-limit or SSE per-IP cap hit. |
| 500 | Internal error during write/install. |
| 503 | Daemon state missing (snapshot freshness == "missing"). |
