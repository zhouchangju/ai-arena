#!/usr/bin/env python3
"""Loopback fault-injection for the two G1/G3 recovery paths.

This harness runs the real ``shared/web-driver.js`` in a plain page (no
extension installs, no network) and simulates:

1. A brand-new conversation whose empty composer was restored by the site with
   the exact prompt Arena last confirmed sending. Only a precomputed SHA-256 of
   that exact old prompt may replace it; a different human draft must never be
   replaced, and neither case is allowed off the new-conversation home page or
   above a non-empty message baseline.
2. A send control that is hidden for several seconds. Before any click the
   driver returns ``send-pending`` with ``clickAttempted:false`` and the caller
   can safely retry. After a click, even an unchanged composer is reported as
   ``submit-unconfirmed`` and a repeat submit must not click again.

Run from the repository root:

    python3 tests/web_driver_recovery.py

Exit code 0 means all checks passed. It writes nothing outside a temp dir.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixtures import find_chromium_executable  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "shared" / "web-driver.js"

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #editor { display:block; width:640px; min-height:28px; border:1px solid #999; }
  #send { display:block; margin:8px 0; }
  #log .turn.user .msg, #log .turn.answer .msg { display:block; white-space:pre-wrap; }
</style>
<div id="editor" class="ProseMirror" contenteditable="true"></div>
<button id="send" data-testid="send-button">发送</button>
<div id="log"></div>
<script>
(function () {
  'use strict';
  const cfg = Object.assign({ prefill: '', hiddenMs: 0, ignoreClicks: false, existing: false }, window.__FIXTURE__ || {});
  const editor = document.getElementById('editor');
  const send = document.getElementById('send');
  const log = document.getElementById('log');
  let clicks = 0;
  window.clicks = 0;
  window.turns = [];

  function put(html) {
    log.insertAdjacentHTML('beforeend', html);
    return log.lastElementChild;
  }

  if (cfg.existing) {
    put('<div class="turn user"><span class="msg"></span></div>').querySelector('.msg').textContent = '上一轮用户消息';
    put('<div class="turn answer"><span class="msg">上一轮回答</span><span class="done">完成</span></div>');
  }
  if (cfg.prefill) editor.innerText = cfg.prefill;
  if (cfg.hiddenMs > 0) {
    send.style.display = 'none';
    setTimeout(() => { send.style.display = ''; }, cfg.hiddenMs);
  }

  send.addEventListener('click', () => {
    clicks += 1;
    window.clicks = clicks;
    if (cfg.ignoreClicks) return;
    const prompt = editor.innerText || editor.textContent || '';
    if (!prompt.trim()) return;
    editor.replaceChildren();
    const user = put('<div class="turn user"><span class="msg"></span></div>');
    user.querySelector('.msg').textContent = prompt;
    const answer = put('<div class="turn answer"><span class="msg"></span><span class="done">完成</span></div>');
    answer.querySelector('.msg').textContent = '回环夹具回答：' + clicks;
    window.turns.push({ prompt: prompt, text: answer.querySelector('.msg').textContent });
  });
})();
</script>"""


