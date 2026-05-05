# Vendor assets

Drop-in third-party JavaScript libraries used by the dashboard.

The web-app is HTMX-driven (no Webpack, no npm build). It expects exactly
one file in this directory:

| File | Source | License | Why we vendor it |
|------|--------|---------|------------------|
| `htmx.min.js` | https://htmx.org/ | BSD-2-Clause | Reactive `hx-get` / `hx-post` / `hx-swap` attributes used in the templates. |

`install.sh --with-web-ui` downloads the current HTMX release into this
directory; the script writes a SHA-256 stamp next to the file so a
re-install is idempotent. If you prefer to manage the file yourself
(e.g. for an offline install), drop your copy here as `htmx.min.js`
before starting `failover-web.service`.

## Why no CDN reference

The dashboard is intended to run on a LAN-only host that may not have
outbound HTTPS at all (homelab routers behind a CGNAT, sites with strict
egress filters). Bundling the JS via the static directory keeps the UI
working without a working internet path.
