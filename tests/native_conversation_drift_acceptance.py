#!/usr/bin/env python3
"""Exercise an actual same-origin conversation drift in the native app.

Gemini's loopback page leaves its saved conversation for a stable second route
while its first answer is being read. The app must return to the saved
conversation automatically, restore the answer read-only, finish the
discussion, and never send this round (or any later round) into the second
route.

The QA bundle copy gets one scoped fixture-only patch in its packaged
``web-driver.js``: the driver's production read-recovery allowlist requires a
real HTTPS provider conversation, so a localhost fixture cannot rebuild a
read-only record after a full page reload. The patch only accepts
``http://127.0.0.1`` bindings and never touches ``shared/web-driver.js``; every
production allowlist stays unchanged.

Run with a built app:

    python3 tests/native_conversation_drift_acceptance.py --app <app> --out <dir>

All pages are local loopback fixtures. No real site, account or personal data
is used.
"""

import argparse
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from fixtures import HTML, PROVIDERS, markup
from qa_app import stage_qa_app


def canned_answer(prompt: str) -> str:
    if "STANCE:" in prompt:
        return "服务端恢复的表态段落。\nSTANCE: agree"
    if "起草候选" in prompt:
        return "服务端恢复的候选段落。\n建议先验证检索。[S1]"
    return "服务端恢复的首轮回答。\n测试结论。"