def collapse(value: str) -> str:
    text = str(value or "")
    text = text.replace("\u00a0", " ")
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"[ \t]+$", "", text, flags=re.M)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"^\s+|\s+$", "", text)
    text = re.sub(r"[\u200b-\u200d\ufeff]", "", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def digest(value: str) -> str:
    return hashlib.sha256(collapse(value).encode("utf-8")).hexdigest()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(PAGE.encode("utf-8"))

    def log_message(self, *_):
        pass


def handle(page, payload):
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def new_page(ctx, base, fixture):
    page = ctx.new_page()
    page.add_init_script("window.__FIXTURE__ = " + json.dumps(fixture, ensure_ascii=False))
    page.goto(base + "/")
    page.add_script_tag(path=str(DRIVER))
    return page


def selectors():
    return {
        "input": "#editor",
        "send": "#send",
        "user": "#log .turn.user .msg",
        "answer": "#log .turn.answer .msg",
        "done": "#log .turn.answer .done",
    }


def submit(page, base, task_id, prompt, known, options=None, home="/"):
    return handle(
        page,
        {
            "type": "arena.web.submit",
            "taskId": task_id,
            "prompt": prompt,
            "knownDraftDigests": known,
            "selectors": selectors(),
            "options": options or {},
            "scope": {"origin": base, "homeHref": base + home, "allowNavigation": False},
        },
    )


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    old = "旧提示：请比较“先发一版再迭代”和“先做完再发布”。\n\n并说明你的立场。"
    new = "本轮新提示：请比较“先验证再扩展”和“先扩展再验证”。"
    human = "这是我自己写的草稿，和旧提示不同，绝不能覆盖。"

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                executable_path=str(find_chromium_executable()),
            )
            ctx = browser.new_context()
            results = {}

            # 1) exact old prompt on a blank new-conversation home is replaced
            page = new_page(ctx, base, {"prefill": old})
            reply = submit(page, base, "t-replace", new, [digest(old)])
            assert reply["status"] == "submitted", reply
            assert reply["detail"]["draftReplaced"] == "known-old-prompt", reply
            assert page.evaluate("window.turns.length") == 1
            assert page.evaluate("window.turns[0].prompt") == new
            assert page.evaluate("document.querySelector('#editor').innerText") == ""
            results["known_old_prompt_replaced"] = True
            page.close()

            # 2) a different human draft is never replaced
            page = new_page(ctx, base, {"prefill": human})
            reply = submit(page, base, "t-human", new, [digest(old)])
            assert reply["status"] == "error" and reply["error"] == "draft-conflict", reply
            assert page.evaluate("document.querySelector('#editor').innerText") == human
            assert page.evaluate("window.turns.length") == 0
            results["human_draft_kept"] = True
            page.close()

            # 3) off the new-conversation home page the same digest is refused
            page = new_page(ctx, base, {"prefill": old})
            page.goto(base + "/chat")
            page.add_script_tag(path=str(DRIVER))
            reply = submit(page, base, "t-offhome", new, [digest(old)], home="/")
            assert reply["status"] == "error" and reply["error"] == "draft-conflict", reply
            assert page.evaluate("document.querySelector('#editor').innerText") == old
            results["off_home_refused"] = True
            page.close()

            # 4) a non-empty message baseline is refused even on the home page
            page = new_page(ctx, base, {"prefill": old, "existing": True})
            reply = submit(page, base, "t-baseline", new, [digest(old)])
            assert reply["status"] == "error" and reply["error"] == "draft-conflict", reply
            assert page.evaluate("window.turns.length") == 0
            results["nonempty_baseline_refused"] = True
            page.close()

            # 5) hidden send control: explicit pre-click failure, then safe retry
            page = new_page(ctx, base, {"hiddenMs": 1500})
            first = submit(page, base, "t-hidden", new, [], {"sendEnableMs": 400, "submitTimeoutMs": 2000})
            assert first["status"] == "error" and first["error"] == "send-pending", first
            detail = first["detail"]
            assert detail["phase"] == "pre-click", detail
            assert detail["clickAttempted"] is False, detail
            assert detail["reason"] == "hidden", detail
            assert page.evaluate("window.clicks") == 0
            assert page.evaluate("window.turns.length") == 0
            page.wait_for_timeout(1300)
            second = submit(page, base, "t-hidden", new, [], {"sendEnableMs": 2000, "submitTimeoutMs": 3000})
            assert second["status"] == "submitted", second
            assert page.evaluate("window.clicks") == 1
            assert page.evaluate("window.turns.length") == 1
            results["pre_click_retry"] = True
            page.close()

            # 6) after a click nobody can prove it was ignored: never click again
            page = new_page(ctx, base, {"ignoreClicks": True})
            first = submit(
                page,
                base,
                "t-clicked",
                new,
                [],
                {"sendEnableMs": 1000, "submitTimeoutMs": 700, "pollMs": 100, "turnGraceMs": 0},
            )
            assert first["status"] == "error" and first["error"] == "submit-unconfirmed", first
            assert first["detail"]["possiblySubmitted"] is True, first
            assert first["detail"]["clickAttempted"] is True, first
            assert page.evaluate("window.clicks") == 1
            again = submit(
                page,
                base,
                "t-clicked",
                new,
                [],
                {"sendEnableMs": 1000, "submitTimeoutMs": 700, "pollMs": 100, "turnGraceMs": 0},
            )
            assert again["status"] in ("pending", "unknown"), again
            assert again.get("detail", {}).get("userTurnVerified") is not True, again
            assert page.evaluate("window.clicks") == 1, again
            assert page.evaluate("window.turns.length") == 0
            results["post_click_not_retried"] = True
            page.close()

            # Native panes can navigate within one host. A route change between
            # filling the composer and clicking send must leave both chats untouched.
            page = new_page(ctx, base, {"hiddenMs": 900})
            page.evaluate("""() => document.querySelector('#editor').addEventListener(
                'input', () => history.replaceState(null, '', '/different-chat'), {once: true})""")
            reply = handle(page, {
                "type": "arena.web.submit", "taskId": "t-switched-chat", "prompt": new,
                "selectors": selectors(), "scope": {"origin": base, "href": base + "/"},
            })
            assert reply["status"] == "error", reply
            assert reply["detail"]["clickAttempted"] is False, reply
            assert page.evaluate("window.clicks") == 0
            results["same_origin_switch_stopped_before_click"] = True
            page.close()

            page = new_page(ctx, base, {"ignoreClicks": True})
            page.evaluate("""() => document.querySelector('#send').addEventListener('click', () => {
                for (let i=0; i<2; i++) {
                    const stop=document.createElement('button');
                    stop.className='stop'; stop.textContent='Stop'; document.body.append(stop);
                }
            })""")
            reply = handle(page, {
                "type": "arena.web.submit", "taskId": "t-after-click", "prompt": new,
                "selectors": {**selectors(), "stop": ".stop"}, "scope": {"origin": base},
            })
            assert reply["error"] == "submit-unconfirmed" and reply["detail"]["clickAttempted"] is True, reply
            assert page.evaluate("window.clicks") == 1
            results["ambiguous_post_click_is_read_only"] = True
            page.close()

            browser.close()
            print(json.dumps(results, ensure_ascii=False, indent=2))
    finally:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
