# Configure the Web-UI

The optional Web-UI ships in `src/web/`. It is a Flask + gunicorn dashboard
that visualises `failover-monitor` state and exposes operator buttons for
manual failback, force-failover, monitor-restart, and config-editing.

> **Authentication is intentionally absent.** The web app is meant to sit
> behind a reverse proxy on a LAN-only host. The defence-in-depth layers
> are: network boundary (reverse proxy with IP allowlist), CSRF token +
> Origin/Referer check, per-IP rate-limit, JSON-Lines audit log,
> alerting on every mutation, and a daemon-side anti-flapping cooldown.
> If you need authentication, terminate it in your reverse proxy.

## Prerequisites

* `linux-dual-wan-failover` already installed and the four core services
  running (see [`tutorial/01-quickstart.md`](../tutorial/01-quickstart.md)).
* Python 3.10+ with the `venv` module
  (`apt install python3-venv` on Debian/Ubuntu).
* `jq` available on `$PATH` (used by the daemon to parse the manual-action
  payload).
* A reverse proxy you can put in front of `127.0.0.1:8091`. The repo ships
  an nginx example at [`systemd/failover-web.nginx.example`](../../systemd/failover-web.nginx.example);
  Caddy/Traefik/HAProxy work just as well — see "Other reverse proxies"
  below.

## 1. Install the Web-UI

Re-run the standard installer with the `--with-web-ui` flag:

```bash
sudo ./install.sh --with-web-ui
```

The flag adds these steps to the regular install:

* Creates the `wan-state` and `failover-web` system groups + user
  (`failover-web` is in both, no shell, no home).
* Copies `src/web/` to `/usr/local/lib/linux-dual-wan-failover/web/src/`.
* Creates a venv at `/usr/local/lib/linux-dual-wan-failover/web/venv/`
  and installs `src/web/requirements.txt`.
* Installs the validating config helper to
  `/usr/local/sbin/install-failover-conf` (mode `0750`, owned `root:root`).
* Installs `failover-web.service`, the sudoers fragment, and the
  tmpfiles fragment.
* Reloads systemd; the service is **not** enabled — that is your call.

The daemon's `failover-monitor.service` is updated by `install_systemd_units`
to create the `wan-state` subdirectory under its `RuntimeDirectory` with
mode `0775` and group `wan-state`. This is what lets `failover-web` (a
member of `wan-state`) drop the `manual_action.json` file there. The
`chgrp` is best-effort — if you install the Web-UI later, restart
`failover-monitor.service` once after running `install.sh --with-web-ui`
so the group flips into place.

## 2. Configure CSRF hosts

Edit `/etc/linux-dual-wan-failover/failover.conf` and uncomment:

```bash
FAILOVER_WEB_CSRF_HOSTS=failover.local,localhost
```

The list is comma-separated; every hostname in your `Origin` /
`Referer` header must match one of these. The default
(`localhost,127.0.0.1`) only works for `curl` smoke tests on the box
itself — set this to your reverse-proxy hostname before browser users
hit the UI.

## 3. (Optional) Cosmetic labels

The dashboard uses `Primary` / `Backup` by default. Override via
`failover.conf`:

```bash
FAILOVER_WEB_LABEL_PRIMARY=DSL
FAILOVER_WEB_LABEL_BACKUP=LTE
```

