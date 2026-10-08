#!/usr/bin/env python3
"""Serves this machine's Claude subscription usage over HTTP, for ClaudeUsageBar.

Runs where the Claude CLI is logged in (e.g. a Linux VM) and lets ClaudeUsageBar
on another machine show that account's usage without holding its login. The
server reads the CLI's stored access token, calls the same usage endpoint the
app does, and returns only the usage JSON -- the token never leaves this host.

It binds to 127.0.0.1 by default, so it is reachable only from this host or
through an SSH local forward such as

    ssh -N -L 127.0.0.1:7103:127.0.0.1:7103 <this-host>

Like the app, it never calls the OAuth token endpoint itself: a refresh from
here would rotate the refresh token underneath a running CLI session. The CLI
refreshes its own token whenever it runs, so with --keep-token-fresh the
server runs one tiny `claude -p` call (Haiku, no saved session) when the
stored token is expired or about to expire, or when the usage API refuses it
anyway, at most once per 10 minutes, and
lets the CLI do the refresh. Without it, an expired token answers
token_expired until any `claude` command on this host has refreshed it.

Endpoints:
    GET /usage   200 with the upstream usage JSON, unchanged; otherwise
                 {"error": <code>, "message": <text>} where code is one of
                 not_logged_in / token_expired (503), rate_limited (429),
                 upstream_error (502)
    GET /health  200 {"ok": true}

Python 3 standard library only.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
DEFAULT_CLAUDE_VERSION = "2.0.31"
# Answers are reused this long so a burst of refreshes is one upstream call.
CACHE_SECONDS = 30
VERSION_CHECK_SECONDS = 3600
# --keep-token-fresh nudges the CLI when the token has this long left...
NUDGE_MARGIN_SECONDS = 300
# ...and tries again no sooner than this if the nudge didn't refresh it.
NUDGE_RETRY_SECONDS = 600
NUDGE_COMMAND = ["claude", "-p", "OK", "--model", "haiku", "--no-session-persistence"]


class UsageError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def credentials_path():
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
    return Path(config_dir).expanduser() / ".credentials.json"


def read_credentials():
    """The CLI's stored access token and its expiry (epoch seconds, or None)."""
    path = credentials_path()
    try:
        root = json.loads(path.read_text())
    except FileNotFoundError:
        raise UsageError(503, "not_logged_in", f"no credentials at {path}")
    except (OSError, ValueError) as e:
        raise UsageError(502, "upstream_error", f"could not read {path}: {e}")

    creds = root.get("claudeAiOauth") or {}
    token = creds.get("accessToken")
    if not token:
        raise UsageError(503, "not_logged_in", f"no access token in {path}")
    expires_ms = creds.get("expiresAt")
    expires = expires_ms / 1000 if isinstance(expires_ms, (int, float)) else None
    return token, expires


def nudge_cli():
    """Runs a minimal `claude` call so the CLI refreshes its own stored token."""
    log("token expired or expiring; running claude so it refreshes its login")
    try:
        result = subprocess.run(NUDGE_COMMAND, capture_output=True, text=True,
                                timeout=120, stdin=subprocess.DEVNULL, cwd=Path.home())
        if result.returncode != 0:
            log(f"claude exited {result.returncode}: {result.stderr.strip()[:200]}")
    except (OSError, subprocess.SubprocessError) as e:
        log(f"could not run claude: {e}")


class ClaudeVersion:
    """`claude --version`, re-checked hourly, for the User-Agent header."""

    def __init__(self):
        self._value = DEFAULT_CLAUDE_VERSION
        self._checked = 0.0

    def get(self):
        if time.time() - self._checked > VERSION_CHECK_SECONDS:
            self._checked = time.time()
            try:
                out = subprocess.run(["claude", "--version"], capture_output=True,
                                     text=True, timeout=10).stdout
                match = re.search(r"\d+\.\d+\.\d+", out)
                if match:
                    self._value = match.group(0)
            except (OSError, subprocess.SubprocessError):
                pass
        return self._value


def fetch_usage(token, claude_version):
    request = urllib.request.Request(USAGE_URL, headers={
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": f"claude-code/{claude_version}",
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
    })
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:200]
        if e.code in (401, 403):
            raise UsageError(503, "token_expired", f"usage API refused the token (HTTP {e.code})")
        if e.code == 429:
            raise UsageError(429, "rate_limited", "usage API rate limited (429)")
        raise UsageError(502, "upstream_error", f"usage API HTTP {e.code}: {body}")
    except (urllib.error.URLError, OSError) as e:
        raise UsageError(502, "upstream_error", f"usage API unreachable: {e}")


class UsageSource:
    def __init__(self, keep_token_fresh):
        self._lock = threading.Lock()
        self._version = ClaudeVersion()
        self._cached = None  # (time, status, body)
        self._keep_token_fresh = keep_token_fresh
        self._last_nudge = 0.0

    def _can_nudge(self):
        return self._keep_token_fresh and time.time() - self._last_nudge > NUDGE_RETRY_SECONDS

    def _nudge(self):
        self._last_nudge = time.time()
        nudge_cli()

    def _access_token(self):
        token, expires = read_credentials()
        if (expires is not None and expires - time.time() < NUDGE_MARGIN_SECONDS
                and self._can_nudge()):
            self._nudge()
            token, expires = read_credentials()
        if expires is not None and expires <= time.time():
            raise UsageError(503, "token_expired", "stored access token is past its expiry")
        return token

    def _fetch(self):
        try:
            return fetch_usage(self._access_token(), self._version.get())
        except UsageError as e:
            # The API can refuse a token before its stored expiry (e.g. revoked
            # server-side); the CLI fixes that the same way, by refreshing.
            if e.code != "token_expired" or not self._can_nudge():
                raise
            log(f"usage {e.code}: {e.message}")
            self._nudge()
            return fetch_usage(self._access_token(), self._version.get())

    def answer(self):
        with self._lock:
            if self._cached and time.time() - self._cached[0] < CACHE_SECONDS:
                return self._cached[1:]
            try:
                body = self._fetch()
                result = (200, body)
            except UsageError as e:
                log(f"usage {e.code}: {e.message}")
                result = (e.status, json.dumps({"error": e.code, "message": e.message}).encode())
            self._cached = (time.time(), *result)
            return result


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, file=sys.stderr, flush=True)


def make_handler(source):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/usage":
                status, body = source.answer()
            elif path == "/health":
                status, body = 200, b'{"ok": true}'
            else:
                status, body = 404, b'{"error": "not_found"}'
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass  # errors are logged in UsageSource; successful polls stay quiet

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to bind (default 127.0.0.1; keep it loopback)")
    parser.add_argument("--port", type=int, default=7103, help="port (default 7103)")
    parser.add_argument("--keep-token-fresh", action="store_true",
                        help="run a tiny `claude -p` call when the stored token expires, "
                             "so the CLI refreshes it (uses a negligible amount of usage)")
    args = parser.parse_args()

    source = UsageSource(keep_token_fresh=args.keep_token_fresh)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(source))
    log(f"serving usage for {credentials_path()} on http://{args.host}:{args.port}/usage")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
