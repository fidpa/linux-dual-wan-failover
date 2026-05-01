# no-op quota provider (default)

This is the **default**. There is no plugin file to install — selecting
`QUOTA_PROVIDER=none` (the default) tells `failover-monitor` to skip the
quota lookup entirely.

Use this when:

- Your backup link is unmetered (e.g., a second wired ISP).
- Your modem has no API to query usage.
- You want maximum simplicity and don't care about quota-aware capping.

To switch to a real provider:

1. Pick or write one (see [`../README.md`](../README.md)).
2. Install its systemd unit/timer (each provider's `README.md` has the
   install commands).
3. Set `QUOTA_PROVIDER=<provider-name>` in `/etc/linux-dual-wan-failover/failover.conf`.
4. `systemctl daemon-reload && systemctl restart failover-monitor`.
