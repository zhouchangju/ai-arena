#!/usr/bin/env python3
"""Focused regression for Gemini's completion condition (G2/G3, R06).

Real three-seat run (2026-11-22): a Gemini seat was saved with only the
9-character heading 「明确判断与主要理由」. The stop control had been visible
and then disappeared, and the heading alone stayed unchanged across samples,
so the generic "stop observed, then gone + stable text" rule treated a heading
as the answer.

This harness runs the real ``extension/web-driver.js`` in a loopback page and
takes the selectors/options from the real ``extension/provider-web-configs.js``
through Node, so the test follows the shipped adapter rather than a copy.
It simulates the observed sequence:

1. the answer body starts with the heading only;
2. the stop control disappears almost immediately;
3. several full sampling rounds happen while that heading is the whole text;
4. only afterwards does the native finished control
   (``model-response gem-icon-button[data-test-id="regenerate-button"]``)
   appear together with the full body.

The driver must stay pending for every read in 3 (no ``text``, heading only as
a preview), then return the full body once, with ``evidence:'done-marker'``.
A second page proves the default rule is untouched: without
``requireDoneMarker`` the same sequence still finishes on ``stop-observed``, so
ChatGPT and DeepSeek keep their current behaviour.

Run from the repository root:

    python3 tests/gemini_completion_acceptance.py [--out DIR]

Exit code 0 means all checks passed. It touches no real site and no network
beyond 127.0.0.1.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent))
from browser_acceptance import find_chromium_executable  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "extension" / "web-driver.js"

HEADING = "明确判断与主要理由"
FULL_BODY = (
    "明确判断与主要理由\n"
    "先验证再扩展，理由是当前证据只覆盖一个周末的小样本，不能据此承诺移动端。\n"
    "建议先做一个可回滚的最小实验，再决定是否扩大范围。"
)

# The shipped adapter is the source of truth for selectors and options.
ADAPTER = json.loads(
    subprocess.run(
        [
            "node",
            "--input-type=module",
            "-e",
            (
                "import { webSiteConfig } from './extension/provider-web-configs.js';"
                "const c = webSiteConfig('gemini');"
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

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>
  #editor { display:block; width:700px; min-height:28px; border:1px solid #999; }
  #send { display:block; margin:8px 0; }
  user-query { display:block; white-space:pre-wrap; }
  message-content { display:block; white-space:pre-wrap; }
  gem-icon-button { display:inline-block; padding:2px 8px; }
</style>
<rich-textarea><div id="editor" class="ql-editor" contenteditable="true"></div></rich-textarea>
<button id="send" aria-label="Send message">发送</button>
<div id="log"></div>
<button id="stop" aria-label="Stop response" hidden>停止</button>
<script>
(function () {
  'use strict';
  const cfg = Object.assign(
    { heading: __HEADING__, full: __FULL__, stopHideMs: 1000, fullAfterMs: 11000 },
    window.__FIXTURE__ || {},
  );
  const editor = document.getElementById('editor');
  const send = document.getElementById('send');
  const stop = document.getElementById('stop');
  const log = document.getElementById('log');

  function put(html) {
    log.insertAdjacentHTML('beforeend', html);
    return log.lastElementChild;
  }

  send.addEventListener('click', function () {
    const prompt = editor.innerText || editor.textContent || '';
    if (!prompt.trim()) return;
    editor.replaceChildren();
    const user = put('<user-query></user-query>');
    user.textContent = prompt;
    const response = put(
      '<model-response><message-content></message-content><div class="toolbar"></div></model-response>'
    );
    const body = response.querySelector('message-content');
    const toolbar = response.querySelector('.toolbar');
    body.textContent = cfg.heading;
    stop.hidden = false;
    window.sawStop = true;
    setTimeout(function () {
      stop.hidden = true;
      window.stopGoneAt = Date.now();
    }, cfg.stopHideMs);
    setTimeout(function () {
      body.textContent = cfg.full;
      toolbar.insertAdjacentHTML(
        'beforeend',
        '<gem-icon-button data-test-id="regenerate-button" aria-label="重新生成">重新生成</gem-icon-button>'
      );
      window.completedAt = Date.now();
    }, cfg.fullAfterMs);
  });
})();
</script>"""


