#!/usr/bin/env python3
"""Authenticated HTTP -> local HEAVN Bluetooth controller bridge for macOS.

Keep this file beside heavn.swift. Start manually; no service is installed.
Required: HEAVN_BRIDGE_TOKEN (at least 24 characters).
Optional: HEAVN_BRIDGE_HOST (default 127.0.0.1), HEAVN_BRIDGE_PORT (default 8765),
HEAVN_DEVICE_NAME (default HEAVN_One2 67a9).
GET /status; POST /on, /off, /toggle. Authorization: Bearer <token>.
"""
import hmac
import json
import os
from pathlib import Path
import shutil
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit


def main():
    token = os.environ.get("HEAVN_BRIDGE_TOKEN", "")
    if len(token) < 24:
        raise SystemExit("Set HEAVN_BRIDGE_TOKEN to a random secret of at least 24 characters.")
    swift = shutil.which("swift")
    script = Path(__file__).resolve().with_name("heavn.swift")
    if not swift or not script.is_file():
        raise SystemExit("Requires Swift command-line tools and heavn.swift beside this file.")
    name = os.environ.get("HEAVN_DEVICE_NAME", "HEAVN_One2 67a9")
    host = os.environ.get("HEAVN_BRIDGE_HOST", "127.0.0.1")
    port = int(os.environ.get("HEAVN_BRIDGE_PORT", "8765"))

    class Handler(BaseHTTPRequestHandler):
        server_version = "HEAVNBridge/1.0"

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

        def dispatch(self, method):
            auth = self.headers.get("Authorization", "")
            if not hmac.compare_digest(auth.encode(), ("Bearer " + token).encode()):
                self.reply(401, {"error": "Unauthorized"})
                return
            path = urlsplit(self.path).path
            operations = {"/status": "status", "/on": "on", "/off": "off", "/toggle": "toggle"}
            if path not in operations:
                self.reply(404, {"error": "Unknown endpoint"})
                return
            if method != ("GET" if path == "/status" else "POST"):
                self.reply(405, {"error": "Use GET /status or POST /on, /off, /toggle"})
                return
            try:
                result = subprocess.run([swift, str(script), operations[path], name],
                                        capture_output=True, text=True, timeout=45)
                try:
                    body = json.loads(result.stdout)
                except ValueError:
                    body = {"error": "Controller did not return JSON", "details": result.stderr[-2000:]}
                self.reply(200 if result.returncode == 0 and "error" not in body else 502, body)
            except subprocess.TimeoutExpired:
                # A toggle may have reached the lamp: never automatically retry it.
                self.reply(504, {"error": "Controller timed out; query /status before retrying"})
            except OSError as error:
                self.reply(502, {"error": str(error)})

        def do_GET(self):
            self.dispatch("GET")

        def do_POST(self):
            self.dispatch("POST")

    # Serial requests prevent competing BLE connections to the same lamp.
    server = HTTPServer((host, port), Handler)
    print(f"HEAVN bridge listening on http://{host}:{port}; device={name}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
