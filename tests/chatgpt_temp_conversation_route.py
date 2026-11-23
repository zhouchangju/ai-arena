#!/usr/bin/env python3
"""Reproduce ChatGPT's temporary conversation route on the real web driver.

G1/G3. A real ChatGPT first answer was observed at

    https://chatgpt.com/c/local-chatgpt:<uuid>

and the site only later swapped in a stable ``/c/<id>``. The old native gate
treated any two-segment ``/c/...`` path as a conversation and fixed the
temporary frontend ID, so the next read was rejected as
``conversation-changed``.

This harness runs the unchanged ``shared/web-driver.js`` in a plain page
whose requests are answered by Playwright routes: no network, no account.
It covers the route chain the native pane depends on:

A. Home -> temporary ``/c/local-chatgpt:<uuid>``:
   submit verifies this round's exact user message and reports that href.
B. A read while still on the temporary route verifies the turn there (the
   page already showed the user), but the temporary route is never a
   persisted binding or a recovery destination.
C. Temporary -> stable ``/c/<id>``:
   the next read re-confirms exactly one matching user turn *on that page*
   and only then returns the answer, with the stable href. No resend.
D. A temporary ``scope.href`` (plain or percent-encoded) is rejected as an
   invalid recovery destination instead of being treated as the conversation.
E. A stable page with two copies of this round's question is ambiguous: the
   read stays ``unknown`` and never returns either answer as the result.

Run from the repository root:

    python3 tests/chatgpt_temp_conversation_route.py

Exit code 0 means all checks passed (one JSON summary on stdout).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixtures import find_chromium_executable  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "shared" / "web-driver.js"

ORIGIN = "https://chatgpt.com"
HOME = ORIGIN + "/"
TEMP_ID = "local-chatgpt:6f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8"
STABLE_ID = "00000000-0000-4000-8000-000000000137"
TEMP_HREF = ORIGIN + "/c/" + TEMP_ID
ENCODED_TEMP_HREF = ORIGIN + "/c/" + TEMP_ID.replace(":", "%3A")
STABLE_HREF = ORIGIN + "/c/" + STABLE_ID
PROMPT = "本轮独立作答：如果手机端采集只出现过一次中断，应该先扩展还是先验证？请给出可执行顺序。"
ANSWER = "回环回答：先做一周小样本验证，再按结果决定扩展；若复现中断则先修手机端。"

SELECTORS = {
    "input": "#prompt-textarea",
    "send": "#send",
    "user": '#log article[data-message-author-role="user"]',
    "answer": '#log article[data-message-author-role="assistant"] [data-response-body]',
    "done": '#log article[data-message-author-role="assistant"] button[data-testid="copy-turn-action-button"]',
}

OPTIONS = {
    "sampleMs": 40,
    "stableSamples": 2,
    "stableMs": 80,
    "submitTimeoutMs": 3000,
    "sendEnableMs": 800,
    "pollMs": 40,
    "turnGraceMs": 0,
}

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #prompt-textarea { display:block; width:720px; min-height:32px; border:1px solid #999; }
  #send { display:block; margin:8px 0; }
  #log article { display:block; margin:4px 0; }
</style>
<div id="prompt-textarea" class="ProseMirror" contenteditable="true"></div>
<button id="send" data-testid="send-button" aria-label="Send">发送</button>
<div id="log"></div>
<script>
(function () {
  'use strict';
  const cfg = Object.assign({
    tempId: __TEMP_ID__,
    stableId: __STABLE_ID__,
    stableAfterMs: 1800,
    duplicate: false,
  }, window.__FIXTURE__ || {});
  const editor = document.getElementById('prompt-textarea');
  const send = document.getElementById('send');
  const log = document.getElementById('log');
  window.sends = 0;
  window.routes = [];

  function addUser(text) {
    const node = document.createElement('article');
    node.setAttribute('data-message-author-role', 'user');
    const body = document.createElement('div');
    body.className = 'whitespace-pre-wrap';
    body.textContent = text;
    node.appendChild(body);
    log.appendChild(node);
    return node;
  }

  function addAnswer(text) {
    const node = document.createElement('article');
    node.setAttribute('data-message-author-role', 'assistant');
    const body = document.createElement('div');
    body.setAttribute('data-response-body', '');
    body.className = 'markdown';
    body.textContent = text;
    node.appendChild(body);
    const done = document.createElement('button');
    done.setAttribute('data-testid', 'copy-turn-action-button');
    done.textContent = '复制';
    node.appendChild(done);
    log.appendChild(node);
    return node;
  }

  send.addEventListener('click', () => {
    const prompt = editor.innerText || editor.textContent || '';
    if (!prompt.trim()) return;
    window.sends += 1;
    editor.replaceChildren();
    addUser(prompt);
    addAnswer(__ANSWER__);

    // The site paints the temporary frontend route first.
    history.pushState({}, '', '/c/' + cfg.tempId);
    window.routes.push(location.pathname);

    setTimeout(() => {
      history.pushState({}, '', '/c/' + cfg.stableId);
      window.routes.push(location.pathname);
      window.stableAt = Date.now();
      if (cfg.duplicate) {
        // Simulate a duplicate rendering of the same question on the stable
        // page: a read must not pick the last one arbitrarily.
        setTimeout(() => addUser(prompt), 120);
      }
    }, cfg.stableAfterMs);
  });
})();
</script>"""


