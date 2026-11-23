#!/usr/bin/env python3
"""Loopback check for ChatGPT's English (no-testid) send and stop controls.

The real site changed its English composer so the send arrow no longer carries
``data-testid="send-button"``. This harness runs the shipped
``shared/web-driver.js`` in a plain English-layout page, using the selectors
from ``shared/provider-web-configs.js`` exactly as the worker would.

Checks
------
1. Exact ``button[aria-label="Send"]`` is recognised, while a visible voice
   control, attachment control, edit control, stop control and an unlabelled
   arrow button are not treated as send.
2. The page receives exactly one submission; a repeated submit for the same
   task never clicks again, and the driver never dispatches Enter.
3. Waiting text that the site shows before the user turn is not accepted as a
   sent message: the driver reports ``submit-unconfirmed`` and read stays
   pending, never ``done``.
4. With no known marker at all the driver fails closed with ``send-pending``
   (pre-click) instead of guessing an arrow or pressing Enter.
5. Exact ``button[aria-label="Stop"]`` still matches the stop control.

Run from the repository root:

    python3 tests/chatgpt_english_controls.py

It writes nothing outside a temp directory and touches no real site.
"""

from __future__ import annotations

import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixtures import find_chromium_executable  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "shared" / "web-driver.js"

# The shipped adapter is the source of truth, not a copied selector list.
ADAPTER = json.loads(
    subprocess.run(
        [
            "node",
            "--input-type=module",
            "-e",
            (
                "import { webSiteConfig } from './shared/provider-web-configs.js';"
                "const c = webSiteConfig('chatgpt');"
                "process.stdout.write(JSON.stringify({"
                "selectors: c.selectors, options: c.options, allowNavigation: c.allowNavigation"
                "}));"
            ),
        ],
        cwd=str(ROOT),
        check=True,
        capture_output=True,
        text=True,
    ).stdout
)

PROMPT = "请比较“先验证再扩展”和“先扩展再验证”，并说明你的立场。"
ANSWER = "ENGLISH_FIXTURE_ANSWER：先验证再扩展。"

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #editor { display:block; width:640px; min-height:28px; border:1px solid #999; }
  #log [data-content-search-unit-key$=":user"],
  #log [data-response-body] { display:block; white-space:pre-wrap; }
  button { display:inline-block; margin:4px; }