def patch_qa_driver(qa_app: Path, port: int) -> None:
    """Allow only the exact loopback fixture conversation read-only rebuild.

    This is a scoped exception in the disposable QA copy: the production
    allowlist (shared/web-driver.js) stays untouched. It requires the same
    exact scope.href/origin the original guard already verified, an http
    127.0.0.1 host (not a string prefix), this run's port, and /gemini.
    """
    driver = qa_app / "Contents" / "Resources" / "web-driver.js"
    source = driver.read_text()
    marker = """    if (scope.homeHref) {
      const home = canonicalHref(scope.homeHref);
      if (home && home === canonical) return null;
    }
    return stableConversationHref(canonical);"""
    if marker not in source:
        raise AssertionError("stableReadBinding marker not found")
    exception = f"""    if (canonical === scope.href) {{
      const fixture = new URL(canonical);
      if (fixture.protocol === 'http:' && fixture.hostname === '127.0.0.1' &&
          fixture.port === '{port}' && fixture.pathname === '/gemini') return canonical;
    }}
"""
    source = source.replace(marker, exception + marker, 1)
    driver.write_text(source)
    # The ad-hoc signature covers resources; re-sign the disposable copy.
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(qa_app)], check=True)
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict",
         "-R", '=identifier "local.ai-arena.desktop.qa"', str(qa_app)],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    result = out / "result.json"
    if result.exists():
        raise FileExistsError(result)

    events = []
    gets = []
    turns = {seat: [] for seat in PROVIDERS}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlparse(self.path).path
            seat = path.strip("/").split("-")[0]
            if path == "/gemini-b":
                gets.append(path)
                page = markup(PROVIDERS.index("gemini")).decode().replace(
                    "window.turns.push(row);",
                    "window.turns.push(row);"
                    "fetch('/observed',{method:'POST',body:JSON.stringify("
                    "{kind:'prompt',seat:'gemini',path:location.pathname,prompt})});",
                )
                self.respond(page.encode())
                return
            if seat not in PROVIDERS:
                self.send_error(404)
                return
            gets.append(path)
            page = markup(PROVIDERS.index(seat)).decode()
            # Report every send-control click, including the second route.
            seat_literal = json.dumps(seat)
            page = page.replace(
                "window.turns.push(row);",
                "window.turns.push(row);"
                "fetch('/observed',{method:'POST',body:JSON.stringify("
                "{kind:'prompt',seat:" + seat_literal + ",path:location.pathname,prompt})});",
            )
            # Only Gemini's first saved page hands itself to the second route.
            if seat == "gemini" and not turns[seat]:
                page = page.replace(
                    "window.turns.push(row);",
                    "window.turns.push(row);"
                    "setTimeout(()=>location.assign('/gemini-b'),2500);",
                    1,
                )
            # Restore server-known turns with literals only: fixtures.markup
            # already expanded its own placeholders.
            content, user_html, answer_html, body_selector, done_html = HTML[PROVIDERS.index(seat)]
            page += f"""<script>
const SAVED={json.dumps(turns[seat], ensure_ascii=False)};
const USER_HTML={json.dumps(user_html)};
const ANSWER_HTML={json.dumps(answer_html)};
const BODY_SELECTOR={json.dumps(body_selector)};
const DONE_HTML={json.dumps(done_html)};
for (const turn of SAVED) {{
  log.insertAdjacentHTML('beforeend', USER_HTML);
  log.lastElementChild.textContent = turn.prompt;
  log.insertAdjacentHTML('beforeend', ANSWER_HTML);
  const article = log.lastElementChild;
  const body = article.matches(BODY_SELECTOR) ? article : article.querySelector(BODY_SELECTOR);
  body.textContent = turn.answer;
  if (DONE_HTML) article.insertAdjacentHTML('beforeend', DONE_HTML);
}}
</script>"""
            self.respond(page.encode())

        def respond(self, body):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != "/observed":
                self.send_error(404)
                return
            event = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            events.append(event)
            if event.get("kind") == "prompt":
                seat = event["seat"]
                turns[seat].append({
                    "prompt": event["prompt"],
                    "answer": canned_answer(event["prompt"]),
                })
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    durable = {}
    try:
        with stage_qa_app(args.app, out / "qa-app") as qa, tempfile.TemporaryDirectory() as data:
            patch_qa_driver(qa.app, server.server_port)
            with (out / "app.log").open("w") as log:
                proc = subprocess.run(
                    [qa.executable, "--smoke-test"],
                    env={
                        **os.environ,
                        "ARENA_FIXTURE_BASE": f"http://127.0.0.1:{server.server_port}",
                        "ARENA_DATA_DIR": data,
                        "ARENA_SMOKE_RESULT": str(result),
                        "ARENA_SMOKE_TIMEOUT": "170",
                    },
                    stdout=log, stderr=log, timeout=200,
                )
            if result.exists():
                payload = json.loads(result.read_text())
                session_id = (payload.get("session") or payload).get("id")
                saved = Path(data) / f"{session_id}.json"
                if saved.exists():
                    durable = json.loads(saved.read_text())
                    (out / "durable-session.json").write_text(json.dumps(durable, ensure_ascii=False, indent=2))
    finally:
        server.shutdown()
        server.server_close()
        (out / "requests.json").write_text(json.dumps(gets, indent=2))
        (out / "events.json").write_text(json.dumps(events, ensure_ascii=False, indent=2))

    payload = json.loads(result.read_text())
    assert proc.returncode == 0, payload
    session = payload.get("session", payload)
    assert session.get("stage") == "done", payload

    history = session.get("history", [])
    assert history and all(row.get("status") == "answered" for row in history), history
    gemini_rows = [row for row in history if row.get("provider") == "gemini"]
    assert gemini_rows, history

    prompts = [event for event in events if event.get("kind") == "prompt"]
    gemini_prompts = [event for event in prompts if event.get("seat") == "gemini"]
    assert len(gemini_prompts) == len(gemini_rows), (gemini_prompts, len(gemini_rows))
    assert all(event["path"] != "/gemini-b" for event in prompts), prompts
    assert gets.count("/gemini-b") == 1, gets
    assert gets.count("/gemini") >= 2, gets

    first_prompt = gemini_prompts[0]["prompt"]
    first_row = gemini_rows[0]
    assert first_row["prompt"] == first_prompt, (first_row, first_prompt)
    assert first_row["answer"] == canned_answer(first_prompt), (first_row["answer"], canned_answer(first_prompt))

    page_urls = durable.get("pageURLs", {})
    assert page_urls.get("gemini", "").endswith("/gemini"), page_urls
    assert "/gemini-b" not in page_urls.get("gemini", ""), page_urls

    print(
        "PASS: Gemini returned from a same-origin drift, restored the answer read-only, "
        "completed the discussion, and sent every prompt exactly once into the saved conversation"
    )


if __name__ == "__main__":
    main()
