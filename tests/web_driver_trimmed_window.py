#!/usr/bin/env python3
"""Offline replay for the same-conversation window-trim recovery (G1/G3).

The real ``extension/web-driver.js`` runs unchanged in a plain page whose
address is a registered ChatGPT conversation URL
(``https://chatgpt.com/c/<id>``). Every request is answered by a Playwright
route, so nothing leaves the machine and no account is touched.

The reproducer is the reported case: the round's prompt was sent inside an
existing ChatGPT conversation, the site then virtualized the oldest user
message *and* its answer out of the DOM. The remaining user nodes are the
critique and the new candidate, so the baseline count no longer orders the
new turn and the driver used to stay in ``verifying`` forever.

Checks
------
A. Old user+answer trimmed, new answer = same node count as the baseline:
   the round is verified from the baseline suffix and the *new* answer text
   is returned (one click only).
B. Same, but the window drops the old turn first and mounts the candidate a
   moment later: no ``history-changed`` while the count is temporarily below
   the baseline; the round verifies once the candidate mounts.
C. Another origin (same selectors, same shape) is never taken over.
D. ChatGPT's new-conversation home (no ``/c/<id>``) is never taken over.
E. No recognizable old node left -> conservative refusal.
F. Remaining old nodes are not a suffix of the baseline -> refusal.
G. An answer whose text already existed before the click is not accepted.
H. The same question already in the submission baseline -> refusal.
I. The same recovery works on a registered DeepSeek conversation URL
   (``https://chat.deepseek.com/a/chat/s/<id>``) when only the old *user*
   message is trimmed away: three answers stay mounted, the new answer is
   after this round's user node, and the pre-click answers are excluded.
J. DeepSeek's new-conversation home (``https://chat.deepseek.com/``) is
   never taken over.
K. DeepSeek paths that are not a registered conversation (empty session id,
   ``/a/chat``) are never taken over.

Run from the repository root:

    python3 tests/web_driver_trimmed_window.py

Exit code 0 means all checks passed (one JSON summary on stdout).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from browser_acceptance import find_chromium_executable  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "extension" / "web-driver.js"

CHATGPT_ORIGIN = "https://chatgpt.com"
CONVERSATION = CHATGPT_ORIGIN + "/c/68fd3c40-9a4c-8327-8f2e-3b0e6a5c1a77"
OTHER_ORIGIN = "https://example.test"
OTHER_CONVERSATION = OTHER_ORIGIN + "/c/68fd3c40-9a4c-8327-8f2e-3b0e6a5c1a77"
DEEPSEEK_ORIGIN = "https://chat.deepseek.com"
DEEPSEEK_CONVERSATION = DEEPSEEK_ORIGIN + "/a/chat/s/1c9d2f7e-4a55-4c0b-9e3a-77b1d2c4e610"

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #prompt-textarea { display:block; width:720px; min-height:32px; border:1px solid #999; }
  #send { display:block; margin:8px 0; }
  #log article { display:block; margin:4px 0; }
</style>
<div id="prompt-textarea" class="ProseMirror" contenteditable="true"></div>
<button id="send" data-testid="send-button">发送</button>
<div id="log"></div>
<script>
(function () {
  'use strict';
  const cfg = Object.assign({
    turns: [], evict: 0, evictLast: false, mountDelayMs: 0, answerDelayMs: 0, answerText: ''
  }, window.__FIXTURE__ || {});
  const editor = document.getElementById('prompt-textarea');
  const send = document.getElementById('send');
  const log = document.getElementById('log');
  window.sends = 0;

  function userNode(text) {
    const user = document.createElement('article');
    user.setAttribute('data-message-author-role', 'user');
    const body = document.createElement('div');
    body.className = 'whitespace-pre-wrap';
    body.textContent = text;
    user.appendChild(body);
    return user;
  }

  function answerNode(text) {
    const answer = document.createElement('article');
    answer.setAttribute('data-message-author-role', 'assistant');
    const body = document.createElement('div');
    body.className = 'markdown';
    body.textContent = text;
    answer.appendChild(body);
    const copy = document.createElement('button');
    copy.setAttribute('data-testid', 'copy-turn-action-button');
    copy.textContent = '复制';
    answer.appendChild(copy);
    return answer;
  }

  cfg.turns.forEach(function (item) {
    const wrap = document.createElement('div');
    wrap.className = 'thread-turn';
    wrap.appendChild(userNode(item.user));
    if (item.answer !== null && item.answer !== undefined) wrap.appendChild(answerNode(item.answer));
    log.appendChild(wrap);
  });

  function evict() {
    const wraps = Array.from(log.querySelectorAll('.thread-turn'));
    for (let index = 0; index < cfg.evict && wraps.length; index += 1) {
      const at = cfg.evictLast ? wraps.length - 1 : 0;
      wraps.splice(at, 1)[0].remove();
    }
  }

  function mount(prompt) {
    evict();
    const wrap = document.createElement('div');
    wrap.className = 'thread-turn';
    wrap.appendChild(userNode(prompt));
    log.appendChild(wrap);
    const answer = function () {
      if (cfg.answerText) wrap.appendChild(answerNode(cfg.answerText));
    };
    if (cfg.answerDelayMs > 0) setTimeout(answer, cfg.answerDelayMs);
    else answer();
  }

  send.addEventListener('click', function () {
    const prompt = editor.innerText || editor.textContent || '';
    if (!prompt.trim()) return;
    window.sends += 1;
    editor.replaceChildren();
    if (cfg.mountDelayMs > 0) setTimeout(function () { mount(prompt); }, cfg.mountDelayMs);
    else mount(prompt);
  });
})();
</script>"""

