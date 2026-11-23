#!/usr/bin/env python3
"""Compile and run the real-WKWebView conversation-drift recovery check.

The check binds one loopback page as the saved conversation, then opens a
same-origin second page. It verifies that the pane:

* returns to the saved page only when the current page has no draft, attachment
  or live generation;
* leaves a draft, a generating page and an unreadable page untouched;
* does nothing when the caller's task/pause check says stop;
* never clicks the page's send control.

Run from the repository root:

    python3 tests/conversation_drift_recovery.py

Exit code 0 means every check passed. No app is launched, no real site is
contacted and no personal account or data is read.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
SITE_PANE = ROOT / "desktop" / "SitePane.swift"
CHECK = ROOT / "tests" / "conversation_drift_recovery.swift"
DRIVER = ROOT / "shared" / "web-driver.js"

PAGES = {
    "/ok": {},
    "/ok-b": {},
    "/draft": {},
    "/draft-b": {"draft": "留给用户的手写草稿"},
    "/busy": {},
    "/busy-b": {"stop": True},
    "/unknown": {},
    "/unknown-b": {"noEditor": True},
    "/pause": {},
    "/pause-b": {},
}


def markup(spec: dict) -> str:
    if spec.get("noEditor"):
        return "<!doctype html><meta charset=utf-8><main>登录</main>"
    draft = spec.get("draft", "")
    stop = '<button id="stop" style="display:block">stop</button>' if spec.get("stop") else ""
    return f"""<!doctype html><meta charset=utf-8>
<div id="turns"></div>
<textarea id="editor">{draft}</textarea>
<button id="send" aria-label="send">send</button>
{stop}
<script>
const editor = document.querySelector('#editor');
const send = document.querySelector('#send');
send.addEventListener('click', () => fetch('/click', {{ method: 'POST', body: editor.value }}));
</script>"""


def main() -> int:
    requests = []
    clicks = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlparse(self.path).path
            if path not in PAGES:
                self.send_error(404)
                return
            requests.append(path)
            body = markup(PAGES[path]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != "/click":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            clicks.append(self.rfile.read(length).decode())
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="arena-drift-check-") as temp:
            directory = Path(temp)
            # A bare executable resolves Bundle.main resources from its own
            # directory; put the real driver beside it.
            (directory / "web-driver.js").write_bytes(DRIVER.read_bytes())
            for name in ("SitePane.swift", "conversation_drift_recovery.swift"):
                source = SITE_PANE if name == "SitePane.swift" else CHECK
                (directory / name).write_bytes(source.read_bytes())
            binary = directory / "conversation-drift-recovery"
            compile_cmd = [
                "xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5",
                "-framework", "AppKit", "-framework", "WebKit", "-framework", "SwiftUI",
                str(directory / "SitePane.swift"),
                str(directory / "conversation_drift_recovery.swift"),
                "-o", str(binary),
            ]
            compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
            if compiled.returncode != 0:
                sys.stderr.write(compiled.stdout)
                sys.stderr.write(compiled.stderr)
                print("conversation drift recovery check did not compile", file=sys.stderr)
                return 1

            ran = subprocess.run(
                [str(binary), f"http://127.0.0.1:{server.server_port}"],
                text=True, capture_output=True, timeout=120,
            )
            sys.stdout.write(ran.stdout)
            sys.stderr.write(ran.stderr)
            if ran.returncode != 0:
                return ran.returncode
    finally:
        server.shutdown()
        server.server_close()

    assert clicks == [], f"send was clicked during drift recovery: {clicks}"
    # The pure-pane check now changes /ok and /draft with history.pushState, so
    # those second routes never reach HTTP. /busy, /unknown and /pause still
    # load real pages for the cases that must not be recovered.
    assert requests.count("/ok-b") == 0, requests
    assert requests.count("/ok") >= 2, requests
    assert requests.count("/draft-b") == 0, requests
    assert "/busy-b" in requests and "/unknown-b" in requests
    assert "/pause-b" in requests
    print("loopback checks: same-document safe return; no click or wrong-page send")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