</style>
<div id="editor" class="ProseMirror" role="textbox" contenteditable="true"></div>
<button id="voice" aria-label="Start voice mode">voice</button>
<button id="attach" aria-label="Attach files">attach</button>
<button id="edit" aria-label="Edit message">edit</button>
<button id="arrow"><svg width="10" height="10"></svg></button>
<button id="stop" aria-label="Stop">stop</button>
<button id="send" aria-label="Send"><svg width="10" height="10"></svg></button>
<div id="log"></div>
<script>
(function () {
  'use strict';
  const cfg = Object.assign(
    { mode: 'normal', sendLabel: 'Send', stopVisible: true },
    window.__FIXTURE__ || {},
  );
  const editor = document.getElementById('editor');
  const send = document.getElementById('send');
  const stop = document.getElementById('stop');
  const log = document.getElementById('log');

  if (cfg.sendLabel) send.setAttribute('aria-label', cfg.sendLabel);
  else send.removeAttribute('aria-label');
  stop.style.display = cfg.stopVisible ? '' : 'none';

  window.clicks = 0;
  window.keydowns = 0;
  window.submits = [];
  window.lastClickId = '';
  window.turns = [];

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') window.keydowns += 1;
  }, true);

  function putUser(prompt) {
    const user = document.createElement('article');
    user.setAttribute('data-content-search-unit-key', 'turn:user');
    const text = document.createElement('div');
    text.className = 'text';
    text.textContent = prompt;
    user.append(text);
    log.append(user);
  }

  function putAnswer() {
    const answer = document.createElement('article');
    const body = document.createElement('div');
    body.setAttribute('data-response-body', '');
    body.textContent = __ANSWER_VALUE__;
    const copy = document.createElement('button');
    copy.setAttribute('data-testid', 'copy-turn-action-button');
    copy.setAttribute('aria-label', 'Copy');
    answer.append(body, copy);
    log.append(answer);
  }

  send.addEventListener('click', () => {
    window.clicks += 1;
    window.lastClickId = 'send';
    const prompt = editor.innerText || editor.textContent || '';
    window.submits.push(prompt);
    if (cfg.mode === 'waiting') {
      // The site is still queueing. This text is visible, but no user turn
      // exists yet, so it must not count as sent.
      const waiting = document.createElement('div');
      waiting.className = 'waiting';
      waiting.textContent = prompt;
      log.append(waiting);
      return;
    }
    editor.replaceChildren();
    stop.style.display = 'none';
    putUser(prompt);
    putAnswer();
    window.turns.push(prompt);
  });
})();
</script>""".replace("__ANSWER_VALUE__", json.dumps(ANSWER, ensure_ascii=False))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(PAGE.encode("utf-8"))

    def log_message(self, *_):
        pass


FAST_OPTIONS = {
    "sampleMs": 50,
    "stableSamples": 2,
    "stableMs": 100,
    "submitTimeoutMs": 1500,
    "sendEnableMs": 800,
    "pollMs": 50,
    "turnGraceMs": 0,
}


def handle(page, payload):
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def payload(base, task_id, prompt, options=None):
    return {
        "type": "arena.web.submit",
        "taskId": task_id,
        "prompt": prompt,
        "selectors": ADAPTER["selectors"],
        "options": options or FAST_OPTIONS,
        "scope": {
            "origin": base,
            "homeHref": base + "/",
            "allowNavigation": ADAPTER["allowNavigation"],
        },
    }


def probe(page, base):
    return handle(
        page,
        {
            "type": "arena.web.probe",
            "taskId": "probe-" + str(page.evaluate("Math.random()")).replace(".", ""),
            "selectors": ADAPTER["selectors"],
            "scope": {"origin": base, "allowNavigation": ADAPTER["allowNavigation"]},
        },
    )


def read(page, base, task_id):
    return handle(
        page,
        {
            "type": "arena.web.read",
            "taskId": task_id,
            "selectors": ADAPTER["selectors"],
            "options": FAST_OPTIONS,
            "scope": {"origin": base, "allowNavigation": ADAPTER["allowNavigation"]},
        },
    )


def new_page(ctx, base, fixture):
    page = ctx.new_page()
    page.add_init_script("window.__FIXTURE__ = " + json.dumps(fixture, ensure_ascii=False))
    page.goto(base + "/")
    page.add_script_tag(path=str(DRIVER))
    return page


def matches(page, selector, element_id):
    return page.evaluate(
        "([selector, id]) => {"
        "  const el = document.getElementById(id);"
        "  try { return !!el && el.matches(selector); } catch (e) { return false; }"
        "}",
        [selector, element_id],
    )


def any_send_candidate_matches(page, element_id):
    return any(matches(page, selector, element_id) for selector in ADAPTER["selectors"]["send"])


def any_stop_candidate_matches(page, element_id):
    return any(matches(page, selector, element_id) for selector in ADAPTER["selectors"]["stop"])


def main() -> int:
    assert ADAPTER["selectors"]["send"], ADAPTER
    assert ADAPTER["selectors"]["stop"], ADAPTER

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    results: dict[str, bool] = {}

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                executable_path=str(find_chromium_executable()),
            )
            ctx = browser.new_context()

            # 1) English layout: only the exact send control may be clicked.
            page = new_page(ctx, base, {"mode": "normal"})
            ready = probe(page, base)
            assert ready["status"] == "ready", ready
            assert any_send_candidate_matches(page, "send"), ADAPTER["selectors"]["send"]
            for decoy in ("voice", "attach", "edit", "arrow", "stop"):
                assert not any_send_candidate_matches(page, decoy), (decoy, ADAPTER["selectors"]["send"])
            assert any_stop_candidate_matches(page, "stop"), ADAPTER["selectors"]["stop"]
            results["send_ignores_voice_stop_attach_edit_and_arrow"] = True

            first = handle(page, payload(base, "t-en", PROMPT))
            assert first["status"] == "submitted", first
            assert first["detail"]["userTurnVerified"] is True, first
            assert page.evaluate("window.clicks") == 1
            assert page.evaluate("window.lastClickId") == "send"
            assert page.evaluate("window.submits") == [PROMPT]
            assert page.evaluate("window.keydowns") == 0
            assert page.evaluate("window.turns") == [PROMPT]
            results["english_send_delivered_exactly_once"] = True

            # A retry for the same task must never click again.
            repeat = handle(page, payload(base, "t-en", PROMPT))
            assert repeat["status"] in ("submitted", "pending", "done"), repeat
            assert page.evaluate("window.clicks") == 1
            results["repeat_submit_does_not_resend"] = True

            answer = None
            for _ in range(20):
                candidate = read(page, base, "t-en")
                if candidate["status"] == "done":
                    answer = candidate
                    break
                page.wait_for_timeout(100)
            assert answer is not None, "English layout answer never completed"
            assert ANSWER in answer["text"], answer
            results["english_answer_read_back"] = True
            page.close()

            # 2) Waiting text without a user turn is not a sent message.
            page = new_page(ctx, base, {"mode": "waiting", "stopVisible": False})
            waiting = handle(page, payload(base, "t-wait", PROMPT, {**FAST_OPTIONS, "submitTimeoutMs": 1200}))
            assert waiting["status"] == "error" and waiting["error"] == "submit-unconfirmed", waiting
            assert waiting["detail"]["possiblySubmitted"] is True, waiting
            assert page.evaluate("window.clicks") == 1
            assert page.evaluate("window.keydowns") == 0
            after = read(page, base, "t-wait")
            assert after["status"] == "pending", after
            assert after["detail"]["userTurnVerified"] is False, after
            assert "text" not in after, after
            results["waiting_text_is_not_sent"] = True
            page.close()

            # 3) No known marker: fail closed, never guess the arrow or Enter.
            page = new_page(ctx, base, {"mode": "normal", "sendLabel": None, "stopVisible": False})
            ready = probe(page, base)
            assert ready["status"] == "ready", ready
            missing = handle(page, payload(base, "t-missing", PROMPT, {**FAST_OPTIONS, "sendEnableMs": 500}))
            assert missing["status"] == "error" and missing["error"] == "send-pending", missing
            assert missing["detail"]["phase"] == "pre-click", missing
            assert missing["detail"]["clickAttempted"] is False, missing
            assert missing["detail"]["reason"] == "missing", missing
            assert page.evaluate("window.clicks") == 0
            assert page.evaluate("window.keydowns") == 0
            assert page.evaluate("document.querySelector('#editor').innerText") == PROMPT
            results["missing_marker_fails_closed"] = True
            page.close()

            browser.close()
            print(json.dumps(results, ensure_ascii=False, indent=2))
    finally:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
