#!/usr/bin/env python3
"""Read-only record rebuild and native "Show more" suffix checks (G1/G3).

Runs the shipped ``extension/web-driver.js`` unchanged against loopback HTML
served for the three registered conversation addresses. Every request is
answered by a Playwright route, so no real site is contacted and no account is
used.

The reproducers are the two real failures:

1. ChatGPT's latest user message renders its full text followed by the native
   expander suffix ``" … Show more"`` (or ``" Show less"``). The driver must
   strip *only* that UI suffix and prove the round by full equality; a rendered
   prefix is never accepted as the full message.
2. A read-only ``read`` may carry ``verifiedReadPrompt`` after the app was
   reopened or the driver lost its in-memory record. Rebuilding is allowed only
   on a trusted, stable, bound conversation (non-home, non-temporary), with a
   unique latest user node equal to the prompt, the answer strictly after it,
   and a live completion signal. A submit afterwards never clicks.

Checks
------
Positive (zero sends, zero extra clicks):
  A. ChatGPT full text + " … Show more" with the unique native control -> done.
  B. ChatGPT expanded render + " Show less" -> done.
  C. ChatGPT without any expand control -> done.
  D. DeepSeek /a/chat/s/<id> rebuild -> done.
  E. Gemini /app/<id> rebuild with the native finished control -> done.
  F. Rebuilt task receives a repeated submit: still zero clicks.
  G. An existing record whose messages are temporarily unmounted stays
     pending (read-recovery-pending), then finishes after remount.

Negative (never done, never a send):
  H. Prefix-only render + " … Show more" (control does nothing) -> pending.
  I. Latest user node differs from the prompt -> pending.
  J. Duplicate user nodes equal to the prompt -> pending.
  K. The only answer sits before this round's user node -> pending.
  L. Only an older answer carries the completion control -> pending.
  M. No scope.href (unbound page) -> unknown/task-unknown.
  N. Home path as scope.href -> unknown/task-unknown.
  O. ChatGPT temporary route -> refused before rebuild.
  P. scope.href of another conversation -> conversation-changed.
  Q. Same task id with a different prompt -> task-prompt-mismatch.

Run from the repository root:

    python3 tests/web_driver_read_rebuild.py

Exit code 0 means every check passed; one JSON summary is printed.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from browser_acceptance import find_chromium_executable  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "extension" / "web-driver.js"

ADAPTERS = json.loads(
    subprocess.run(
        [
            "node",
            "--input-type=module",
            "-e",
            (
                "import { webSiteConfig } from './extension/provider-web-configs.js';"
                "const out = {};"
                "for (const id of ['chatgpt','gemini','deepseek']) {"
                "  const c = webSiteConfig(id);"
                "  out[id] = { selectors: c.selectors, options: c.options,"
                "              allowNavigation: c.allowNavigation, origin: c.origin, url: c.url };"
                "}"
                "process.stdout.write(JSON.stringify(out));"
            ),
        ],
        cwd=str(ROOT),
        check=True,
        capture_output=True,
        text=True,
    ).stdout
)

CHATGPT_ORIGIN = "https://chatgpt.com"
CHATGPT_HOME = CHATGPT_ORIGIN + "/"
CHATGPT_CONVERSATION = CHATGPT_ORIGIN + "/c/00000000-0000-4000-8000-000000000137"
CHATGPT_OTHER = CHATGPT_ORIGIN + "/c/00000000-0000-4000-8000-000000000138"
CHATGPT_TEMP = CHATGPT_ORIGIN + "/c/local-chatgpt%3A6f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8"

DEEPSEEK_ORIGIN = "https://chat.deepseek.com"
DEEPSEEK_HOME = DEEPSEEK_ORIGIN + "/"
DEEPSEEK_CONVERSATION = DEEPSEEK_ORIGIN + "/a/chat/s/00000000-0000-4000-8000-000000000139"

GEMINI_ORIGIN = "https://gemini.google.com"
GEMINI_HOME = GEMINI_ORIGIN + "/app"
GEMINI_CONVERSATION = GEMINI_ORIGIN + "/app/abc123def456"

PROMPT_BASE = "互评：请比较“先验证再扩展”和“先扩展再验证”，说明条件与反例。"
# Mirror the real 5168-character critique round so the suffix/equality path is
# exercised at the same size as the site observation.
PROMPT = PROMPT_BASE + ("长" * (5168 - len(PROMPT_BASE)))
OLD_USER = "首轮：请给出你的独立判断。"
OLD_ANSWER = "首轮回答：先验证再扩展，并给出一个小样本窗口。"
NEW_ANSWER = "互评回答：验证可以并行，但必须先锁一个可证伪指标。"
BEFORE_ANSWER = "更早的回答：这一节点排在本轮用户消息之前。"

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #prompt-textarea { display:block; width:720px; min-height:32px; border:1px solid #999; }
  #send { display:block; margin:6px 0; }
  #log > * { display:block; margin:4px 0; }
  user-query, model-response { display:block; margin:4px 0; }
</style>
<div id="prompt-textarea" class="ProseMirror" contenteditable="true"></div>
<button id="send" data-testid="send-button">发送</button>
<div id="log"></div>
<script>
(function () {
  'use strict';
  const cfg = Object.assign({
    provider: 'chatgpt', turns: [], answerOnSend: true,
    answerText: '', answerDone: true,
  }, window.__FIXTURE__ || {});
  const log = document.getElementById('log');
  const editor = document.getElementById('prompt-textarea');
  window.sends = 0;
  window.expandClicks = 0;

  function makeUser(item) {
    if (cfg.provider === 'gemini') {
      const query = document.createElement('user-query');
      const line = document.createElement('div');
      line.className = 'query-text-line';
      line.textContent = item.user;
      query.append(line);
      return query;
    }
    if (cfg.provider === 'deepseek') {
      const message = document.createElement('div');
      message.className = 'ds-message';
      const text = document.createElement('div');
      text.textContent = item.user;
      message.append(text);
      return message;
    }
    const article = document.createElement('article');
    article.setAttribute('data-content-search-unit-key', 'turn:user');
    const body = document.createElement('div');
    body.className = 'whitespace-pre-wrap';
    body.textContent = item.user;
    article.append(body);
    if (item.expand) {
      const control = document.createElement('button');
      control.type = 'button';
      control.textContent = item.expand;
      control.addEventListener('click', () => { window.expandClicks += 1; });
      article.append(control);
    }
    return article;
  }

  function makeAnswer(item) {
    if (cfg.provider === 'gemini') {
      const response = document.createElement('model-response');
      const body = document.createElement('message-content');
      body.textContent = item.answer;
      response.append(body);
      if (item.done) {
        const control = document.createElement('gem-icon-button');
        control.setAttribute('data-test-id', 'regenerate-button');
        control.textContent = '↻';
        response.append(control);
      }
      return response;
    }
    if (cfg.provider === 'deepseek') {
      const message = document.createElement('div');
      message.className = 'ds-message';
      const body = document.createElement('div');
      body.className = 'ds-assistant-message-main-content';
      body.textContent = item.answer;
      message.append(body);
      if (item.done) {
        const row = document.createElement('div');
        row.className = 'ds-flex';
        const control = document.createElement('button');
        control.setAttribute('aria-label', '朗读');
        control.textContent = '♪';
        row.append(control);
        message.append(row);
      }
      return message;
    }
    const article = document.createElement('article');
    const body = document.createElement('div');
    body.setAttribute('data-response-body', '');
    body.textContent = item.answer;
    article.append(body);
    if (item.done) {
      const control = document.createElement('button');
      control.setAttribute('data-testid', 'copy-turn-action-button');
      control.textContent = '复制';
      article.append(control);
    }
    return article;
  }

  function render() {
    log.replaceChildren();
    cfg.turns.forEach((item) => {
      if (item.user !== undefined && item.user !== null) log.append(makeUser(item));
      if (item.answer !== undefined && item.answer !== null) log.append(makeAnswer(item));
    });
  }

  window.mountFixture = render;
  window.unmountFixture = () => log.replaceChildren();
  window.setLastUserText = (text) => {
    const users = Array.from(log.querySelectorAll('[data-content-search-unit-key$=":user"]'));
    const last = users[users.length - 1];
    const body = last && last.querySelector('.whitespace-pre-wrap');
    if (body) body.textContent = text;
  };
  render();

  document.getElementById('send').addEventListener('click', () => {
    window.sends += 1;
    const prompt = editor.innerText || '';
    editor.replaceChildren();
    cfg.turns.push({
      user: prompt,
      answer: cfg.answerOnSend ? (cfg.answerText || 'FIXTURE_ANSWER') : null,
      done: cfg.answerDone,
    });
    render();
  });
})();
</script>"""


