#!/usr/bin/env python3
"""FenixNavi CIQ bridge.

Receives navigation_update messages from the web simulator (tools/simulator.html)
over HTTP and injects them into the running Connect IQ Simulator via AppleScript
("Simulator -> Phone App Message").

Usage:
    python3 ciq_bridge.py            # listens on http://localhost:8765

Environment variables (optional):
    CIQ_BRIDGE_PORT   port to listen on (default 8765)
    CIQ_PROCESS       AppleScript process name for the simulator (default "ConnectIQ")
"""
import http.server
import json
import os
import subprocess
import tempfile

PORT = int(os.environ.get("CIQ_BRIDGE_PORT", "8765"))
PROCESS = os.environ.get("CIQ_PROCESS", "ConnectIQ")


def apple_escape(s: str) -> str:
    """Escape a string so it can be embedded as an AppleScript string literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def inject(message: dict) -> None:
    """Inject a navigation message into the CIQ simulator via AppleScript."""
    json_str = json.dumps(message)
    escaped = apple_escape(json_str)

    script = f'''
tell application "System Events"
    tell process "{PROCESS}"
        click menu item "Phone App Message" of menu "Simulator" of menu bar 1
        delay 0.6
        set value of text field 1 of window 1 to "{escaped}"
        delay 0.2
        click button "Send" of window 1
    end tell
end tell
'''

    with tempfile.NamedTemporaryFile("w", suffix=".scpt", delete=False) as f:
        f.write(script)
        path = f.name
    try:
        subprocess.run(["osascript", path], check=True, capture_output=True)
    finally:
        os.unlink(path)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            message = json.loads(body)
            inject(message)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        except Exception as e:  # noqa: BLE001
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ciq-bridge running")

    def log_message(self, *args):  # keep the console clean
        pass


if __name__ == "__main__":
    print(f"CIQ bridge listening on http://localhost:{PORT} (process '{PROCESS}')")
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