The labels appear in the hero card, the button captions ("Manual Failback
(LTE → DSL)"), and the diag interface picker. Useful when the operators
who read the dashboard are not the people who chose the kernel interface
names.

## 4. Wire alerting (optional)

The Web-UI shares the alerting plugin contract documented in
[`plugins/alerting/README.md`](../../plugins/alerting/README.md). To
mirror the daemon's Mattermost alerts on every web-driven mutation, set
in `failover.conf`:

```bash
ALERTING_BACKEND=mattermost
ALERT_MATTERMOST_WEBHOOK_URL=https://your-mattermost/hooks/abc123...
```

Then add the secret to `failover-web.service` via a drop-in:

```bash
sudo systemctl edit failover-web.service
```

```ini
[Service]
Environment="ALERTING_BACKEND=mattermost"
Environment="ALERT_MATTERMOST_WEBHOOK_URL=https://your-mattermost/hooks/abc123..."
```

The web app maps each mutation to the same severity tiers the daemon
uses:

| Mutation | Alert type |
|----------|------------|
| `POST /api/failback` | `WARN_FAILOVER` |
| `POST /api/force-failover` | `CRIT_FAILOVER` |
| `PUT /api/config` (success) | `INFO_FAILOVER` |
| `PUT /api/config` (installed but restart failed) | `WARN_FAILOVER` |

## 5. Drop the HTMX vendor file

The dashboard expects `htmx.min.js` in
`/usr/local/lib/linux-dual-wan-failover/web/src/web/static/vendor/`. The
installer leaves this empty so you can decide between an HTTPS download
or an air-gapped offline copy. The repo's
[`src/web/static/vendor/README.md`](../../src/web/static/vendor/README.md)
has the details; the short version is:

```bash
sudo curl -fL -o /usr/local/lib/linux-dual-wan-failover/web/src/web/static/vendor/htmx.min.js \
    https://unpkg.com/htmx.org@1.9.12/dist/htmx.min.js
```

Pin the version when you do this — the dashboard does not lock against a
SHA. HTMX is stable, so an in-place upgrade rarely breaks anything; treat
it like any other vendored dep and re-test.

## 6. Reverse proxy

The Flask app binds to `127.0.0.1:8091` only — it has no built-in TLS
or IP-allowlist support. The repo ships an nginx upstream sample at
[`systemd/failover-web.nginx.example`](../../systemd/failover-web.nginx.example).
Adapt it to your hostname and TLS setup, drop it in
`/etc/nginx/sites-available/`, symlink into `sites-enabled`, then
`nginx -t && systemctl reload nginx`.

The two non-negotiable proxy settings:

```nginx
# Overwrite, NOT append. failover-web reads the rightmost element of
# X-Forwarded-For and trusts it. Appending would let any LAN client
# inject a fake source IP.
proxy_set_header X-Forwarded-For $remote_addr;

# SSE needs no buffering and a long read timeout.
proxy_buffering off;
proxy_read_timeout 3600s;
```

### Other reverse proxies

The same constraints apply to Caddy, Traefik, and HAProxy:

* Overwrite (do not append) `X-Forwarded-For`.
* Allow long-lived connections (SSE pipe lifetime > 60 s).
* Restrict via your platform's IP allowlist mechanism.

A minimal Caddyfile:

```Caddyfile
failover.local {
    @lan remote_ip 10.0.0.0/8 192.168.0.0/16 172.16.0.0/12
    handle @lan {
        reverse_proxy 127.0.0.1:8091 {
            header_up X-Forwarded-For {remote_host}
            flush_interval -1
            transport http {
                read_timeout 1h
            }
        }
    }
    respond 403
}
```

## 7. Start the service

```bash
sudo systemctl enable --now failover-web.service
sudo systemctl restart failover-monitor.service   # picks up wan-state group
sudo systemctl status failover-web --no-pager
```

Smoke test from the box:

```bash
curl -s http://127.0.0.1:8091/health | jq .
# {
#   "freshness": "fresh",
#   "prom_age_seconds": 2,
#   "state_age_seconds": 1,
#   "status": "ok"
# }
```

Smoke test from a LAN client (replace the hostname):

```bash
curl -s https://failover.local/api/state | jq '.current_wan, .freshness'
# "primary"
# "fresh"
```

## 8. Use it

Open `https://<your-hostname>/` in a browser. The dashboard polls
`/api/state-html` every 5 s, renders interface cards with score / latency
/ loss / DNS / HTTP metrics, and surfaces two operator buttons:

* **Manual Failback** — only valid when the daemon is currently on backup.
* **Force Failover** — only valid when the daemon is currently on primary.

The `Configuration` accordion lists 16 whitelisted tunables; values are
range-checked client-side and re-validated server-side before staging.
The `Diagnostics` accordion runs `ping` / `dig` / `traceroute` / `mtr`
against an arbitrary target and streams the output via Server-Sent Events.

## 9. Logs

| Path | Contents |
|------|----------|
| `/var/log/linux-dual-wan-failover/failover-web.log` | gunicorn access + Flask app log |
| `/var/log/linux-dual-wan-failover/failover-web-audit.log` | JSON-Lines per mutation |
| `journalctl -u failover-web.service` | systemd lifecycle |
| `journalctl -u failover-monitor.service` | daemon-side processing of the manual_action |

Audit-log review:

```bash
sudo tail -50 /var/log/linux-dual-wan-failover/failover-web-audit.log \
  | jq -c '{ts, event, src_ip, result}'
```

## 10. Disable / remove

```bash
sudo systemctl disable --now failover-web.service
sudo rm -f /etc/sudoers.d/failover-web
sudo rm -f /etc/tmpfiles.d/failover-web.conf
sudo rm -rf /usr/local/lib/linux-dual-wan-failover/web
sudo rm -f /usr/local/sbin/install-failover-conf
# The failover-web user / wan-state group can be left in place — they
# don't hold any privilege without the sudoers fragment.
```

The daemon continues to ignore the missing `manual_action.json` after the
Web-UI is gone — the `process_manual_action_request` function is a cheap
`stat()` per loop iteration when the file doesn't exist.

## See also

* [`docs/reference/web-api.md`](../reference/web-api.md) — endpoint
  reference + payload schemas.
* [`docs/explanation/web-ui-architecture.md`](../explanation/web-ui-architecture.md) —
  privilege model, file-trigger rationale, threat model.
* [`src/web/README.md`](../../src/web/README.md) — module layout and
  developer-mode setup.
