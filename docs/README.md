# Documentation index

> Looking for the project README? See [../README.md](../README.md).

This documentation follows the [Diataxis](https://diataxis.fr/) framework:
**tutorial** (learning-oriented), **how-to** (task-oriented),
**reference** (information-oriented), **explanation** (understanding-oriented).

## I want to…

| Goal | Start with |
|---|---|
| …get running for the first time | [tutorial/01-quickstart.md](tutorial/01-quickstart.md) |
| …install on production from source | [how-to/install-from-source.md](how-to/install-from-source.md) |
| …debug a real failover incident | [how-to/debug-failover.md](how-to/debug-failover.md) |
| …trace one failover across all services | [how-to/trace-failover.md](how-to/trace-failover.md) |
| …test failover safely without breaking SSH | [how-to/safe-failover-testing.md](how-to/safe-failover-testing.md) |
| …add Mattermost alerts | [how-to/configure-mattermost.md](how-to/configure-mattermost.md) |
| …track LTE quota | [how-to/configure-quota-tracking.md](how-to/configure-quota-tracking.md) |
| …run the optional Web-UI | [how-to/configure-web-ui.md](how-to/configure-web-ui.md) |
| …look up a config variable | [reference/config.md](reference/config.md) |
| …read a Prometheus metric | [reference/metrics.md](reference/metrics.md) |
| …call the Web-UI HTTP API | [reference/web-api.md](reference/web-api.md) |
| …understand the scoring algorithm | [reference/scoring.md](reference/scoring.md) |
| …understand the architecture | [reference/architecture-overview.md](reference/architecture-overview.md) |
| …know WHY the design is what it is | see Explanation docs below |

## Explanation docs

| Document | Answers |
|---|---|
| [explanation/why-event-driven.md](explanation/why-event-driven.md) | Why polling alone isn't enough, and what the event path buys. |
| [explanation/why-dual-service.md](explanation/why-dual-service.md) | Why detection and orchestration are separate services. |
| [explanation/anti-flapping.md](explanation/anti-flapping.md) | Thresholds, cooldowns, stability windows — and why failback fails more often than failover. |
| [explanation/state-file-ownership.md](explanation/state-file-ownership.md) | The single-writer rule, atomic writes, and why `/run` state vanishes on restart. |
| [explanation/web-ui-architecture.md](explanation/web-ui-architecture.md) | The Web-UI's file-trigger handshake, privilege split, and threat model. |

## Recommended reading order

**First-time installer**

1. [tutorial/01-quickstart.md](tutorial/01-quickstart.md) — 5-minute walk-through with a fictional setup
2. [how-to/install-from-source.md](how-to/install-from-source.md) — exact files deployed where
3. [reference/config.md](reference/config.md) — config variables reference

**Debugging an incident**

1. [how-to/debug-failover.md](how-to/debug-failover.md) — structured runbook for common failure modes
2. [reference/architecture-overview.md](reference/architecture-overview.md) — data flow and coordination primitives
3. [explanation/anti-flapping.md](explanation/anti-flapping.md) — thresholds, cooldowns, and why failback fails more often

**Plugin author (alerting or quota provider)**

1. [reference/architecture-overview.md](reference/architecture-overview.md) — understand the four-service architecture
2. [explanation/state-file-ownership.md](explanation/state-file-ownership.md) — single-writer rule and atomic-write pattern
3. [../plugins/quota-providers/README.md](../plugins/quota-providers/README.md) — quota snapshot schema and contract
4. [../plugins/alerting/README.md](../plugins/alerting/README.md) — `send_alert()` contract and selection mechanism

## Mapping to conventional filenames

If you came expecting flat filenames like `SETUP.md` or `TROUBLESHOOTING.md`:

| Conventional name | This repo |
|---|---|
| `SETUP.md` | [how-to/install-from-source.md](how-to/install-from-source.md) |
| `TROUBLESHOOTING.md` | [how-to/debug-failover.md](how-to/debug-failover.md) |
| `ARCHITECTURE.md` | [reference/architecture-overview.md](reference/architecture-overview.md) |
| `MONITORING.md` | [reference/metrics.md](reference/metrics.md) |