def fixture(cfg: dict) -> bytes:
    body = PAGE.replace("window.__FIXTURE__ || {}", json.dumps(cfg, ensure_ascii=False))
    return body.encode("utf-8")


def fast_options(provider: str) -> dict:
    return {
        "sampleMs": 40,
        "stableSamples": 2,
        "stableMs": 60,
        "submitTimeoutMs": 3000,
        "sendEnableMs": 500,
        "pollMs": 40,
        "turnGraceMs": 0,
        "pendingTimeoutMs": 10000,
        "requireDoneMarker": bool(ADAPTERS[provider]["options"].get("requireDoneMarker")),
    }


def scope_for(origin: str, home: str, href: str | None) -> dict:
    scope = {"origin": origin, "homeHref": home, "allowNavigation": True}
    if href is not None:
        scope["href"] = href
    return scope


def read(page, provider, origin, home, href, prompt, task_id, options=None):
    payload = {
        "type": "arena.web.read",
        "taskId": task_id,
        "selectors": ADAPTERS[provider]["selectors"],
        "options": options or fast_options(provider),
        "scope": scope_for(origin, home, href),
    }
    if prompt is not None:
        payload["verifiedReadPrompt"] = prompt
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def submit(page, provider, origin, home, href, prompt, task_id, options=None):
    payload = {
        "type": "arena.web.submit",
        "taskId": task_id,
        "prompt": prompt,
        "selectors": ADAPTERS[provider]["selectors"],
        "options": options or fast_options(provider),
        "scope": scope_for(origin, home, href),
    }
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def read_until(page, provider, origin, home, href, prompt, task_id, seconds=2.0, options=None):
    seen = []
    deadline = seconds
    latest = None
    while deadline > 0:
        latest = read(page, provider, origin, home, href, prompt, task_id, options)
        seen.append(latest.get("status") + ":" + str(latest.get("error") or latest.get("detail", {}).get("reason") or ""))
        if latest.get("status") == "done":
            break
        page.wait_for_timeout(80)
        deadline -= 0.08
    if latest is not None:
        latest["_seen"] = seen
    return latest or {"_seen": seen, "status": "timeout"}


