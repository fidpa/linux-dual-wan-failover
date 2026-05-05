"""linux-dual-wan-failover — operations Web-UI (optional add-on).

A Flask + gunicorn dashboard that visualises failover-monitor state,
exposes manual failback / force-failover / restart / config-editing
controls, and runs on-demand diagnostics (ping, dig, traceroute, mtr).

The whole module is read-only against the daemon by default — mutations
are deposited as a JSON file in ``RUNTIME_DIR/wan-state/manual_action.json``
and picked up by ``failover-monitor`` on its next loop iteration. No
privileged sudo escalation other than ``systemctl restart`` and a
root-owned validating config installer.

See ``docs/how-to/configure-web-ui.md`` for setup, and
``docs/explanation/web-ui-architecture.md`` for the trigger-path and
security model.
"""

__all__: list[str] = []