SELECTORS = {
    "input": ['div.ProseMirror[contenteditable="true"]', "#prompt-textarea"],
    "send": ['button[data-testid="send-button"]'],
    "user": ['[data-content-search-unit-key$=":user"]', '[data-message-author-role="user"]'],
    "answer": [
        "[data-response-body]",
        '[data-message-author-role="assistant"] .markdown',
        '[data-message-author-role="assistant"]',
    ],
    "stop": ["button[data-testid=\"stop-button\"]"],
    "done": [
        "article:has([data-response-body]) button[data-testid=\"copy-turn-action-button\"]",
        '[data-message-author-role="assistant"] button[data-testid="copy-turn-action-button"]',
    ],
}

# DeepSeek shape: the site trims the oldest *user* node while the answers stay
# mounted, so the reported page keeps three answers and only the critique plus
# this round's candidate as user nodes.
DS_PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #chat-input { display:block; width:720px; height:48px; }
  #send { display:block; margin:8px 0; }
  .ds-message { display:block; margin:4px 0; }
  .ds-assistant-message-main-content { display:block; }
  .ds-flex { display:block; }
</style>
<textarea id="chat-input" name="search"></textarea>
<button id="send" class="ds-button--primary ds-button--circle">发送</button>
<div id="log"></div>
<script>
(function () {
  'use strict';
  const cfg = Object.assign({
    turns: [], evictUsers: 0, mountDelayMs: 0, answerDelayMs: 0, answerText: ''
  }, window.__FIXTURE__ || {});
  const input = document.getElementById('chat-input');
  const send = document.getElementById('send');
  const log = document.getElementById('log');
  window.sends = 0;

  function userNode(text) {
    const message = document.createElement('div');
    message.className = 'ds-message';
    const body = document.createElement('div');
    body.className = 'fbb737a4';
    body.textContent = text;
    message.appendChild(body);
    log.appendChild(message);
    return message;
  }

  function answerNode(text) {
    const message = document.createElement('div');
    message.className = 'ds-message';
    const body = document.createElement('div');
    body.className = 'ds-assistant-message-main-content';
    body.textContent = text;
    message.appendChild(body);
    const tools = document.createElement('div');
    tools.className = 'ds-flex';
    const read = document.createElement('button');
    read.setAttribute('aria-label', '朗读');
    read.textContent = '朗读';
    tools.appendChild(read);
    message.appendChild(tools);
    log.appendChild(message);
    return message;
  }

  cfg.turns.forEach(function (item) {
    userNode(item.user);
    if (item.answer !== null && item.answer !== undefined) answerNode(item.answer);
  });

  function evictUsers() {
    const users = Array.from(
      log.querySelectorAll('.ds-message:not(:has(.ds-assistant-message-main-content))')
    );
    for (let index = 0; index < cfg.evictUsers && index < users.length; index += 1) {
      users[index].remove();
    }
  }

  function mount(prompt) {
    evictUsers();
    userNode(prompt);
    const answer = function () {
      if (cfg.answerText) answerNode(cfg.answerText);
    };
    if (cfg.answerDelayMs > 0) setTimeout(answer, cfg.answerDelayMs);
    else answer();
  }

  send.addEventListener('click', function () {
    const prompt = input.value || '';
    if (!prompt.trim()) return;
    window.sends += 1;
    input.value = '';
    if (cfg.mountDelayMs > 0) setTimeout(function () { mount(prompt); }, cfg.mountDelayMs);
    else mount(prompt);
  });
})();
</script>"""

DS_SELECTORS = {
    "input": ['textarea[name="search"]', "#chat-input"],
    "send": ["button.ds-button--primary.ds-button--circle"],
    "user": [
        ".ds-message:not(:has(.ds-assistant-message-main-content)) .fbb737a4",
        ".fbb737a4",
    ],
    "answer": [".ds-assistant-message-main-content"],
    "stop": [".ds-loading"],
    "done": [
        ".ds-message:has(.ds-assistant-message-main-content) .ds-flex "
        ':is(button, [role="button"])[aria-label="朗读"]',
    ],
}

OPTIONS = {
    "sampleMs": 50,
    "stableSamples": 2,
    "stableMs": 100,
    "submitTimeoutMs": 8000,
    "sendEnableMs": 2000,
    "pollMs": 50,
    "turnGraceMs": 0,
    "pendingTimeoutMs": 30000,
    "previewChars": 600,
}

FAST = dict(OPTIONS, submitTimeoutMs=1200)

PROMPT = (
    "本轮候选：请把两位同事关于「先验证再扩展」和「先扩展再验证」的取舍写成一份可执行结论。\n\n"
    "要求：\n"
    "1. 先指出两人分歧的实际分歧点，而不是各自措辞。\n"
    "2. 给出一个两周内可完成的顺序，并写明每周的验证动作。\n"
    "3. 说明在什么条件下应改走另一条路，以及判断条件何时可以回退。\n"
    "4. 保留仍未解决的条件，不要用「综合考虑」代替结论。\n\n"
    "背景：现有实现只在一个内部团队的桌面端验证过，手机端采集曾经出现过一次中断，"
    "但没有稳定复现。支持先扩展的一方的理由是新用户增长窗口只有六周；支持先验证的一方的理由"
    "是中断发生在新用户第一次录入时，损失最大。两人的共同点是都承认需要量化损失，"
    "区别在于量化放在扩展之前还是之后。请在结论里明确写出谁的条件被保留、谁的条件被暂时搁置。"
)
OLD_A = "独立作答：我认为应当先验证，因为中断发生在第一次录入。"
OLD_A_ANSWER = "独立回答：先验证。桌面端样本只能说明桌面端没问题。"
CRITIQUE = "质询：你如何解释六周增长窗口？如果验证拖到窗口之后，损失又怎么算？"
CRITIQUE_ANSWER = "质询回答：窗口是约束不是理由，验证可以在窗口内并行。"
NEW_ANSWER = "候选回答：首周小样本验证，次周按结果扩展；若手机端复现中断则先修手机端。"

BASE_TURNS = [
    {"user": OLD_A, "answer": OLD_A_ANSWER},
    {"user": CRITIQUE, "answer": CRITIQUE_ANSWER},
]


def fixture(cfg: dict, page_html: str = PAGE) -> bytes:
    # The config rides in the HTML so the address can stay an exact
    # conversation URL (the recovery gate rejects query strings).
    body = page_html.replace("window.__FIXTURE__ || {}", json.dumps(cfg, ensure_ascii=False))
    return body.encode("utf-8")


def scenario(browser, url: str, cfg: dict, page_html: str = PAGE):
    ctx = browser.new_context()
    html = fixture(cfg, page_html)
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


def handle(page, payload):
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def message(kind, task_id, url, prompt=None, options=None, selectors=None):
    parts = urlsplit(url)
    origin = f"{parts.scheme}://{parts.netloc}"
    payload = {
        "type": kind,
        "taskId": task_id,
        "selectors": selectors or SELECTORS,
        "options": options or OPTIONS,
        "scope": {"origin": origin, "homeHref": origin + "/", "allowNavigation": True},
    }
    if prompt is not None:
        payload["prompt"] = prompt
    return payload


def submit(page, url, task_id, prompt=PROMPT, options=None):
    return handle(page, message("arena.web.submit", task_id, url, prompt, options))


def read(page, url, task_id, options=None):
    return handle(page, message("arena.web.read", task_id, url, None, options))


def ds_submit(page, url, task_id, prompt=PROMPT, options=None):
    return handle(page, message("arena.web.submit", task_id, url, prompt, options, DS_SELECTORS))


def ds_read(page, url, task_id, options=None):
    return handle(page, message("arena.web.read", task_id, url, None, options, DS_SELECTORS))


def ds_read_until_done(page, url, task_id, seconds=8.0):
    deadline = seconds
    seen = []
    while deadline > 0:
        reply = ds_read(page, url, task_id)
        seen.append(reply.get("status"))
        if reply.get("status") == "done":
            reply["_seen"] = seen
            return reply
        page.wait_for_timeout(120)
        deadline -= 0.12
    return {"_seen": seen, "status": "timeout"}


def read_until_done(page, url, task_id, seconds=8.0):
    deadline = seconds
    seen = []
    while deadline > 0:
        reply = read(page, url, task_id)
        seen.append(reply.get("status"))
        if reply.get("status") == "done":
            reply["_seen"] = seen
            return reply
        page.wait_for_timeout(120)
        deadline -= 0.12
    return {"_seen": seen, "status": "timeout"}


def expect_unconfirmed(first, page):
    """A refused takeover may only produce the already-clicked, read-only state."""
    assert first["status"] == "error", first
    assert first["error"] == "submit-unconfirmed", first
    assert first["detail"]["possiblySubmitted"] is True, first
    assert first["detail"]["clickAttempted"] is True, first
    assert page.evaluate("window.sends") == 1


def expect_not_verified(page, url, task_id, reader=read):
    """Three reads must never verify, never complete and never click again."""
    assert page.evaluate("window.sends") == 1
    for _ in range(3):
        reply = reader(page, url, task_id)
        assert reply["status"] in ("pending", "unknown"), reply
        assert reply.get("detail", {}).get("userTurnVerified") is not True, reply
        page.wait_for_timeout(150)
    assert page.evaluate("window.sends") == 1


def main() -> int:
    results = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            executable_path=str(find_chromium_executable()),
        )

        # A) equal node counts: one old user+answer trimmed, candidate + answer mount
        ctx, page = scenario(
            browser,
            CONVERSATION,
            {"turns": BASE_TURNS, "evict": 1, "answerDelayMs": 400, "answerText": NEW_ANSWER},
        )
        first = submit(page, CONVERSATION, "t-trim-equal")
        assert first["status"] == "submitted", first
        assert first["detail"]["historyTrimmed"] == {"evictedUsers": 1, "keptUsers": 1}, first
        done = read_until_done(page, CONVERSATION, "t-trim-equal")
        assert done["status"] == "done", done
        assert done["text"] == NEW_ANSWER, done
        assert done["detail"]["historyTrimmed"] == {"evictedUsers": 1, "keptUsers": 1}, done
        assert done["detail"]["userTurnVerified"] is True, done
        assert page.evaluate("window.sends") == 1
        assert page.evaluate("document.querySelectorAll('[data-message-author-role=\"user\"]').length") == 2
        results["equal_count_trimmed"] = done["_seen"]
        ctx.close()

        # B) the window drops the old turn first: count below baseline, then mounts
        ctx, page = scenario(
            browser,
            CONVERSATION,
            {"turns": BASE_TURNS, "evict": 1, "mountDelayMs": 500, "answerDelayMs": 300, "answerText": NEW_ANSWER},
        )
        first = submit(page, CONVERSATION, "t-trim-late")
        assert first["status"] == "submitted", first
        assert first["detail"]["historyTrimmed"] == {"evictedUsers": 1, "keptUsers": 1}, first
        done = read_until_done(page, CONVERSATION, "t-trim-late")
        assert done["status"] == "done" and done["text"] == NEW_ANSWER, done
        assert page.evaluate("window.sends") == 1
        results["below_baseline_then_mount"] = done["_seen"]
        ctx.close()

        # C) another origin with the same shape is never taken over
        ctx, page = scenario(
            browser,
            OTHER_CONVERSATION,
            {"turns": BASE_TURNS, "evict": 1, "answerText": NEW_ANSWER},
        )
        first = submit(page, OTHER_CONVERSATION, "t-other-origin", options=FAST)
        expect_unconfirmed(first, page)
        assert "historyTrimmed" not in first["detail"], first
        expect_not_verified(page, OTHER_CONVERSATION, "t-other-origin")
        results["other_origin_refused"] = True
        ctx.close()

        # D) ChatGPT's new-conversation home (no /c/<id>) is never taken over
        ctx, page = scenario(
            browser,
            CHATGPT_ORIGIN + "/",
            {"turns": BASE_TURNS, "evict": 1, "answerText": NEW_ANSWER},
        )
        first = submit(page, CHATGPT_ORIGIN + "/", "t-home", options=FAST)
        expect_unconfirmed(first, page)
        assert "historyTrimmed" not in first["detail"], first
        expect_not_verified(page, CHATGPT_ORIGIN + "/", "t-home")
        results["home_refused"] = True
        ctx.close()

        # E) no recognizable old node left behind -> conservative refusal
        ctx, page = scenario(
            browser,
            CONVERSATION,
            {"turns": [BASE_TURNS[1]], "evict": 1, "answerText": NEW_ANSWER},
        )
        first = submit(page, CONVERSATION, "t-no-history", options=FAST)
        expect_unconfirmed(first, page)
        assert "historyTrimmed" not in first["detail"], first
        expect_not_verified(page, CONVERSATION, "t-no-history")
        results["no_known_history_refused"] = True
        ctx.close()

        # F) the kept old node is not a baseline suffix -> refusal
        ctx, page = scenario(
            browser,
            CONVERSATION,
            {"turns": BASE_TURNS, "evict": 1, "evictLast": True, "answerText": NEW_ANSWER},
        )
        first = submit(page, CONVERSATION, "t-suffix", options=FAST)
        expect_unconfirmed(first, page)
        assert "historyTrimmed" not in first["detail"], first
        expect_not_verified(page, CONVERSATION, "t-suffix")
        results["suffix_mismatch_refused"] = True
        ctx.close()

        # G) an answer text seen before the click is never accepted as this round's
        ctx, page = scenario(
            browser,
            CONVERSATION,
            {"turns": BASE_TURNS, "evict": 1, "answerText": CRITIQUE_ANSWER},
        )
        first = submit(page, CONVERSATION, "t-old-answer")
        assert first["status"] == "submitted", first
        assert first["detail"]["historyTrimmed"] == {"evictedUsers": 1, "keptUsers": 1}, first
        pending = read(page, CONVERSATION, "t-old-answer")
        assert pending["status"] == "pending", pending
        assert pending["detail"]["reason"] == "answer-equal-old", pending
        assert page.evaluate("window.sends") == 1
        results["old_answer_refused"] = pending["detail"]["reason"]
        ctx.close()

        # H) the same question already in the baseline -> refusal
        ctx, page = scenario(
            browser,
            CONVERSATION,
            {
                "turns": [{"user": PROMPT, "answer": OLD_A_ANSWER}, BASE_TURNS[1]],
                "evict": 1,
                "answerText": NEW_ANSWER,
            },
        )
        first = submit(page, CONVERSATION, "t-repeat", options=FAST)
        expect_unconfirmed(first, page)
        assert "historyTrimmed" not in first["detail"], first
        expect_not_verified(page, CONVERSATION, "t-repeat")
        results["baseline_prompt_refused"] = True
        ctx.close()

        # I) registered DeepSeek conversation: old user node trimmed, answers stay
        ctx, page = scenario(
            browser,
            DEEPSEEK_CONVERSATION,
            {"turns": BASE_TURNS, "evictUsers": 1, "answerDelayMs": 400, "answerText": NEW_ANSWER},
            page_html=DS_PAGE,
        )
        first = ds_submit(page, DEEPSEEK_CONVERSATION, "t-ds-trim")
        assert first["status"] == "submitted", first
        assert first["detail"]["historyTrimmed"] == {"evictedUsers": 1, "keptUsers": 1}, first
        done = ds_read_until_done(page, DEEPSEEK_CONVERSATION, "t-ds-trim")
        assert done["status"] == "done", done
        assert done["text"] == NEW_ANSWER, done
        assert done["detail"]["historyTrimmed"] == {"evictedUsers": 1, "keptUsers": 1}, done
        assert done["detail"]["userTurnVerified"] is True, done
        assert page.evaluate("window.sends") == 1
        # The reported shape: the critique and this round only, three answers.
        assert page.evaluate("document.querySelectorAll('.fbb737a4').length") == 2
        assert page.evaluate(
            "document.querySelectorAll('.ds-assistant-message-main-content').length"
        ) == 3
        results["deepseek_trimmed"] = done["_seen"]
        ctx.close()

        # J) DeepSeek's new-conversation home is never taken over
        ctx, page = scenario(
            browser,
            DEEPSEEK_ORIGIN + "/",
            {"turns": BASE_TURNS, "evictUsers": 1, "answerText": NEW_ANSWER},
            page_html=DS_PAGE,
        )
        first = ds_submit(page, DEEPSEEK_ORIGIN + "/", "t-ds-home", options=FAST)
        expect_unconfirmed(first, page)
        assert "historyTrimmed" not in first["detail"], first
        expect_not_verified(page, DEEPSEEK_ORIGIN + "/", "t-ds-home", reader=ds_read)
        results["deepseek_home_refused"] = True
        ctx.close()

        # K) DeepSeek paths outside the registered conversation pattern
        for url, task_id in (
            (DEEPSEEK_ORIGIN + "/a/chat/s/", "t-ds-empty-id"),
            (DEEPSEEK_ORIGIN + "/a/chat", "t-ds-other-path"),
        ):
            ctx, page = scenario(
                browser,
                url,
                {"turns": BASE_TURNS, "evictUsers": 1, "answerText": NEW_ANSWER},
                page_html=DS_PAGE,
            )
            first = ds_submit(page, url, task_id, options=FAST)
            expect_unconfirmed(first, page)
            assert "historyTrimmed" not in first["detail"], first
            expect_not_verified(page, url, task_id, reader=ds_read)
            ctx.close()
        results["deepseek_unregistered_path_refused"] = True

        browser.close()
    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
