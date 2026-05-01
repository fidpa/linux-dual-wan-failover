# Contributing to linux-dual-wan-failover

Thank you for considering a contribution! This project lives or dies on
real-world dual-WAN setups, so even bug reports and "this didn't work on my
ISP" stories help.

## Code of Conduct

This project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). By
participating you agree to uphold it.

## Getting Started

### Prerequisites

- Linux (any distro with `systemd` and `iproute2`)
- Bash 4.0+
- `nmcli` (NetworkManager) — required for the event-driven monitor
- `python3` 3.10+ — required for the metrics collector
- `shellcheck`, `bashate`, `bats-core`, `ruff` — required for tests/linting

```bash
# Raspberry Pi OS
sudo apt install shellcheck bats python3-pip
pip3 install --user bashate ruff
```

### Project Structure

```
linux-dual-wan-failover/
├── src/
│   ├── lib/             # Sourced libraries (common, performance, network, routing)
│   ├── services/        # Long-running daemons (Bash)
│   └── collectors/      # Helper collectors (Python)
├── plugins/
│   ├── alerting/        # none / mattermost / webhook
│   └── quota-providers/ # no-op / netgear-lm1200 / custom-template
├── systemd/             # Unit files
├── config/              # failover.conf.example + examples/
├── docs/                # Diataxis: tutorial / how-to / reference / explanation
└── tests/               # bats-core unit tests + mocks
```

### Local Development

1. **Fork** the repository on GitHub.
2. **Clone** your fork.
3. **Install dependencies** (see Prerequisites).
4. **Run the test suite** to confirm a clean baseline:
   ```bash
   bats tests/unit/
   shellcheck src/lib/*.sh src/services/*.sh
   ```

You don't need a real dual-WAN router to develop — most logic is testable
through the `tests/mocks/` shims for `ip`, `nmcli`, and `ping`.

## How to Contribute

### Reporting Bugs

Before opening an issue, search existing issues to avoid duplicates. Good
reports include:

- A clear, descriptive title
- Exact steps to reproduce
- Expected vs. actual behaviour
- Your environment: distro, Bash version, NetworkManager version, hardware
- Relevant logs (`journalctl -u failover-monitor -n 200`)
- Output of `ip route show` and `nmcli connection show` (sanitised)

### Suggesting Features

Open an issue with the feature-request template. Please include:

- The problem you're trying to solve
- Your proposed solution
- Alternatives you considered
- Why this would help most users (not just your specific setup)

### Pull Requests

1. Branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make changes following the coding standards below.
3. Run the test suite:
   ```bash
   bats tests/unit/
   shellcheck src/**/*.sh
   bashate src/**/*.sh
   ruff check src/collectors/ plugins/quota-providers/netgear-lm1200/
   ```
4. Update documentation under `docs/` and add a `CHANGELOG.md` entry.
5. Commit with a clear message.
6. Open the PR with a description that explains *why*, not just *what*.

## Coding Standards

### Bash

- Pass `shellcheck` cleanly (no warnings).
- Header: `#!/usr/bin/env bash` + `set -uo pipefail` (services additionally
  use trap-based cleanup).
- Always quote variables: `"$var"`, not `$var`.
- One responsibility per function (SRP).
- 4-space indentation, no tabs.
- Comments explain *why*, not *what*.

### Python

- Pass `ruff check`.
- Type hints on public function signatures.
- `pathlib` for paths; no `os.path.join` in new code.
- Standard library only for collectors — keep dependency surface minimal.

### Documentation

- English only.
- Diataxis structure (`tutorial/`, `how-to/`, `reference/`, `explanation/`).
- Every PR that adds or changes user-visible behaviour updates the relevant
  doc.
- `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/).

## Plugin Contributions

Quota-provider and alerting plugins are first-class contributions. To add a
plugin for your modem or alerting system:

1. Copy the matching `custom-template/` directory.
2. Implement the contract (see `plugins/quota-providers/README.md` or
   `plugins/alerting/README.md`).
3. Add a `README.md` documenting the upstream API, auth flow, and any
   firmware versions tested.
4. Open a PR — plugins ship in a separate PR from core changes.

## Release Process

Maintainers handle releases using semantic versioning (MAJOR.MINOR.PATCH):

- **MAJOR**: breaking changes (config format, plugin contract)
- **MINOR**: new features (new plugin slots, new metrics)
- **PATCH**: bug fixes

## Recognition

Contributors are listed in the README. Thank you for making this project
better!
