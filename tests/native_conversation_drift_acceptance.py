#!/usr/bin/env python3
"""Exercise an actual same-origin, same-document conversation drift in the app.

Gemini's loopback page finishes its first answer, then changes only its address
to a stable second route with a genuine ``history.pushState``.  That is the SPA
case a site produces without a navigation request; the app must notice the
address change, return to the saved conversation, restore the answer read-only,
finish the discussion, and never send this round (or any later round) into the
second route.

The route change is deliberately made when the first answer has completed and
the page is idle.  A route change while A is still streaming must leave the
live generation alone; the separate pure-pane check covers that busy case, and
the full-navigation lock is covered by
``native_independent_conversation_acceptance.py``.

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
    drift_events = []
    turns = {seat: [] for seat in PROVIDERS}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlparse(self.path).path
            seat = path.strip("/").split("-")[0]
            if path == "/gemini-b":
                # A full navigation here would mean the lock was bypassed. Serve
                # a page so a failure is diagnosable, but the assertions expect
                # this route to stay unvisited.
                with lock:
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
            with lock:
                gets.append(path)
                saved_turns = list(turns[seat])
            page = markup(PROVIDERS.index(seat)).decode()
            # Report every send-control click, including the second route.
            seat_literal = json.dumps(seat)
            page = page.replace(
                "window.turns.push(row);",
                "window.turns.push(row);"
                "fetch('/observed',{method:'POST',body:JSON.stringify("
                "{kind:'prompt',seat:" + seat_literal + ",path:location.pathname,prompt})});",
            )
            # Gemini's first saved page changes only its address once its first
            # answer is complete. A real ``history.pushState`` keeps the same
            # document and does not ask WebKit for B; the app must notice the
            # URL change and return to the saved conversation. Do not arm the
            # reload after recovery: its restored first turn is not re-sent.
            if seat == "gemini" and not saved_turns:
                page = page.replace(
                    "row.complete=true;stop.remove();",
                    "row.complete=true;stop.remove();"
                    "if(seq===1&&window.__arenaDriftArmed){"
                    "window.__arenaDriftArmed=false;"
                    "history.pushState({},'','/gemini-b');"
                    "fetch('/observed',{method:'POST',body:JSON.stringify("
                    "{kind:'drift',path:location.pathname})})}",
                    1,
                )
                page += "<script>window.__arenaDriftArmed=true;</script>"
            # Restore server-known turns with literals only: fixtures.markup
            # already expanded its own placeholders.
            content, user_html, answer_html, body_selector, done_html = HTML[PROVIDERS.index(seat)]
            page += f"""<script>
const SAVED={json.dumps(saved_turns, ensure_ascii=False)};
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
            length = int(self.headers.get("Content-Length", "0"))
            event = json.loads(self.rfile.read(length))
            with lock:
                events.append(event)
                if event.get("kind") == "prompt":
                    seat = event["seat"]
                    turns[seat].append({
                        "prompt": event["prompt"],
                        "answer": canned_answer(event["prompt"]),
                    })
                elif event.get("kind") == "drift":
                    drift_events.append(event["path"])
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
        (out / "drift-events.json").write_text(json.dumps(drift_events, indent=2))
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
    assert drift_events == ["/gemini-b"], drift_events
    # The address change must stay same-document: no GET of the second route.
    assert gets.count("/gemini-b") == 0, gets
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
