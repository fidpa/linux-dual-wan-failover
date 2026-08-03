# Quickstart: 5 minutes from clone to working failover

> **You'll need:** a Linux box with two WAN uplinks, NetworkManager, root,
> and ~10 minutes for testing. This tutorial uses a fictional dual-WAN setup
> and assumes Raspberry Pi OS.

## What you'll build

```
┌──────────┐                                      ┌─────────┐
│ Internet │  ◀──── primary uplink ──── eth0 ─── │ Linux   │
│   (DSL)  │                                      │ box     │
└──────────┘                                      │         │
                                                  │         │  failover
┌──────────┐                                      │         │
│ Internet │  ◀──── backup uplink ──── lte0 ─── │         │  in <5 s
│ (LTE)    │                                      └─────────┘
└──────────┘
```

When the DSL link goes degraded or dies, the box switches the default route
to LTE within ~5 seconds. When DSL recovers and stays stable for 5 minutes,
it switches back.

## 1. Clone and inspect

```bash
git clone https://github.com/fidpa/linux-dual-wan-failover.git
cd linux-dual-wan-failover
ls
```

Don't install yet. Look at `config/failover.conf.example` first — that's
where you'll configure your interfaces.

## 2. Identify your interfaces

```bash
ip -br link
nmcli connection show --active
```

You should see two WAN-bound interfaces (e.g. `eth0` for DSL, `lte0` for
your LTE modem) with NetworkManager connection names.

## 3. Install

```bash
sudo ./install.sh
```

This:
- Copies scripts to `/usr/local/lib/linux-dual-wan-failover/`.
- Copies systemd units to `/etc/systemd/system/`.
- Creates `/etc/linux-dual-wan-failover/` (config) and
  `/var/lib/linux-dual-wan-failover/` (state).
- Does **not** start any services yet.

## 4. Configure

```bash
sudo cp config/failover.conf.example /etc/linux-dual-wan-failover/failover.conf
sudo $EDITOR /etc/linux-dual-wan-failover/failover.conf
```

The five lines you almost certainly need to change:

```bash
PRIMARY_IFACE=eth0                    # your real WAN interface
BACKUP_IFACE=lte0                     # your real backup interface
PRIMARY_NM_CONNECTION="WAN-Primary"   # from `nmcli connection show`
BACKUP_NM_CONNECTION="LTE-Backup"     # from `nmcli connection show`
ALERTING_BACKEND=none                 # set to mattermost/webhook later if you want alerts
```

Everything else has working defaults.

## 5. Enable and verify

```bash
sudo systemctl enable --now \
    failover-monitor.service \
    nmcli-failover-monitor.service \
    route-guardian.service \
    failover-metrics-collector.service

systemctl is-active \
    failover-monitor.service \
    nmcli-failover-monitor.service \
    route-guardian.service \
    failover-metrics-collector.service

journalctl -u failover-monitor -n 30
```

You should see something like:

```
Starting linux-dual-wan-failover — orchestrator...
[INFO] Loaded /etc/linux-dual-wan-failover/failover.conf
[INFO] PRIMARY=eth0 (metric 50), BACKUP=lte0 (metric 200)
[INFO] Initial scores: eth0=98, lte0=84  → active=eth0
[INFO] Entering main loop (CHECK_INTERVAL=15s)
```

## 6. Test it (the safe way)

**Don't** unplug your DSL — that's a real-world trigger but it tests
recovery from physical-layer events you may not be ready to handle. Use
this simulation instead:

```bash
# Briefly disconnect the primary via NetworkManager (recovers automatically).
sudo nmcli connection down "WAN-Primary"
journalctl -u failover-monitor -f
# Watch for: "Failover triggered: eth0 → lte0 (score 0)"
sleep 10
sudo nmcli connection up "WAN-Primary"
# Watch for: "Failback triggered: lte0 → eth0 (stable for 5 min)"
```

For a fuller treatment of safe testing — including a score-collapse
simulation that leaves the link up — see
[`docs/how-to/safe-failover-testing.md`](../how-to/safe-failover-testing.md).

## What's next

- [Configure Mattermost alerting](../how-to/configure-mattermost.md) so you
  get a ping when failover fires.
- [Set up quota tracking](../how-to/configure-quota-tracking.md) if your
  backup link is metered (LTE).
- [Install the optional Web-UI](../how-to/configure-web-ui.md) if you want
  operator buttons and a live dashboard (`sudo ./install.sh --with-web-ui`).
- [Read the architecture](../reference/architecture-overview.md) to
  understand what each service does and why there are four.
