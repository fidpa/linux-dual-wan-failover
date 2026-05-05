"""WSGI entry point for gunicorn.

Production invocation::

    gunicorn --bind 127.0.0.1:8091 \\
             --workers 2 --worker-class gthread --threads 4 \\
             linux_dual_wan_failover_web.wsgi:app

The systemd unit ``failover-web.service`` ships a working invocation.
"""

from .app import app

__all__ = ["app"]
