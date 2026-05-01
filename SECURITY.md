# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in `linux-dual-wan-failover`, please
report it responsibly:

1. **Do NOT** open a public issue.
2. **Use GitHub Security Advisories**: navigate to the
   [Security tab](https://github.com/fidpa/linux-dual-wan-failover/security/advisories)
   and click "Report a vulnerability".
3. **Provide details**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if available)

## Response Timeline

- **Initial Response**: within 72 hours
- **Status Update**: within 7 days
- **Fix Timeline**: depends on severity (critical issues prioritized)

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.x.x   | :white_check_mark: (pre-1.0; latest minor only) |

Once 1.0 ships, the latest minor version of the current major plus the
previous major's last minor will be supported.

## Threat Model

`linux-dual-wan-failover` runs on a Linux router/gateway. Relevant security
boundaries:

| Boundary | Trust Level |
|----------|-------------|
| Local root on the router | trusted (config, services) |
| Backup-link modem API | semi-trusted (read-only HTTP, may be on a separate L2) |
| Snapshot files (`/var/lib/linux-dual-wan-failover/`) | trusted (root-owned) |
| systemd journal | trusted |
| Webhook endpoints (alerting plugins) | external (TLS recommended) |

The system does **not** open inbound network ports of its own. Failover
decisions are based on outbound connectivity probes (ICMP, DNS, HTTP) and
local routing-table inspection.

## Security Best Practices for Operators

- **Permissions**: `chmod 644` for sourced libraries, `chmod 755` for
  executables, `chmod 600` for `.env` files containing modem passwords or
  webhook URLs.
- **Secrets**: never commit `.env` files; use `.env.example` as a template.
- **systemd hardening**: keep `ProtectSystem=strict`, `PrivateTmp=true`,
  `NoNewPrivileges=true` enabled in shipped unit files.
- **Plugin code**: a custom quota-provider or alerting plugin runs with the
  same privileges as the failover service (typically root). Review plugin
  code before deploying.
- **Backup-modem API credentials**: store in `--password-env-file` or
  systemd `EnvironmentFile=`. Never embed in command lines or service
  arguments.

## Disclosure Policy

We follow responsible disclosure:

- Security issues are fixed before public disclosure.
- Credit is given to reporters (unless they prefer anonymity).
- CVE IDs are assigned for critical vulnerabilities.
