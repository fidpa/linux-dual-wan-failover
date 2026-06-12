"""Tests for the alerts plugin dispatcher.

Verifies the documented plugin-resolution order:

  1. ``ALERTING_BACKEND=none`` (default) → no-op, returns False.
  2. ``ALERTING_PLUGIN_PATH`` overrides everything else.
  3. ``ALERTING_PLUGIN_DIR/<backend>.sh`` is the standard production lookup.
  4. ``<repo>/plugins/alerting/<backend>.sh`` is the dev/tests fallback.
"""

from __future__ import annotations

from pathlib import Path


def _write_plugin(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def _capture_plugin(path: Path) -> Path:
    """Return a plugin whose ``send_alert`` writes a file we can assert on."""
    capture = path.parent / f"{path.stem}.captured"
    body = f"""#!/usr/bin/env bash
send_alert() {{
    printf '%s\\n%s\\n' "$1" "$2" > {capture!s}
}}
"""
    _write_plugin(path, body)
    return capture


def test_default_backend_is_no_op(monkeypatch):
    from web import config as cfg
    from web.alerts import dispatcher

    monkeypatch.setattr(cfg, "ALERTING_BACKEND", "none")
    assert dispatcher.send("INFO_FAILOVER", "irrelevant") is False


def test_plugin_path_takes_precedence(tmp_path, monkeypatch):
    from web import config as cfg
    from web.alerts import dispatcher

    plugin = tmp_path / "plugins" / "custom.sh"
    capture = _capture_plugin(plugin)

    monkeypatch.setattr(cfg, "ALERTING_BACKEND", "custom")
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_PATH", str(plugin))
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_DIR", tmp_path / "absent")

    assert dispatcher.send("WARN_FAILOVER", "hello") is True
    assert capture.read_text(encoding="utf-8").strip().splitlines() == ["WARN_FAILOVER", "hello"]


def test_plugin_dir_lookup(tmp_path, monkeypatch):
    from web import config as cfg
    from web.alerts import dispatcher

    plugin_dir = tmp_path / "plugin-dir"
    plugin = plugin_dir / "fake.sh"
    capture = _capture_plugin(plugin)

    monkeypatch.setattr(cfg, "ALERTING_BACKEND", "fake")
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_PATH", "")
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_DIR", plugin_dir)

    assert dispatcher.send("CRIT_FAILOVER", "boom") is True
    assert capture.read_text(encoding="utf-8").splitlines()[0] == "CRIT_FAILOVER"


def test_missing_plugin_returns_false(tmp_path, monkeypatch):
    from web import config as cfg
    from web.alerts import dispatcher

    monkeypatch.setattr(cfg, "ALERTING_BACKEND", "no-such-backend")
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_PATH", "")
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_DIR", tmp_path / "absent")
    assert dispatcher.send("INFO_FAILOVER", "msg") is False


def test_plugin_failure_is_swallowed(tmp_path, monkeypatch):
    from web import config as cfg
    from web.alerts import dispatcher

    plugin = tmp_path / "fail.sh"
    plugin.write_text(
        "#!/usr/bin/env bash\nsend_alert() { return 17; }\n",
        encoding="utf-8",
    )
    plugin.chmod(0o755)

    monkeypatch.setattr(cfg, "ALERTING_BACKEND", "fail")
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_PATH", str(plugin))

    # Still False, but never raises — operator request flow must not block.
    assert dispatcher.send("CRIT_FAILOVER", "trigger") is False


def test_plugin_timeout(tmp_path, monkeypatch):
    from web import config as cfg
    from web.alerts import dispatcher

    plugin = tmp_path / "slow.sh"
    plugin.write_text(
        "#!/usr/bin/env bash\nsend_alert() { sleep 5; }\n",
        encoding="utf-8",
    )
    plugin.chmod(0o755)

    monkeypatch.setattr(cfg, "ALERTING_BACKEND", "slow")
    monkeypatch.setattr(cfg, "ALERTING_PLUGIN_PATH", str(plugin))

    assert dispatcher.send("WARN_FAILOVER", "x", timeout=0.5) is False