def fixture_page(duplicate: bool, stable_after_ms: int) -> bytes:
    body = (
        PAGE.replace("__TEMP_ID__", json.dumps(TEMP_ID))
        .replace("__STABLE_ID__", json.dumps(STABLE_ID))
        .replace("__ANSWER__", json.dumps(ANSWER, ensure_ascii=False))
        .replace("stableAfterMs: 1800", f"stableAfterMs: {stable_after_ms}")
        .replace("duplicate: false", f"duplicate: {'true' if duplicate else 'false'}")
    )
    return body.encode("utf-8")


def new_page(browser, duplicate: bool = False, stable_after_ms: int = 1800):
    ctx = browser.new_context()
    html = fixture_page(duplicate, stable_after_ms)
    ctx.route(
        "**/*",
        lambda route: route.fulfill(
            status=200,
            headers={"content-type": "text/html; charset=utf-8"},
            body=html,
        ),
    )
    page = ctx.new_page()
    page.goto(HOME)
    page.add_script_tag(path=str(DRIVER))
    return ctx, page


def handle(page, payload):
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def message(kind: str, task_id: str, prompt: str | None = None, href: str | None = None):
    scope = {
        "origin": ORIGIN,
        "hrefPrefix": ORIGIN + "/",
        "homeHref": HOME,
        "allowNavigation": True,
    }
    if href is not None:
        scope["href"] = href
    payload = {
        "type": kind,
        "taskId": task_id,
        "selectors": SELECTORS,
        "options": OPTIONS,
        "scope": scope,
    }
    if prompt is not None:
        payload["prompt"] = prompt
    return payload


def submit(page, task_id: str, href: str | None = HOME):
    return handle(page, message("arena.web.submit", task_id, PROMPT, href))


def read(page, task_id: str, href: str | None = None):
    return handle(page, message("arena.web.read", task_id, None, href))


def wait_for_stable(page):
    page.wait_for_function(
        "(id) => location.pathname === '/c/' + id",
        arg=STABLE_ID,
        timeout=6000,
    )


def reads_until_done(page, task_id: str, seconds: float = 3.0):
    deadline = seconds
    seen = []
    while deadline > 0:
        reply = read(page, task_id)
        seen.append(reply.get("status"))
        if reply.get("status") == "done":
            reply["_seen"] = seen
            return reply
        page.wait_for_timeout(80)
        deadline -= 0.08
    return {"_seen": seen, "status": "timeout"}


