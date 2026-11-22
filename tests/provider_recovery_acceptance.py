#!/usr/bin/env python3
"""Loopback integration test for the two real-site recovery paths.

A disposable MV3 copy points ChatGPT and Gemini at separate HTTPS fixtures on
127.0.0.1. The product worker, adapters and page driver run unchanged. The test
does not touch the real sites, accounts or network.

Scenarios
---------
A. A second session opens a new ChatGPT tab whose empty composer was restored
   with the exact prompt the first session confirmed sending. The worker may
   replace it only because its precomputed SHA-256 matches a recent confirmed
   dispatch for ChatGPT; the page must receive the digest, not the old text.
   A different human draft in a third session must stay untouched.
B. Gemini's send control stays hidden for ~11 s. The driver reports
   ``send-pending`` with ``clickAttempted:false``; the worker retries within
   ~45 s and sends exactly once. Seat detail reports the waiting phase.

Run from the repository root:

    python3 tests/provider_recovery_acceptance.py --out /tmp/ai-arena-recovery

It writes only into the requested output directory.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from browser_acceptance import find_chromium_executable  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = ("chatgpt", "gemini")
ENTRIES = ("https://chatgpt.com/", "https://gemini.google.com/app")

MARKUP = {
    "chatgpt": {
        "content": (
            '<div id="editor" class="ProseMirror" role="textbox" '
            'contenteditable="true"></div>'
            '<button id="send" data-testid="send-button">发送</button>'
            '<div id="log"></div>'
        ),
        "user": '<article data-content-search-unit-key="turn:user"></article>',
        "answer": (
            "<article><pre data-response-body></pre>"
            '<button data-testid="copy-turn-action-button">复制</button></article>'
        ),
        "body": "[data-response-body]",
    },
    "gemini": {
        "content": (
            "<rich-textarea>"
            '<div id="editor" class="ql-editor" contenteditable="true"></div>'
            "</rich-textarea>"
            '<button id="send" aria-label="Send message">发送</button>'
            '<div id="log"></div>'
        ),
        "user": "<user-query></user-query>",
        "answer": (
            "<model-response><message-content></message-content>"
            '<button aria-label="复制回答">复制</button></model-response>'
        ),
        "body": "message-content",
    },
}

TEMPLATE = r"""<!doctype html><meta charset=utf-8>
<style>
  #editor { display:block; width:700px; min-height:28px; border:1px solid #999; }
  #send { display:block; margin:8px 0; }