def page_bytes() -> bytes:
    return (
        PAGE.replace("__HEADING__", json.dumps(HEADING, ensure_ascii=False))
        .replace("__FULL__", json.dumps(FULL_BODY, ensure_ascii=False))
        .encode("utf-8")
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(self.server.payload)

    def log_message(self, *_):
        pass


def handle(page, payload):
    return page.evaluate("(payload) => window.__arenaWebDriver.handle(payload)", payload)


def open_page(ctx, base):
    page = ctx.new_page()
    page.goto(base + "/")
    page.add_script_tag(path=str(DRIVER))
    return page


def message(base, task_id, kind="read", prompt=None, options=None):
    payload = {
        "type": f"arena.web.{kind}",
        "taskId": task_id,
        "selectors": ADAPTER["selectors"],
        "options": options if options is not None else ADAPTER["options"],
        "scope": {
            "origin": base,
            "homeHref": base + "/",
            "allowNavigation": ADAPTER["allowNavigation"],
        },
    }
    if prompt is not None:
        payload["prompt"] = prompt
    return payload


def main(out: Path | None) -> int:
    assert ADAPTER["options"].get("requireDoneMarker") is True, ADAPTER
    done = ADAPTER["selectors"].get("done") or []
    assert any("regenerate-button" in css for css in done), done
    base_options = dict(ADAPTER["options"])
    base_options.update({"sampleMs": 150, "stableSamples": 3, "stableMs": 400, "pollMs": 60})
    default_options = dict(base_options)
    default_options["requireDoneMarker"] = False
    prompt = "请给出明确判断，并说明主要理由与适用条件。"

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.payload = page_bytes()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    results = {}

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                executable_path=str(find_chromium_executable()),
            )
            ctx = browser.new_context()

            # 1) requireDoneMarker: heading + vanished stop stays pending
            page = open_page(ctx, base)
            submitted = handle(
                page, message(base, "t-gem-marker", "submit", prompt, base_options)
            )
            assert submitted["status"] == "submitted", submitted

            page.wait_for_function("() => window.stopGoneAt !== undefined", timeout=10000)
            visible_stop = page.evaluate(
                """() => (() => {
                  const stop = document.getElementById('stop');
                  const rect = stop.getBoundingClientRect();
                  return !stop.hidden && (rect.width > 0 || rect.height > 0);
                })()"""
            )
            assert visible_stop is False, visible_stop
            assert page.evaluate("() => window.completedAt === undefined") is True

            reads = [
                handle(page, message(base, "t-gem-marker", "read", None, base_options))
                for _ in range(4)
            ]
            for index, read in enumerate(reads):
                assert read["status"] == "pending", (index, read)
                assert "text" not in read, (index, read)
                detail = read.get("detail") or {}
                assert detail.get("reason") in (
                    "answer-updating",
                    "completion-signal-missing",
                ), (index, read)
                assert detail.get("requireDoneMarker") is True, (index, read)
                preview = detail.get("preview") or {}
                assert preview.get("text") == HEADING, (index, read)
            assert (
                sum(
                    1
                    for read in reads
                    if read["detail"].get("reason") == "completion-signal-missing"
                )
                >= 3
            ), reads
            assert any((read["detail"].get("sawGenerating") is True) for read in reads), reads
            assert page.evaluate("() => window.sawStop === true") is True
            assert page.evaluate("() => window.completedAt === undefined") is True, (
                "sampling must not wait for the finished control"
            )
            results["heading_only_pending_reads"] = len(reads)

            # 2) once the finished control exists, the full body is saved
            page.wait_for_function("() => window.completedAt !== undefined", timeout=20000)
            final = None
            for _ in range(12):
                candidate = handle(
                    page, message(base, "t-gem-marker", "read", None, base_options)
                )
                if candidate["status"] == "done":
                    final = candidate
                    break
            assert final is not None, candidate
            assert final["text"] == FULL_BODY, final
            evidence = (final.get("detail") or {}).get("evidence")
            assert evidence == "done-marker", final
            results["full_body_after_done_marker"] = True
            page.close()

            # 3) default sites keep the stop-observed rule
            page = open_page(ctx, base)
            submitted = handle(
                page,
                message(base, "t-gem-default", "submit", prompt, default_options),
            )
            assert submitted["status"] == "submitted", submitted
            page.wait_for_function("() => window.stopGoneAt !== undefined", timeout=10000)
            legacy = None
            for _ in range(8):
                candidate = handle(
                    page, message(base, "t-gem-default", "read", None, default_options)
                )
                if candidate["status"] == "done":
                    legacy = candidate
                    break
            assert legacy is not None, candidate
            assert legacy["text"] == HEADING, legacy
            evidence = (legacy.get("detail") or {}).get("evidence")
            assert evidence == "stop-observed", legacy
            results["default_stop_observed_kept"] = True
            page.close()

            browser.close()
            print(json.dumps(results, ensure_ascii=False, indent=2))
            if out is not None:
                out.mkdir(parents=True, exist_ok=True)
                (out / "gemini-completion.json").write_text(
                    json.dumps(results, ensure_ascii=False, indent=2)
                )
    finally:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    raise SystemExit(main(args.out.resolve() if args.out else None))
