#!/usr/bin/env python3
"""followerBot log server — read-only HTTP JSON access to bot.log,
audit_log.jsonl and trades.db, bucketed by calendar day.

Design goals (deliberately minimal, stdlib only, no dependencies):
- GET-only, read-only. No endpoint can write, restart, or touch .env.
- Bucketing by day happens HERE, by parsing each source's own timestamp —
  it does NOT require changing the bot's logging setup (bot.log rotates by
  SIZE, not by day, and a single day can span several rotated files; this
  server reads every bot.log* file present and re-buckets by the date each
  line actually carries, so the query-by-day API is correct regardless of
  how the underlying files happen to be rotated).
- One bearer token (LOG_SERVER_TOKEN), constant-time compared. No token
  configured -> refuses to start, rather than serving unauthenticated.
- Meant to run directly on the LXC host (plain Debian, no Docker/Wine
  needed) via the accompanying followerbot-logs.service unit, reading the
  same /opt/bot-config the bot container writes into.

Endpoints (all require "Authorization: Bearer <token>" except /health):
  GET /health
  GET /status
  GET /logs?from=YYYY-MM-DD&to=YYYY-MM-DD
  GET /audit?from=YYYY-MM-DD&to=YYYY-MM-DD
  GET /trades?from=YYYY-MM-DD&to=YYYY-MM-DD
"""
from __future__ import annotations

import hmac
import json
import os
import re
import sqlite3
import subprocess
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

BOT_CONFIG_DIR = Path(os.environ.get("BOT_CONFIG_DIR", "/opt/bot-config"))
APP_DIR = Path(os.environ.get("APP_DIR", "/opt/mi_trading_bot"))
HOST = os.environ.get("LOG_SERVER_HOST", "0.0.0.0")
PORT = int(os.environ.get("LOG_SERVER_PORT", "8765"))
TOKEN = os.environ.get("LOG_SERVER_TOKEN", "")
MAX_RANGE_DAYS = 31  # refuse absurdly large ranges (self-inflicted DoS guard)

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_LOG_LINE_DATE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}:\d{2}")


def _parse_date(s: str) -> date:
    if not _DATE_RE.match(s or ""):
        raise ValueError(f"invalid date {s!r}, expected YYYY-MM-DD")
    return datetime.strptime(s, "%Y-%m-%d").date()


def _day_range(from_str: str, to_str: str) -> list[str]:
    d_from, d_to = _parse_date(from_str), _parse_date(to_str)
    if d_to < d_from:
        raise ValueError("'to' is before 'from'")
    if (d_to - d_from).days + 1 > MAX_RANGE_DAYS:
        raise ValueError(f"range too large (max {MAX_RANGE_DAYS} days)")
    days = []
    d = d_from
    while d <= d_to:
        days.append(d.isoformat())
        d += timedelta(days=1)
    return days


def _bucket_bot_log(days: list[str]) -> dict:
    """Read every bot.log* file, bucket lines by the date each line (or, for
    a continuation line with no leading timestamp, the last seen date)
    carries. Independent of how the files happen to be rotated."""
    wanted = set(days)
    buckets: dict[str, list[str]] = {d: [] for d in days}
    log_files = sorted(BOT_CONFIG_DIR.glob("bot.log*"))
    for path in log_files:
        try:
            current_day = None
            with path.open("r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = _LOG_LINE_DATE_RE.match(line)
                    if m:
                        current_day = m.group(1)
                    if current_day in wanted:
                        buckets[current_day].append(line.rstrip("\n"))
        except OSError:
            continue
    return {d: {"count": len(lines), "lines": lines} for d, lines in buckets.items()}


def _bucket_audit_log(days: list[str]) -> dict:
    """audit_log.jsonl is one JSON object per line with a "ts" ISO8601
    field -- bucket by the date portion of that field."""
    wanted = set(days)
    buckets: dict[str, list[dict]] = {d: [] for d in days}
    path = BOT_CONFIG_DIR / "audit_log.jsonl"
    if not path.exists():
        return {d: {"count": 0, "events": []} for d in days}
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = obj.get("ts", "")
            day = ts[:10] if len(ts) >= 10 else None
            if day in wanted:
                buckets[day].append(obj)
    return {d: {"count": len(events), "events": events} for d, events in buckets.items()}


def _bucket_trades(days: list[str]) -> dict:
    """Trades whose open_time OR close_time falls on each day."""
    db_path = BOT_CONFIG_DIR / "trades.db"
    buckets: dict[str, dict] = {d: {"opened": [], "closed": []} for d in days}
    if not db_path.exists():
        return {d: {"count": 0, **v} for d, v in buckets.items()}

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        d_from, d_to = days[0], days[-1]
        rows = conn.execute(
            "SELECT * FROM trades WHERE substr(open_time, 1, 10) BETWEEN ? AND ? "
            "OR substr(close_time, 1, 10) BETWEEN ? AND ?",
            (d_from, d_to, d_from, d_to),
        ).fetchall()
    finally:
        conn.close()

    for row in rows:
        r = dict(row)
        open_day = (r.get("open_time") or "")[:10]
        close_day = (r.get("close_time") or "")[:10]
        if open_day in buckets:
            buckets[open_day]["opened"].append(r)
        if close_day in buckets:
            buckets[close_day]["closed"].append(r)

    return {
        d: {"count": len(v["opened"]) + len(v["closed"]), **v}
        for d, v in buckets.items()
    }


def _git_status() -> dict:
    def _run(args):
        try:
            return subprocess.run(
                args, cwd=APP_DIR, capture_output=True, text=True, timeout=5,
            ).stdout.strip()
        except Exception as e:  # noqa: BLE001 - best-effort status, never fatal
            return f"<error: {e}>"

    return {
        "commit": _run(["git", "log", "-1", "--format=%H %ci %s"]),
        "branch": _run(["git", "rev-parse", "--abbrev-ref", "HEAD"]),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "followerbot-log-server/1.0"

    def log_message(self, fmt, *args):  # quieter default access log
        pass

    def _send_json(self, status: int, payload: dict):
        body = json.dumps(payload, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        return hmac.compare_digest(auth[len("Bearer "):], TOKEN)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/health":
            self._send_json(200, {"ok": True})
            return

        if not self._authorized():
            self._send_json(401, {"error": "missing or invalid bearer token"})
            return

        try:
            if path == "/status":
                self._send_json(200, _git_status())
            elif path in ("/logs", "/audit", "/trades"):
                from_str = qs.get("from", [""])[0]
                to_str = qs.get("to", [""])[0]
                days = _day_range(from_str, to_str)
                if path == "/logs":
                    data = _bucket_bot_log(days)
                    source = "bot.log"
                elif path == "/audit":
                    data = _bucket_audit_log(days)
                    source = "audit_log.jsonl"
                else:
                    data = _bucket_trades(days)
                    source = "trades.db"
                self._send_json(200, {"source": source, "from": from_str, "to": to_str, "days": data})
            else:
                self._send_json(404, {"error": "unknown endpoint"})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001 - never leak a stack trace over HTTP
            self._send_json(500, {"error": "internal error", "detail": str(e)})


def main():
    if not TOKEN:
        raise SystemExit(
            "LOG_SERVER_TOKEN is not set -- refusing to start unauthenticated. "
            "Set it in the environment (see followerbot-logs.service)."
        )
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"followerBot log server listening on {HOST}:{PORT} (BOT_CONFIG_DIR={BOT_CONFIG_DIR})")
    server.serve_forever()


if __name__ == "__main__":
    main()