def main() -> int:
    results: dict[str, bool] = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            executable_path=str(find_chromium_executable()),
        )
        try:
            # A-C: home -> temporary -> stable, with a read on each hop.
            ctx, page = new_page(browser, duplicate=False)
            task_id = "round1.seatA"
            first = submit(page, task_id)
            assert first["status"] == "submitted", first
            assert first["detail"]["userTurnVerified"] is True, first
            assert first["detail"]["href"].endswith("/c/" + TEMP_ID), first
            assert page.evaluate("window.sends") == 1
            assert page.evaluate("window.routes")[0] == "/c/" + TEMP_ID
            results["submit_reports_temporary_frontend_route"] = True

            temp_read = read(page, task_id)
            assert temp_read["status"] in ("pending", "done"), temp_read
            assert temp_read.get("detail", {}).get("userTurnVerified") is True, temp_read
            assert temp_read["detail"]["href"].endswith("/c/" + TEMP_ID), temp_read
            assert page.evaluate("window.sends") == 1
            results["temporary_route_can_show_this_round_user"] = True

            wait_for_stable(page)
            stable_read = reads_until_done(page, task_id)
            assert stable_read["status"] == "done", stable_read
            assert stable_read["text"] == ANSWER, stable_read
            assert stable_read["detail"]["userTurnVerified"] is True, stable_read
            assert stable_read["detail"]["href"] == STABLE_HREF, stable_read
            assert stable_read["detail"]["navigation"]["to"] == STABLE_HREF, stable_read
            assert stable_read["detail"]["navigation"]["from"] == TEMP_HREF, stable_read
            assert page.evaluate("window.sends") == 1, "the route chain never re-sends"
            results["stable_page_reconfirms_unique_turn_then_returns_answer"] = True

            # D: an old temporary binding is never a recovery destination.
            for href in (TEMP_HREF, ENCODED_TEMP_HREF):
                refused = read(page, task_id, href)
                assert refused["status"] == "error", refused
                assert refused["error"] == "bad-message", refused
                assert refused["detail"]["field"] == "scope", refused
                assert refused["detail"]["reason"] == "href-temporary", refused
            assert page.evaluate("window.sends") == 1
            results["temporary_scope_href_is_refused"] = True
            page.close()
            ctx.close()

            # E: duplicate question on the stable page is ambiguous, not answered.
            ctx, page = new_page(browser, duplicate=True, stable_after_ms=300)
            task_id = "round1.seatA"
            first = submit(page, task_id)
            assert first["status"] == "submitted", first
            wait_for_stable(page)
            page.wait_for_function(
                "() => document.querySelectorAll('#log article[data-message-author-role=\"user\"]').length === 2",
                timeout=3000,
            )
            ambiguous = read(page, task_id)
            assert ambiguous["status"] == "unknown", ambiguous
            assert ambiguous["error"] == "page-changed", ambiguous
            assert ambiguous["detail"]["reason"] == "spa-navigation-unverified", ambiguous
            assert "text" not in ambiguous, ambiguous
            assert page.evaluate("window.sends") == 1
            results["duplicate_question_is_ambiguous_not_last_answer"] = True
            page.close()
            ctx.close()

            for timing in ("before-fill", "during-fill"):
                ctx, page = new_page(browser)
                page.evaluate("""timing => {
                    const seed = () => {
                        document.querySelector('#log').insertAdjacentHTML(
                            'beforeend', '<article data-message-author-role="user">已有私人对话</article>'
                        );
                    };
                    if (timing === 'before-fill') seed();
                    else document.querySelector('#prompt-textarea').addEventListener('input', seed, {once: true});
                }""", timing)
                judge = message("arena.web.submit", "evaluation:r1:independent:chatgpt", PROMPT, HOME)
                judge["freshConversationOnly"] = True
                refused = handle(page, judge)
                assert refused["error"] == "fresh-conversation-required", refused
                assert page.evaluate("window.sends") == 0
                results[f"judge_refuses_existing_history_{timing}"] = True
                ctx.close()
        finally:
            browser.close()

    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
