#!/usr/bin/env python3
"""Pre-click send repair: driver probe opt-in + native decision gate.

Target: G1/G3. A real Gemini vote round stayed in ``send-pending`` for about
90 s because the send control was missing/hidden before any click; reopening
the same confirmed conversation sent once immediately. The native app now has
one bounded automatic repair in its pre-click retry branch, and this test pins
its two halves:

1. The shipped ``shared/web-driver.js`` probe may carry an optional
   ``expectedPrompt`` and then returns ``composer.matchesExpectedPrompt``, using
   the same normalized ``sameText`` helper as submit. The probe stays read-only:
   it never writes the composer, never clicks, and its reply is byte-for-byte
   the old shape when the option is absent (existing callers unchanged).
2. ``desktop/ArenaModel.swift`` only allows the repair for Gemini, a
   ``prepared`` intent, a driver-confirmed ``pre-click`` answer with
   ``clickAttempted:false``, and a ``missing``/``hidden`` send control, once per
   task, after 20 s or 3 successive refusals. The composer must be empty or
   exactly this round's prompt, with no live Stop. ``SitePane`` accepts the
   comparison prompt only as a bounded, non-NUL string.

No real site, account, network, click or saved response is touched: the driver
runs against loopback HTML, and the native check is a pure compiled binary.

Run from the repository root:

    python3 tests/pre_click_send_repair.py

Exit code 0 means every check passed; nothing is written outside a temp dir.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixtures import find_chromium_executable  # noqa: E402
from swift_sources import stage_desktop_sources  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "shared" / "web-driver.js"

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #editor { display:block; width:640px; min-height:28px; border:1px solid #999; }
  #log .turn.user .msg, #log .turn.answer .msg { display:block; white-space:pre-wrap; }
</style>
<div id="editor" contenteditable="true"></div>
<button id="send">发送</button>
<button id="stop">停止</button>
<div id="log"></div>
<script>
(function () {
  'use strict';
  const cfg = Object.assign({ prefill: '', hideSend: false, stop: false },
                            window.__FIXTURE__ || {});
  const editor = document.getElementById('editor');
  const send = document.getElementById('send');
  const stop = document.getElementById('stop');
  if (cfg.prefill) editor.innerText = cfg.prefill;
  send.style.display = cfg.hideSend ? 'none' : '';
  stop.style.display = cfg.stop ? '' : 'none';
  window.clicks = 0;
  send.addEventListener('click', () => { window.clicks += 1; });
})();
</script>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(PAGE.encode("utf-8"))

    def log_message(self, *_):
        pass


def selectors() -> dict[str, str]:
    return {
        "input": "#editor",
        "send": "#send",
        "user": "#log .turn.user .msg",
        "answer": "#log .turn.answer .msg",
        "stop": "#stop",
    }


def new_page(ctx, base, fixture):
    page = ctx.new_page()
    page.add_init_script("window.__FIXTURE__ = " + json.dumps(fixture, ensure_ascii=False))
    page.goto(base + "/")
    page.add_script_tag(path=str(DRIVER))
    return page


def probe(page, base, task_id, expected=None):
    payload = {
        "type": "arena.web.probe",
        "taskId": task_id,
        "selectors": selectors(),
        "options": {},
        "scope": {"origin": base, "homeHref": base + "/", "allowNavigation": True},
    }
    if expected is not None:
        payload["expectedPrompt"] = expected
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def run_swift_checks() -> int:
    """Compile the native decision gate with a pure, non-app test binary."""
    with tempfile.TemporaryDirectory(prefix="arena-pre-click-check-") as temp:
        directory = Path(temp)
        # The check needs the whole desktop module (ArenaModel references the
        # evaluated-session digest). Compile a stable copy and drop only the
        # production @main from the copied ArenaApp.swift.
        sources = stage_desktop_sources(ROOT, directory)
        check = directory / "pre_click_send_repair.swift"
        check.write_bytes((ROOT / "tests" / "pre_click_send_repair.swift").read_bytes())
        binary = directory / "pre-click-send-repair-check"
        compile_cmd = [
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-swift-version",
            "5",
            "-framework",
            "AppKit",
            "-framework",
            "WebKit",
            "-framework",
            "SwiftUI",
            "-framework",
            "JavaScriptCore",
            *[str(source) for source in sources],
            str(check),
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("pre-click send repair check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


def main() -> int:
    swift_status = run_swift_checks()
    if swift_status != 0:
        return swift_status

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    prompt = "本轮完整提示：请比较两个方案。\n\n并说明你会改变立场的条件。"
    prompt_with_noise = "本轮完整提示：请比较两个方案。\u00a0 \n \n\n\n并说明你会改变立场的条件。 "
    human = "这是我自己写的草稿，绝不能被比较通过或覆盖。"
    failures = 0

    def check(name: str, value: bool) -> None:
        nonlocal failures
        if value:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name}")

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                executable_path=str(find_chromium_executable()),
            )
            ctx = browser.new_context()

            # A) Without the opt-in the probe reply keeps its exact old shape.
            page = new_page(ctx, base, {})
            reply = probe(page, base, "t-probe-old-shape")
            check("plain probe is ready", reply.get("status") == "ready")
            composer = reply["detail"]["composer"]
            check(
                "plain probe composer keys unchanged",
                set(composer) == {"kind", "draftChars", "draftEmpty", "enabled"},
            )
            check("plain probe reports an empty composer", composer["draftEmpty"] is True)
            check(
                "plain probe has no matchesExpectedPrompt",
                "matchesExpectedPrompt" not in composer,
            )
            check("plain probe never clicks", page.evaluate("window.clicks") == 0)
            page.close()

            # B) Exact full prompt, normalized whitespace -> matches, no write.
            page = new_page(ctx, base, {"prefill": prompt_with_noise})
            before = page.evaluate("document.querySelector('#editor').innerText")
            reply = probe(page, base, "t-probe-match", prompt)
            composer = reply["detail"]["composer"]
            check("opt-in probe is ready", reply.get("status") == "ready")
            check(
                "composer is the exact normalized prompt",
                composer.get("matchesExpectedPrompt") is True,
            )
            check("matching composer is not empty", composer["draftEmpty"] is False)
            check(
                "probe never rewrites the composer",
                page.evaluate("document.querySelector('#editor').innerText") == before,
            )
            check("probe still never clicks", page.evaluate("window.clicks") == 0)
            page.close()

            # C) A human draft is reported, never replaced.
            page = new_page(ctx, base, {"prefill": human})
            reply = probe(page, base, "t-probe-human", prompt)
            composer = reply["detail"]["composer"]
            check(
                "a human draft does not match this round's prompt",
                composer.get("matchesExpectedPrompt") is False,
            )
            check(
                "probe leaves the human draft untouched",
                page.evaluate("document.querySelector('#editor').innerText") == human,
            )
            check("human-draft probe never clicks", page.evaluate("window.clicks") == 0)
            page.close()

            # D) An empty composer never claims a match.
            page = new_page(ctx, base, {})
            reply = probe(page, base, "t-probe-empty", prompt)
            composer = reply["detail"]["composer"]
            check("empty composer is empty", composer["draftEmpty"] is True)
            check(
                "empty composer does not match a prompt",
                composer.get("matchesExpectedPrompt") is False,
            )
            page.close()

            # E) Opt-in payload validation fails closed.
            page = new_page(ctx, base, {"prefill": prompt})
            for label, value in (
                ("blank", " \n\t "),
                ("NUL", "a\u0000b"),
                ("over-long", "x" * 100_001),
                ("non-string", 42),
            ):
                reply = probe(page, base, f"t-probe-bad-{label}", value)
                check(
                    f"{label} expectedPrompt is rejected",
                    reply.get("status") == "error"
                    and reply.get("error") == "bad-message"
                    and reply.get("detail", {}).get("field") == "expectedPrompt",
                )
            check("rejected payloads never click", page.evaluate("window.clicks") == 0)
            page.close()

            # F) The real failing pre-click state: the send control is hidden.
            page = new_page(ctx, base, {"prefill": prompt, "hideSend": True})
            reply = probe(page, base, "t-probe-hidden-send", prompt)
            detail = reply.get("detail", {})
            check("hidden send control still probes ready", reply.get("status") == "ready")
            check("hidden send control is reported hidden", detail["send"]["visible"] is False)
            check(
                "hidden send control still confirms our complete prompt",
                detail["composer"].get("matchesExpectedPrompt") is True,
            )
            check("hidden send control never clicks", page.evaluate("window.clicks") == 0)
            page.close()

            # G) An active Stop is reported; the native gate must refuse then.
            page = new_page(ctx, base, {"prefill": prompt, "stop": True})
            reply = probe(page, base, "t-probe-stop", prompt)
            detail = reply.get("detail", {})
            check("probe with a live Stop is ready", reply.get("status") == "ready")
            check("live Stop is reported active", detail["stop"]["active"] is True)
            check(
                "live Stop does not change the composer comparison",
                detail["composer"].get("matchesExpectedPrompt") is True,
            )
            check("live Stop probe never clicks", page.evaluate("window.clicks") == 0)
            page.close()

            browser.close()
    finally:
        server.shutdown()

    if failures == 0:
        print("pre-click send repair: all driver checks passed")
        return 0
    print(f"pre-click send repair: {failures} driver check(s) failed")
    return 1


if __name__ == "__main__":
    sys.exit(main())