def scenario(browser, url: str, cfg: dict):
    ctx = browser.new_context()
    html = fixture(cfg)
    ctx.route(
        "**/*",
        lambda route: route.fulfill(
            status=200,
            headers={"content-type": "text/html; charset=utf-8"},
            body=html,
        ),
    )
    page = ctx.new_page()
    page.goto(url)
    page.add_script_tag(path=str(DRIVER))
    return ctx, page


def counters(page):
    return {
        "sends": page.evaluate("window.sends"),
        "expandClicks": page.evaluate("window.expandClicks"),
    }


def main() -> int:
    results: dict[str, bool] = {}

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            executable_path=str(find_chromium_executable()),
        )

        # A) Full text + " … Show more": the visible suffix is UI only.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [
                    {"user": OLD_USER, "answer": OLD_ANSWER, "done": True},
                    {"user": PROMPT + " … ", "answer": NEW_ANSWER, "done": True, "expand": "Show more"},
                ],
            },
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-show-more")
        results["chatgpt_show_more_suffix"] = (
            reply["status"] == "done" and reply["text"] == NEW_ANSWER and counters(page) == {"sends": 0, "expandClicks": 0}
        )
        results["chatgpt_show_more_detail"] = reply.get("_seen")
        ctx.close()

        # B) Expanded render + " Show less".
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [
                    {"user": PROMPT + " ", "answer": NEW_ANSWER, "done": True, "expand": "Show less"},
                ],
            },
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-show-less")
        results["chatgpt_show_less_suffix"] = reply["status"] == "done" and reply["text"] == NEW_ANSWER
        results["chatgpt_show_less_detail"] = reply.get("_seen")
        ctx.close()

        # C) No expander at all: visible text is compared verbatim.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {"provider": "chatgpt", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-plain")
        results["chatgpt_plain_text"] = reply["status"] == "done" and reply["text"] == NEW_ANSWER
        ctx.close()

        # D) DeepSeek conversation rebuild.
        ctx, page = scenario(
            browser,
            DEEPSEEK_CONVERSATION,
            {"provider": "deepseek", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read_until(page, "deepseek", DEEPSEEK_ORIGIN, DEEPSEEK_HOME, DEEPSEEK_CONVERSATION, PROMPT, "t-deepseek")
        results["deepseek_rebuild"] = reply["status"] == "done" and reply["text"] == NEW_ANSWER
        results["deepseek_zero_sends"] = counters(page)["sends"] == 0
        ctx.close()

        # E) Gemini rebuild; this provider requires its live finished control.
        ctx, page = scenario(
            browser,
            GEMINI_CONVERSATION,
            {"provider": "gemini", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read_until(page, "gemini", GEMINI_ORIGIN, GEMINI_HOME, GEMINI_CONVERSATION, PROMPT, "t-gemini")
        results["gemini_rebuild"] = reply["status"] == "done" and reply["text"] == NEW_ANSWER
        results["gemini_zero_sends"] = counters(page)["sends"] == 0
        ctx.close()

        # F) A rebuild must never turn a repeated submit into a click.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {"provider": "chatgpt", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-rebuild-submit")
        again = submit(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-rebuild-submit")
        results["rebuild_then_submit_zero_send"] = (
            counters(page)["sends"] == 0 and again["status"] in ("done", "pending", "submitted")
        )
        ctx.close()

        # G) Existing record, messages unmounted for a moment: read-only hold.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [{"user": OLD_USER, "answer": OLD_ANSWER, "done": True}],
                "answerText": NEW_ANSWER,
                "answerDone": True,
            },
        )
        sent = submit(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-unmounted")
        page.evaluate("window.unmountFixture()")
        held = read(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-unmounted")
        held_ok = (
            held["status"] == "pending"
            and held.get("detail", {}).get("userTurnVerified") is not True
        )
        page.evaluate("window.mountFixture()")
        recovered = read_until(
            page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-unmounted", seconds=3.0
        )
        results["existing_record_transient_hold"] = held_ok and recovered["status"] == "done"
        results["existing_record_one_send"] = counters(page)["sends"] == 1 and sent["status"] in ("submitted", "pending", "done")
        results["existing_record_detail"] = {"hold": held.get("detail", {}).get("reason"), "seen": recovered.get("_seen")}
        ctx.close()

        # G2) Existing record, the latest user node briefly re-renders a prefix:
        # user-turn-mismatch must hold read-only instead of blocking for good.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [{"user": OLD_USER, "answer": OLD_ANSWER, "done": True}],
                "answerText": NEW_ANSWER,
                "answerDone": True,
            },
        )
        submit(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-mismatch-hold")
        page.evaluate("(text) => window.setLastUserText(text)", PROMPT[:30] + " … ")
        held = read(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-mismatch-hold")
        page.evaluate("window.mountFixture()")
        recovered = read_until(
            page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-mismatch-hold", seconds=3.0
        )
        results["existing_mismatch_held"] = (
            held["status"] == "pending"
            and held.get("detail", {}).get("transientCode") == "user-turn-mismatch"
            and recovered["status"] == "done"
            and counters(page)["sends"] == 1
        )
        results["existing_mismatch_detail"] = {"hold": held.get("detail", {}).get("reason"), "seen": recovered.get("_seen")}
        ctx.close()

        # H) Prefix-only render is never accepted, even with the control.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [
                    {"user": PROMPT[:40] + " … ", "answer": NEW_ANSWER, "done": True, "expand": "Show more"},
                ],
            },
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-prefix", seconds=1.0)
        results["prefix_only_not_proven"] = reply["status"] != "done" and counters(page)["sends"] == 0
        results["prefix_only_seen"] = reply.get("_seen")
        ctx.close()

        # I) Latest user node differs.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {"provider": "chatgpt", "turns": [{"user": OLD_USER, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-different")
        results["different_latest_user_refused"] = reply["status"] != "done" and counters(page)["sends"] == 0
        ctx.close()

        # J) Duplicate matching user nodes.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [
                    {"user": PROMPT, "answer": NEW_ANSWER, "done": True},
                    {"user": PROMPT, "answer": NEW_ANSWER, "done": True},
                ],
            },
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-duplicate")
        results["duplicate_user_refused"] = reply["status"] != "done"
        results["duplicate_user_reason"] = reply.get("detail", {}).get("reason")
        ctx.close()

        # K) Only an answer before this round's user node.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [
                    {"user": OLD_USER, "answer": BEFORE_ANSWER, "done": True},
                    {"user": PROMPT, "answer": None},
                ],
            },
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-answer-before")
        results["answer_must_follow_turn"] = reply["status"] != "done"
        results["answer_must_follow_turn_reason"] = reply.get("detail", {}).get("reason")
        ctx.close()

        # L) Only the older answer carries the completion control.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {
                "provider": "chatgpt",
                "turns": [
                    {"user": OLD_USER, "answer": OLD_ANSWER, "done": True},
                    {"user": PROMPT, "answer": NEW_ANSWER, "done": False},
                ],
            },
        )
        reply = read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-old-done")
        results["old_done_marker_refused"] = reply["status"] != "done"
        results["old_done_marker_reason"] = reply.get("detail", {}).get("reason")
        ctx.close()

        # M) No bound conversation: no rebuild.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {"provider": "chatgpt", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, None, PROMPT, "t-unbound")
        results["unbound_refused"] = reply["status"] == "unknown" and reply.get("error") == "task-unknown"
        ctx.close()

        # N) Binding to the home path is not a conversation.
        ctx, page = scenario(
            browser,
            CHATGPT_HOME,
            {"provider": "chatgpt", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_HOME, PROMPT, "t-home")
        results["home_binding_refused"] = reply["status"] == "unknown"
        ctx.close()

        # O) ChatGPT temporary route is not a recovery destination.
        ctx, page = scenario(
            browser,
            CHATGPT_TEMP,
            {"provider": "chatgpt", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_TEMP, PROMPT, "t-temp")
        results["temporary_route_refused"] = reply["status"] != "done"
        results["temporary_route_error"] = reply.get("error")
        ctx.close()

        # P) A binding to another conversation is refused by the page gate.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {"provider": "chatgpt", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        reply = read(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_OTHER, PROMPT, "t-other")
        results["other_conversation_refused"] = (
            reply["status"] == "error" and reply.get("error") == "conversation-changed"
        )
        ctx.close()

        # Q) Same task id, different prompt: never adopt another round.
        ctx, page = scenario(
            browser,
            CHATGPT_CONVERSATION,
            {"provider": "chatgpt", "turns": [{"user": PROMPT, "answer": NEW_ANSWER, "done": True}]},
        )
        read_until(page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT, "t-mismatch")
        reply = read(
            page, "chatgpt", CHATGPT_ORIGIN, CHATGPT_HOME, CHATGPT_CONVERSATION, PROMPT + "另一个任务", "t-mismatch"
        )
        results["prompt_mismatch_refused"] = reply["status"] == "error" and reply.get("error") == "task-prompt-mismatch"
        ctx.close()

        browser.close()

    failed = sorted(key for key, value in results.items() if value is False)
    print(json.dumps({"results": results, "failed": failed}, ensure_ascii=False, indent=2))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
