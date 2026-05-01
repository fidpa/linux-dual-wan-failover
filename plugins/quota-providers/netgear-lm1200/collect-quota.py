#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Netgear LM1200 / Sierra Wireless D86 quota provider.

Queries the modem's /api/model.json endpoint and writes a quota-snapshot.json
matching plugins/quota-providers/_schema/quota-snapshot.schema.json.

Tested firmware:
- Netgear LM1200 (FW NTGX_LM1200_xx.xx.xx.xx)
- Other Sierra Wireless D86-based devices may work — please open a PR if you
  test one and find it does/doesn't.

Auth flow:
    1. GET  /api/model.json                     → Guest session + secToken
    2. POST /Forms/config (token + password)    → upgrade to Admin
    3. GET  /api/model.json                     → full payload incl. dataUsage

Usage:
    collect-quota.py [--modem-ip IP] [--snapshot-path PATH]
                     [--password-env-file FILE | --password STRING]

The --password-env-file expects a shell-style file with:
    LM1200_PASSWORD=your-modem-admin-password
File must be mode 0600 and owned by the user running this script.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.cookiejar import CookieJar
from pathlib import Path
from typing import Any

# ---- Defaults ---------------------------------------------------------------

DEFAULT_MODEM_IP = "192.168.0.1"  # factory default for LM1200
DEFAULT_SNAPSHOT_PATH = "/var/lib/linux-dual-wan-failover/quota-snapshot.json"
DEFAULT_TIMEOUT = 10
USER_AGENT = "linux-dual-wan-failover/lm1200-quota-collector"
SECRET_KEY = "LM1200_PASSWORD"

logger = logging.getLogger("lm1200-quota")


# ---- Secret loading ---------------------------------------------------------


def load_password(args: argparse.Namespace) -> str:
    if args.password:
        return args.password

    env_password = os.getenv(SECRET_KEY)
    if env_password:
        return env_password

    if args.password_env_file:
        return _read_password_env_file(Path(args.password_env_file))

    raise SystemExit(
        f"No password provided. Use --password, $LM1200_PASSWORD, "
        f"or --password-env-file FILE."
    )


def _read_password_env_file(path: Path) -> str:
    """Read SECRET_KEY=value from a shell-style env file with 0600 perms."""
    if not path.exists():
        raise SystemExit(f"--password-env-file does not exist: {path}")

    mode = path.stat().st_mode & 0o777
    if mode & 0o077:
        raise SystemExit(
            f"Insecure permissions on {path}: {oct(mode)} (expected 0600 or stricter)"
        )

    prefix = f"{SECRET_KEY}="
    with path.open(encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or not line.startswith(prefix):
                continue
            value = line[len(prefix):]
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            else:
                value = value.split("#", 1)[0].strip()
            if not value:
                raise SystemExit(f"{SECRET_KEY} is empty in {path}")
            return value
    raise SystemExit(f"{SECRET_KEY} not found in {path}")


# ---- Modem client -----------------------------------------------------------


class ModemClient:
    """Minimal HTTP client for the Netgear LM1200 / Sierra D86 admin API."""

    def __init__(self, modem_ip: str, password: str, timeout: int = DEFAULT_TIMEOUT):
        self.base_url = f"http://{modem_ip}"
        self.password = password
        self.timeout = timeout
        self.cookie_jar = CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar),
        )
        self.opener.addheaders = [("User-Agent", USER_AGENT)]
        self._sec_token: str | None = None

    def _get(self, url: str) -> bytes:
        req = urllib.request.Request(url, method="GET")
        with self.opener.open(req, timeout=self.timeout) as resp:
            return resp.read()

    def _post_form(self, url: str, fields: dict[str, str]) -> int:
        body = urllib.parse.urlencode(fields).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        req.add_header("Referer", f"{self.base_url}/")
        with self.opener.open(req, timeout=self.timeout) as resp:
            return resp.status

    def _fetch_model(self) -> dict[str, Any]:
        raw = self._get(f"{self.base_url}/api/model.json")
        return json.loads(raw)

    def login(self) -> None:
        guest = self._fetch_model()
        self._sec_token = guest.get("session", {}).get("secToken", "")
        if not self._sec_token:
            raise RuntimeError("No secToken in Guest response — modem unreachable?")
        status = self._post_form(
            f"{self.base_url}/Forms/config",
            {"token": self._sec_token, "session.password": self.password},
        )
        if status not in (200, 204):
            raise RuntimeError(f"Login failed (HTTP {status})")
        admin = self._fetch_model()
        if admin.get("session", {}).get("userRole") != "Admin":
            raise RuntimeError(f"Admin login not granted (role={admin.get('session', {}).get('userRole')})")

    def fetch_model(self) -> dict[str, Any]:
        return self._fetch_model()


# ---- Field extraction -------------------------------------------------------


def extract_limit_pct(model: dict[str, Any]) -> float | None:
    """Extract usage percentage from model.json. Returns None if not configured."""
    wwan = model.get("wwan", {}) or {}
    data_usage = wwan.get("dataUsage", {}) or {}

    # Field shape varies slightly by firmware. Try the documented places.
    generic = data_usage.get("generic", {}) or {}

    transferred = generic.get("dataTransferred")  # bytes
    limit = generic.get("dataLimit")              # bytes; 0 / None = unlimited

    if not isinstance(transferred, (int, float)) or transferred < 0:
        return None
    if not isinstance(limit, (int, float)) or limit <= 0:
        return None

    return round(100.0 * float(transferred) / float(limit), 2)


# ---- Snapshot writing -------------------------------------------------------


def write_snapshot(path: Path, limit_pct: float | None) -> None:
    snapshot = {
        "limit_pct": limit_pct,
        "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "provider": "netgear-lm1200",
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


# ---- Main -------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="LM1200 quota provider.")
    parser.add_argument("--modem-ip", default=os.getenv("LM1200_MODEM_IP", DEFAULT_MODEM_IP))
    parser.add_argument(
        "--snapshot-path",
        default=os.getenv("QUOTA_SNAPSHOT_PATH", DEFAULT_SNAPSHOT_PATH),
    )
    parser.add_argument("--password-env-file")
    parser.add_argument("--password")  # avoid in production; visible in `ps`
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--dry-run", action="store_true",
                        help="Query the modem and print the snapshot, but don't write.")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    password = load_password(args)
    client = ModemClient(args.modem_ip, password, timeout=args.timeout)

    try:
        client.login()
        model = client.fetch_model()
        pct = extract_limit_pct(model)
    except Exception as exc:
        logger.error("Modem query failed: %s", exc)
        return 1

    if args.dry_run:
        snapshot = {
            "limit_pct": pct,
            "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "provider": "netgear-lm1200",
        }
        print(json.dumps(snapshot, indent=2))
        return 0

    write_snapshot(Path(args.snapshot_path), pct)
    logger.info("Snapshot written: limit_pct=%s path=%s", pct, args.snapshot_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
