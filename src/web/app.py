"""Flask application for the linux-dual-wan-failover Web-UI.

Endpoints
---------

Read-only (no CSRF, no rate-limit):

  * ``GET  /``                       — HTML dashboard
  * ``GET  /api/state``              — JSON snapshot
  * ``GET  /api/state-html``         — HTML fragment (HTMX-poll target, every 5 s)
  * ``GET  /api/events/stream``      — SSE stream of state events
  * ``GET  /api/history``            — recent failover events from SQLite
  * ``GET  /api/config``             — whitelisted tunables + current values
  * ``GET  /health``                 — liveness + freshness probe

Mutating (CSRF + rate-limit + audit + alert):

  * ``POST /api/failback``           — manual failback (backup → primary)
  * ``POST /api/force-failover``     — manual failover (primary → backup)
  * ``POST /api/restart-monitor``    — restart failover-monitor.service
  * ``PUT  /api/config``             — apply whitelisted config updates
  * ``POST /api/diag/<tool>``        — on-demand ping/dig/traceroute/mtr (SSE)

All mutations write to ``MANUAL_ACTION_FILE`` (atomic temp+rename) — the
daemon picks them up on its next loop iteration. The web-app never touches
the kernel routing table directly.
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Iterator
from logging.handlers import RotatingFileHandler

from flask import Flask, Response, jsonify, render_template, request, stream_with_context
from flask.typing import ResponseReturnValue
from jinja2 import select_autoescape

from . import config
from .alerts import dispatcher
from .diag import runner as diag_runner
from .middleware import audit_log
from .middleware.csrf import csrf_protect, init_csrf
from .middleware.rate_limit import rate_limit
from .middleware.sse_limit import reserve_slot as reserve_sse_slot
from .readers import config_reader, events_reader, state_reader
from .writers import config_writer, manual_action_writer, service_controller


def _configure_logging(app: Flask) -> None:
    handler = RotatingFileHandler(
        config.APP_LOG,
        maxBytes=config.LOG_MAX_BYTES,
        backupCount=config.LOG_BACKUP_COUNT,
    )
    handler.setFormatter(
        logging.Formatter("[%(asctime)s] [%(levelname)s] [%(name)s] %(message)s")
    )
    app.logger.handlers = [handler]
    app.logger.setLevel(logging.INFO)
    for name in ("werkzeug", "gunicorn.error", "gunicorn.access"):
        lg = logging.getLogger(name)
        lg.handlers = [handler]
        lg.setLevel(logging.INFO)


def create_app() -> Flask:
    if not config.CSRF_ALLOWED_HOSTS:
        raise RuntimeError(
            "FAILOVER_WEB_CSRF_HOSTS resolved to an empty tuple — refusing to "
            "start with Origin/Referer checks disabled. Set the env to a "
            "comma-separated host list or unset it to use the default."
        )
    app = Flask(__name__, template_folder="templates", static_folder="static")
    # Force autoescape on every template extension served by this app — defence
    # in depth against stored XSS through e.g. `.html.j2` files.
    app.jinja_env.autoescape = select_autoescape(
        enabled_extensions=("html", "htm", "j2", "xml"),
        default_for_string=True,
        default=True,
    )
    app.jinja_env.globals["iface_labels"] = config.INTERFACE_LABELS
    app.jinja_env.globals["primary_label"] = config.PRIMARY_LABEL
    app.jinja_env.globals["backup_label"] = config.BACKUP_LABEL
    app.jinja_env.globals["primary_iface"] = config.PRIMARY_IFACE
    app.jinja_env.globals["backup_iface"] = config.BACKUP_IFACE
    app.jinja_env.globals["diag_interfaces"] = config.DIAG_INTERFACES
    app.jinja_env.globals["target_service"] = config.TARGET_SERVICE
    try:
        _configure_logging(app)
    except (PermissionError, FileNotFoundError):
        app.logger.addHandler(logging.StreamHandler())
        app.logger.setLevel(logging.INFO)

    init_csrf(app)

    @app.get("/")
    def index() -> ResponseReturnValue:
        snap = state_reader.read_snapshot()
        return render_template("dashboard.html.j2", snapshot=snap)

    @app.get("/api/state-html")
    def api_state_html() -> ResponseReturnValue:
        snap = state_reader.read_snapshot()
        return render_template("_state_panel.html.j2", snapshot=snap)

    @app.get("/api/state")
    def api_state() -> ResponseReturnValue:
        snap = state_reader.read_snapshot()
        return jsonify(state_reader.snapshot_to_dict(snap))

    @app.get("/api/events/stream")
    def api_events_stream() -> ResponseReturnValue:
        slot_cm = reserve_sse_slot()
        slot = slot_cm.__enter__()
        if slot is None:
            slot_cm.__exit__(None, None, None)
            return jsonify(
                {
                    "error": "sse_per_ip_limit",
                    "limit": config.SSE_MAX_CONNECTIONS_PER_IP,
                    "detail": "Too many concurrent SSE connections from this IP",
                }
            ), 429

        def generate() -> Iterator[str]:
            try:
                last_heartbeat = time.monotonic()
                while True:
                    snap = state_reader.read_snapshot()
                    payload = json.dumps(state_reader.snapshot_to_dict(snap), separators=(",", ":"))
                    yield f"event: state\ndata: {payload}\n\n"
                    tick = config.SSE_TICK_SECONDS
                    slept = 0.0
                    step = 0.5
                    while slept < tick:
                        time.sleep(step)
                        slept += step
                        if time.monotonic() - last_heartbeat >= config.SSE_HEARTBEAT_SECONDS:
                            yield ": heartbeat\n\n"
                            last_heartbeat = time.monotonic()
            finally:
                slot_cm.__exit__(None, None, None)

        return Response(
            stream_with_context(generate()),
            mimetype="text/event-stream",
            headers={
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    @app.get("/api/history")
    def api_history() -> ResponseReturnValue:
        try:
            days = int(request.args.get("days", "30"))
        except ValueError:
            days = 30
        try:
            limit = int(request.args.get("limit", "1000"))
        except ValueError:
            limit = 1000
        events = events_reader.list_events(days=days, limit=limit)
        return jsonify({"days": days, "count": len(events), "events": events})

    @app.post("/api/failback")
    @csrf_protect
    @rate_limit("failback", max_calls=1, per_seconds=60)
    def api_failback() -> ResponseReturnValue:
        snap = state_reader.read_snapshot()
        if snap.freshness == "missing":
            audit_log.emit("failback_rejected", result="rejected", payload={"reason": "state_missing"})
            return jsonify({"error": "state_missing", "detail": "Daemon state not readable"}), 503
        if snap.current_wan != "backup":
            audit_log.emit(
                "failback_noop",
                result="noop",
                payload={"current_wan": snap.current_wan, "freshness": snap.freshness},
            )
            return jsonify(
                {
                    "status": "noop",
                    "detail": (
                        f"Already on {snap.current_wan}; failback only valid when "
                        "current_wan=backup"
                    ),
                    "current_wan": snap.current_wan,
                }
            ), 409

        result = manual_action_writer.submit_action("failback")
        if not result["submitted"]:
            audit_log.emit(
                "failback_failed",
                result="error",
                payload={"request_id": result["request_id"], "detail": result.get("detail")},
            )
            return jsonify({"error": "submission_failed", **result}), 500

        audit_log.emit(
            "failback_submitted",
            result="ok",
            payload={"request_id": result["request_id"], "ts": result["ts"]},
        )
        dispatcher.send(
            "WARN_FAILOVER",
            f"Manual failback triggered via web-ui "
            f"(request_id={result['request_id']}, current_wan={snap.current_wan})",
        )
        return jsonify(
            {
                "status": "submitted",
                "request_id": result["request_id"],
                "ts": result["ts"],
                "detail": "Daemon will process within next check interval (15s).",
            }
        ), 202

    @app.get("/api/config")
    def api_config_read() -> ResponseReturnValue:
        descs = config_reader.read_whitelisted_config()
        return jsonify(
            {
                "fields": config_reader.descriptors_to_dict(descs),
                "config_path": str(config.CONFIG_PATH),
            }
        )

    @app.put("/api/config")
    @csrf_protect
    @rate_limit("config_put", max_calls=1, per_seconds=30)
    def api_config_put() -> ResponseReturnValue:
        if request.is_json:
            submitted = request.get_json(silent=True) or {}
        else:
            submitted = dict(request.form.items())
        if not isinstance(submitted, dict) or not submitted:
            return jsonify({"error": "empty_body", "detail": "Send a JSON object or form data"}), 400

        accepted, errors = config_reader.validate_updates(submitted)
        if errors:
            audit_log.emit(
                "config_validation_failed",
                result="rejected",
                payload={"errors": errors, "submitted_keys": sorted(submitted.keys())},
            )
            return jsonify({"error": "validation_failed", "errors": errors, "accepted": accepted}), 422

        result = config_writer.apply_updates(accepted)
        status = result.get("status")
        if status in ("applied", "noop"):
            audit_log.emit(
                "config_updated",
                result="ok",
                payload={"applied": result.get("applied", []), "values": accepted},
            )
            dispatcher.send(
                "INFO_FAILOVER",
                f"failover.conf updated via web-ui "
                f"(applied: {', '.join(result.get('applied', []) or ['<none>'])})",
            )
            return jsonify(result), 200
        if status == "installed_but_restart_failed":
            audit_log.emit(
                "config_updated_restart_failed",
                result="warning",
                payload={
                    "applied": result.get("applied", []),
                    "values": accepted,
                    "detail": result.get("detail"),
                },
            )
            dispatcher.send(
                "WARN_FAILOVER",
                "failover.conf updated via web-ui but daemon restart failed — "
                f"applied={result.get('applied', [])} detail={result.get('detail')}",
            )
            return jsonify(result), 207
        audit_log.emit("config_update_failed", result="error", payload=result)
        return jsonify(result), 500

    @app.post("/api/force-failover")
    @csrf_protect
    @rate_limit("force_failover", max_calls=1, per_seconds=120)
    def api_force_failover() -> ResponseReturnValue:
        snap = state_reader.read_snapshot()
        if snap.freshness == "missing":
            audit_log.emit("force_failover_rejected", result="rejected", payload={"reason": "state_missing"})
            return jsonify({"error": "state_missing"}), 503
        if snap.current_wan != "primary":
            audit_log.emit(
                "force_failover_noop",
                result="noop",
                payload={"current_wan": snap.current_wan},
            )
            return jsonify(
                {
                    "status": "noop",
                    "detail": (
                        f"Already on {snap.current_wan}; force_failover only valid "
                        "when current_wan=primary"
                    ),
                    "current_wan": snap.current_wan,
                }
            ), 409

        result = manual_action_writer.submit_action("force_failover")
        if not result["submitted"]:
            audit_log.emit(
                "force_failover_failed",
                result="error",
                payload={"request_id": result["request_id"], "detail": result.get("detail")},
            )
            return jsonify({"error": "submission_failed", **result}), 500

        audit_log.emit(
            "force_failover_submitted",
            result="ok",
            payload={"request_id": result["request_id"], "ts": result["ts"]},
        )
        dispatcher.send(
            "CRIT_FAILOVER",
            f"Force-failover triggered via web-ui "
            f"(request_id={result['request_id']}, current_wan={snap.current_wan})",
        )
        return jsonify(
            {
                "status": "submitted",
                "request_id": result["request_id"],
                "ts": result["ts"],
                "detail": "Daemon will process within next check interval (15s).",
            }
        ), 202

    @app.post("/api/restart-monitor")
    @csrf_protect
    @rate_limit("restart_monitor", max_calls=1, per_seconds=300)
    def api_restart_monitor() -> ResponseReturnValue:
        audit_log.emit("restart_monitor_requested", payload={})
        # Use the historical name; both `restart_failover_monitor` and
        # `restart_target_service` resolve to the same callable. Existing
        # tests monkeypatch `web.app.service_controller.restart_failover_monitor`.
        result = service_controller.restart_failover_monitor()
        if not result["ok"]:
            audit_log.emit("restart_monitor_failed", result="error", payload=result)
            return jsonify({"error": "restart_failed", **result}), 500
        dispatcher.send(
            "INFO_FAILOVER",
            f"{config.TARGET_SERVICE} restarted via web-ui (counters reset).",
        )
        audit_log.emit("restart_monitor_succeeded", result="ok", payload=result)
        return jsonify({"status": "restarted", **result}), 200

    @app.post("/api/diag/<tool>")
    @csrf_protect
    @rate_limit("diag", max_calls=1, per_seconds=10)
    def api_diag(tool: str) -> ResponseReturnValue:
        if request.is_json:
            data = request.get_json(silent=True) or {}
        else:
            data = dict(request.form.items())

        target = str(data.get("target", "")).strip()
        iface = data.get("iface") or None
        try:
            count = int(data.get("count", 4))
        except (TypeError, ValueError):
            count = 4

        try:
            argv = diag_runner.build_command(tool, target=target, iface=iface, count=count)
        except ValueError as exc:
            audit_log.emit(
                "diag_rejected",
                result="rejected",
                payload={"tool": tool, "target": target, "iface": iface, "detail": str(exc)},
            )
            return jsonify({"error": "invalid_input", "detail": str(exc)}), 400

        audit_log.emit(
            "diag_started",
            result="ok",
            payload={"tool": tool, "target": target, "iface": iface, "count": count},
        )

        slot_cm = reserve_sse_slot()
        slot = slot_cm.__enter__()
        if slot is None:
            slot_cm.__exit__(None, None, None)
            return jsonify(
                {
                    "error": "sse_per_ip_limit",
                    "limit": config.SSE_MAX_CONNECTIONS_PER_IP,
                }
            ), 429

        def gen() -> Iterator[str]:
            try:
                yield from diag_runner.stream_command(argv)
            finally:
                slot_cm.__exit__(None, None, None)

        return Response(
            stream_with_context(gen()),
            mimetype="text/event-stream",
            headers={
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    @app.get("/health")
    def health() -> ResponseReturnValue:
        snap = state_reader.read_snapshot()
        return jsonify(
            {
                "status": "ok" if snap.freshness != "missing" else "degraded",
                "freshness": snap.freshness,
                "state_age_seconds": snap.state_age_seconds,
                "prom_age_seconds": snap.prom_age_seconds,
            }
        )

    return app


# WSGI entry point for gunicorn (also re-exported by wsgi.py).
app = create_app()


if __name__ == "__main__":
    # Local development only; production uses gunicorn.
    app.run(host=config.WEB_BIND, port=config.WEB_PORT, debug=False, threaded=True)