</style>
CONTENT
<script>
(function () {
  'use strict';
  const cfg = Object.assign(
    { prefill: '', hiddenMs: 0 },
    __FIXTURE_CONFIG__,
  );
  const editor = document.getElementById('editor');
  const send = document.getElementById('send');
  const log = document.getElementById('log');
  const USER = __USER__;
  const ANSWER = __ANSWER__;
  const BODY = __BODY__;
  let seq = 0;
  window.turns = [];

  function put(html) {
    log.insertAdjacentHTML('beforeend', html);
    return log.lastElementChild;
  }
  if (cfg.prefill) {
    if (editor.tagName === 'TEXTAREA') editor.value = cfg.prefill;
    else editor.innerText = cfg.prefill;
  }
  if (cfg.hiddenMs > 0) {
    send.style.display = 'none';
    setTimeout(function () { send.style.display = ''; }, cfg.hiddenMs);
  }
  send.addEventListener('click', function () {
    const prompt = editor.tagName === 'TEXTAREA'
      ? editor.value
      : (editor.innerText || editor.textContent || '');
    if (!prompt.trim()) return;
    if (editor.tagName === 'TEXTAREA') editor.value = '';
    else editor.replaceChildren();
    seq += 1;
    const user = put(USER);
    user.textContent = prompt;
    const answer = put(ANSWER);
    const body = answer.matches(BODY) ? answer : answer.querySelector(BODY);
    body.textContent = '回环夹具回答 ' + __PROVIDER__ + ' 第' + seq + '轮。';
    window.turns.push({ prompt: prompt, text: body.textContent });
  });
})();
</script>"""

STORE_KEY = "arena.automation.v1"


def payload(provider, prefill="", hidden_ms=0):
    spec = MARKUP[provider]
    window = {"prefill": prefill, "hiddenMs": hidden_ms}
    text = TEMPLATE
    for pair in (
        ("CONTENT", spec["content"]),
        ("__USER__", json.dumps(spec["user"])),
        ("__ANSWER__", json.dumps(spec["answer"])),
        ("__BODY__", json.dumps(spec["body"])),
        ("__PROVIDER__", json.dumps(provider)),
        ("__FIXTURE_CONFIG__", json.dumps(window, ensure_ascii=False)),
    ):
        text = text.replace(pair[0], pair[1])
    return text.encode("utf-8")


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


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(self.server.payload)

    def log_message(self, *_):
        pass


def call(page, message):
    result = page.evaluate("(payload) => chrome.runtime.sendMessage(payload)", message)
    if not result or not result.get("ok"):
        raise AssertionError(result)
    return result


def wait(page, fn, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        page.wait_for_timeout(180)
    raise AssertionError("timed out")


def set_store(page, value):
    page.evaluate(
        """(arg) => new Promise((resolve) => {
          chrome.storage.local.set({ [arg.key]: arg.value }, resolve);
        })""",
        {"key": STORE_KEY, "value": value},
    )


def read_store(page):
    return page.evaluate(
        """(key) => new Promise((resolve) => {
          chrome.storage.local.get(key, (value) => resolve(value[key]));
        })""",
        STORE_KEY,
    )


def session(page, sid):
    return call(page, {"type": "get", "id": sid})["session"]


def create(page, question):
    return call(
        page,
        {"type": "create", "question": question, "providers": list(PROVIDERS)},
    )["session"]


def provider_page(ctx, origin):
    for tab in ctx.pages:
        if tab.is_closed():
            continue
        if tab.url.startswith(origin + "/"):
            return tab
    return None


def close_provider_tabs(ctx, origins):
    for tab in list(ctx.pages):
        if any(tab.url.startswith(origin + "/") for origin in origins):
            tab.close()


def independent_prompt(state, provider):
    for entry in state.get("history", []):
        if entry.get("stage") == "independent" and entry.get("provider") == provider:
            return entry.get("prompt", "")
    for entry in state.get("tasks", []):
        # Current-stage tasks have no stage field; only use them as a fallback.
        if entry.get("provider") == provider:
            return entry.get("prompt", "")
    return ""


def main(out: Path) -> int:
    out.mkdir(exist_ok=True, parents=True)
    results = {}
    with tempfile.TemporaryDirectory() as dirname:
        root = Path(dirname)
        key, cert = root / "key", root / "cert"
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key), "-out", str(cert), "-days", "1",
                "-subj", "/CN=127.0.0.1",
            ],
            check=True,
            capture_output=True,
        )
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        servers = []
        for index in range(len(PROVIDERS)):
            srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            srv.payload = payload(PROVIDERS[index])
            srv.socket = tls.wrap_socket(srv.socket, server_side=True)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            servers.append(srv)
        origins = [f"https://127.0.0.1:{srv.server_port}" for srv in servers]

        ext = root / "extension"
        shutil.copytree(ROOT / "extension", ext)
        registry = ext / "providers.js"
        text = registry.read_text()
        for url, origin in zip(ENTRIES, origins):
            text = text.replace(url, origin + "/")
        registry.write_text(text)
        manifest_path = ext / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["host_permissions"] = ["https://127.0.0.1/*"]
        manifest_path.write_text(json.dumps(manifest))

        try:
            with sync_playwright() as p:
                ctx = p.chromium.launch_persistent_context(
                    str(root / "profile"),
                    headless=True,
                    executable_path=str(find_chromium_executable()),
                    args=[
                        f"--disable-extensions-except={ext}",
                        f"--load-extension={ext}",
                        "--ignore-certificate-errors",
                        "--no-proxy-server",
                        "--disable-quic",
                        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
                        "--disable-background-networking",
                    ],
                )
                worker = (
                    ctx.service_workers[0]
                    if ctx.service_workers
                    else ctx.wait_for_event("serviceworker", timeout=15000)
                )
                page = ctx.new_page()
                page.goto(worker.url.rsplit("/", 1)[0] + "/workspace.html")

                # --- Seed one confirmed ChatGPT dispatch from a real session.
                first = create(page, "回环恢复种子问题：如何小规模验证旧提示复用？")
                first_state = session(page, first["id"])
                first_task = next(
                    task for task in first_state["tasks"] if task["provider"] == "chatgpt"
                )
                old_prompt = first_task["prompt"]
                seed_run = {
                    "enabled": False,
                    "completed": True,
                    "startedAt": int(time.time() * 1000) - 5000,
                    "updatedAt": int(time.time() * 1000),
                    "stoppedAt": int(time.time() * 1000),
                    "bootId": "seed",
                    "windowId": None,
                    "openerTabId": None,
                    "tabs": {},
                    "dispatch": {
                        first_task["id"]: {
                            "taskId": first_task["id"],
                            "provider": "chatgpt",
                            "phase": "answered",
                            "bootId": "seed",
                            "stage": "independent",
                            "round": 0,
                            "voteInstruction": False,
                            "status": "done",
                            "at": int(time.time() * 1000),
                        }
                    },
                    "seats": {},
                    "lastError": "",
                }
                set_store(
                    page,
                    {"version": 1, "configs": {}, "runs": {first["id"]: seed_run}},
                )

                # --- Scenario A+B: prefill ChatGPT with the old prompt and hide
                # Gemini's send control for 11 s in the second session.
                servers[0].payload = payload("chatgpt", prefill=old_prompt)
                servers[1].payload = payload("gemini", hidden_ms=11000)
                second = create(page, "回环恢复问题：本轮新提示应替换站点恢复的旧提示。")
                sid2 = second["id"]
                call(page, {"type": "automation.start", "id": sid2})

                saw_waiting = False

                def independent_done():
                    nonlocal saw_waiting
                    state = session(page, sid2)
                    info = call(page, {"type": "automation.info"})["runs"].get(sid2) or {}
                    for seat in info.get("seats", {}).values():
                        detail = seat.get("detail", "")
                        if "尚未点击发送" in detail or "发送控件暂未出现" in detail:
                            saw_waiting = True
                    answered = [
                        entry
                        for entry in state.get("history", [])
                        if entry.get("stage") == "independent"
                        and entry.get("status") == "answered"
                    ]
                    return state if len(answered) >= 2 else None

                second_state = wait(page, independent_done, seconds=70)
                call(page, {"type": "automation.stop", "id": sid2})
                page.wait_for_timeout(400)

                chat_tab = provider_page(ctx, origins[0])
                gem_tab = provider_page(ctx, origins[1])
                assert chat_tab and gem_tab, [tab.url for tab in ctx.pages]
                chat_turns = chat_tab.evaluate("window.turns")
                gem_turns = gem_tab.evaluate("window.turns")
                p2_chat = independent_prompt(second_state, "chatgpt")
                p2_gem = independent_prompt(second_state, "gemini")

                assert p2_chat.strip(), second_state
                assert chat_turns, chat_turns
                assert collapse(chat_turns[0]["prompt"]) == collapse(p2_chat), (
                    chat_turns[0]["prompt"],
                    p2_chat,
                )
                assert all(
                    collapse(turn["prompt"]) != collapse(old_prompt)
                    for turn in chat_turns
                ), chat_turns
                assert sum(
                    1
                    for turn in chat_turns
                    if collapse(turn["prompt"]) == collapse(p2_chat)
                ) == 1, chat_turns
                assert gem_turns, gem_turns
                assert collapse(gem_turns[0]["prompt"]) == collapse(p2_gem), (
                    gem_turns[0]["prompt"],
                    p2_gem,
                )
                assert saw_waiting, "seat never reported the pre-click waiting phase"

                raw = read_store(page)
                run2 = raw["runs"][sid2]
                confirmed = ("submitted", "streaming", "answered")
                chat_dispatch = next(
                    item
                    for item in run2["dispatch"].values()
                    if item["provider"] == "chatgpt"
                    and item["stage"] == "independent"
                    and item["phase"] in confirmed
                )
                gem_dispatch = next(
                    item
                    for item in run2["dispatch"].values()
                    if item["provider"] == "gemini"
                    and item["stage"] == "independent"
                    and item["phase"] in confirmed
                )
                assert chat_dispatch["clickAttempted"] is True, chat_dispatch
                assert gem_dispatch["clickAttempted"] is True, gem_dispatch
                assert gem_dispatch["preClickAttempts"] >= 1, gem_dispatch

                chat_tab.screenshot(path=str(out / "chatgpt-recovered.png"), full_page=True)
                gem_tab.screenshot(path=str(out / "gemini-send-wait.png"), full_page=True)
                results.update(
                    {
                        "draft_replaced_once": True,
                        "old_prompt_not_sent": True,
                        "gemini_pre_click_waits": gem_dispatch["preClickAttempts"],
                        "seat_reported_waiting": True,
                    }
                )

                close_provider_tabs(ctx, origins)

                # --- Scenario A safety: a different human draft is untouched.
                human = "这是我手动写下的不同草稿，不是 Arena 的旧提示，绝不能覆盖。"
                servers[0].payload = payload("chatgpt", prefill=human)
                servers[1].payload = payload("gemini")
                third = create(page, "回环恢复问题：人工草稿保护。")
                sid3 = third["id"]
                call(page, {"type": "automation.start", "id": sid3})

                def chat_paused():
                    info = call(page, {"type": "automation.info"})["runs"].get(sid3) or {}
                    seat = (info.get("seats") or {}).get("chatgpt") or {}
                    return seat if seat.get("paused") and "draft-conflict" in seat.get("detail", "") else None

                seat3 = wait(page, chat_paused, seconds=20)
                call(page, {"type": "automation.stop", "id": sid3})
                page.wait_for_timeout(300)
                human_tab = provider_page(ctx, origins[0])
                assert human_tab, [tab.url for tab in ctx.pages]
                composer = human_tab.evaluate(
                    "() => { const el=document.querySelector('#editor');"
                    " return el.tagName === 'TEXTAREA' ? el.value : el.innerText; }"
                )
                assert collapse(composer) == collapse(human), (composer, human)
                assert human_tab.evaluate("window.turns.length") == 0, human_tab.evaluate(
                    "window.turns"
                )
                human_tab.screenshot(path=str(out / "human-draft-kept.png"), full_page=True)
                results["human_draft_kept"] = True
                results["paused_reason"] = seat3["detail"]

                (out / "result.json").write_text(
                    json.dumps(results, ensure_ascii=False, indent=2)
                )
                print((out / "result.json").read_text(), flush=True)
                ctx.close()
        finally:
            for srv in servers:
                srv.shutdown()
                srv.server_close()
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    raise SystemExit(main(parser.parse_args().out.resolve()))
