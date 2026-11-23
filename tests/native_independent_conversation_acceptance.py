#!/usr/bin/env python3
"""Prove one Arena seat never follows another conversation on its own site.

The built app drives three loopback provider pages (A) while a *separate*,
fresh headless Chromium profile acts as the person using those same sites.  For
every provider that profile sends two unrelated private messages: one in a
second conversation (B) and one in a third conversation (C).  The fixture's
A page polls for that change and tries ``location.assign(B/C)`` exactly as a
site-side SPA or a link would.

The app must keep every automatic seat on its bound A conversation:

* six outside messages are recorded from the personal browser;
* six A-page navigation attempts happen and none becomes an app GET of B/C;
* no Arena prompt or answer is ever produced by a B/C page;
* ten normal deliveries reach A, and each saved row belongs to the same seat
  and round that produced it;
* the private marker never reaches the saved session, its store files, or the
  Markdown export.

All pages are loopback fixtures.  No real site, account or personal profile is
used; evidence is written below ``--out`` (normally /tmp).

Run against a built QA app:

    python3 tests/native_independent_conversation_acceptance.py \
        --app desktop/build/"AI Arena.app" --out /tmp/arena-independent

Use ``--baseline`` only to reproduce the old failure: it stops after asserting
that the app did fetch an outside conversation.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from playwright.sync_api import sync_playwright
except ImportError as error:  # pragma: no cover - environment guard
    raise SystemExit(
        "Playwright is required for the separate personal browser: "
        f"{error}. Install the Python package; this test never installs a browser."
    )

from fixtures import PROVIDERS, find_chromium_executable, markup
from qa_app import stage_qa_app


def normalized(text: str) -> str:
    return " ".join(text.split())


def stage_hint(prompt: str) -> str:
    """The fixture prompt is self-describing; use it to check the saved row."""
    if "这是独立作答轮" in prompt:
        return "independent"
    if "本轮是交叉质询" in prompt:
        return "critique"
    if "【起草任务】" in prompt:
        return "proposal"
    if "明确表态" in prompt or "STANCE:" in prompt:
        return "vote"
    return "unknown"


def arena_page(index: int) -> bytes:
    """The bound conversation A, with observation hooks and a drift trigger."""
    page = markup(index).decode()
    page = page.replace(
        "window.turns.push(row);",
        "window.turns.push(row);"
        "fetch('/arena',{method:'POST',body:JSON.stringify("
        "[location.pathname.slice(1),location.pathname,prompt])});",
    )
    page += """
<script>
const arenaSeat = location.pathname.slice(1);
let lastSignal = '';
setInterval(async () => {
  try {
    const dest = await (await fetch('/signal/' + arenaSeat)).json();
    if (dest && dest !== lastSignal) {
      lastSignal = dest;
      await fetch('/attempt', { method: 'POST',
        body: JSON.stringify([arenaSeat, dest, location.pathname]) });
      location.assign(dest);
    }
  } catch (error) { /* the app may be navigating; the next poll retries */ }
}, 100);
</script>"""
    return page.encode()


def outside_page(index: int) -> bytes:
    """Another conversation on the same site, plus the person's own composer."""
    page = markup(index).decode()
    page = page.replace(
        "window.turns.push(row);",
        "window.turns.push(row);"
        "fetch('/outside-send',{method:'POST',body:JSON.stringify("
        "{path:location.pathname,prompt})});",
    )
    page = page.replace(
        "answer.textContent=row.text;",
        "answer.textContent=row.text;"
        "if(row.complete)fetch('/outside-answer',{method:'POST',body:JSON.stringify("
        "{path:location.pathname,answer:row.text})});",
    )
    page += """
<textarea id="other"></textarea>
<button id="external-send" type="button">Send</button>
<script>
document.querySelector('#external-send').addEventListener('click', () => {
  fetch('/external', { method: 'POST',
    body: JSON.stringify([location.pathname,
      document.querySelector('#other').value]) });
});
</script>"""
    return page.encode()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--baseline", action="store_true",
                        help="reproduce the old behaviour and expect an outside GET")
    args = parser.parse_args()

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    result = out / "result.json"
    if result.exists():
        raise FileExistsError(f"Choose a fresh evidence directory: {out}")

    origin_holder: dict[str, str] = {}
    marker = "PRIVATE-QA-" + uuid.uuid4().hex[:10]
    lock = threading.Lock()
    requests: list[tuple[str, bool]] = []
    foreign: list[str] = []
    external: list[list[str]] = []
    attempts: list[list[str]] = []
    arena: list[list[str]] = []
    outside_send: list[dict] = []
    outside_answer: list[dict] = []
    signals: dict[str, str] = {}

    def record(bucket: list, value) -> None:
        with lock:
            bucket.append(value)

    def signal_for(seat: str) -> str:
        with lock:
            return signals.get(seat, "")

    class Handler(BaseHTTPRequestHandler):
        def reply(self, body: bytes, kind: str = "text/html") -> None:
            self.send_response(200)
            self.send_header("Content-Type", kind + "; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path.startswith("/signal/"):
                seat = path.strip("/").split("/", 1)[1]
                self.reply(json.dumps(signal_for(seat)).encode(), "application/json")
                return
            seat = path.strip("/").split("-")[0]
            if seat not in PROVIDERS:
                self.send_error(404)
                return
            personal = self.headers.get("X-QA-Personal") == "yes"
            record(requests, (path, personal))
            index = PROVIDERS.index(seat)
            if "-" in path.strip("/"):
                # B/C are another conversation on the same site.  Only the
                # person's separate browser should ever load them.
                if not personal:
                    record(foreign, path)
                self.reply(outside_page(index))
                return
            self.reply(arena_page(index))

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            try:
                payload = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                self.send_error(400)
                return
            if self.path == "/external":
                path, text = payload
                record(external, [path, text])
                seat = path.strip("/").split("-")[0]
                with lock:
                    signals[seat] = path
            elif self.path == "/attempt":
                record(attempts, payload)
            elif self.path == "/arena":
                record(arena, payload)
            elif self.path == "/outside-send":
                record(outside_send, payload)
            elif self.path == "/outside-answer":
                record(outside_answer, payload)
            else:
                self.send_error(404)
                return
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_port}"
    origin_holder["origin"] = origin

    chromium = find_chromium_executable()
    if chromium is None:
        server.shutdown()
        server.server_close()
        raise RuntimeError(
            "No local Chromium found. Set PLAYWRIGHT_CHROMIUM_EXECUTABLE to an "
            "already-installed browser; this test never downloads one."
        )

    data = out / "data"
    app_log = out / "app.log"
    restore_log = out / "restore.log"
    process: subprocess.Popen | None = None
    session: dict | None = None

    def snapshot() -> dict:
        with lock:
            return {
                "requests": len(requests),
                "foreign": list(foreign),
                "external": len(external),
                "attempts": list(attempts),
                "arena": len(arena),
                "outsideSend": list(outside_send),
                "outsideAnswer": list(outside_answer),
            }

    def wait_for(predicate, timeout: float, message: str) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if process is not None and process.poll() is not None:
                raise AssertionError(
                    f"{message}; app exited {process.returncode}: {snapshot()}"
                )
            time.sleep(0.05)
        raise AssertionError(f"{message}; ledger={snapshot()}")

    try:
        with stage_qa_app(args.app, out / "qa-app") as qa, \
             sync_playwright() as pw:
            browser = pw.chromium.launch(
                executable_path=str(chromium), headless=True
            )
            # new_context() is an empty, in-memory profile: no cookies, history
            # or extensions from any personal browser are reused.
            context = browser.new_context(
                extra_http_headers={"X-QA-Personal": "yes"}
            )
            personal = {seat: context.new_page() for seat in PROVIDERS}
            env = {
                **os.environ,
                "ARENA_FIXTURE_BASE": origin,
                "ARENA_DATA_DIR": str(data),
                "ARENA_SMOKE_RESULT": str(result),
                "ARENA_SMOKE_TIMEOUT": "170",
                "ARENA_TRACE_STATUS": "1",
            }
            with app_log.open("w") as log:
                process = subprocess.Popen(
                    [str(qa.executable), "--smoke-test"],
                    env=env, stdout=log, stderr=log,
                )

            def bound() -> bool:
                text = app_log.read_text(errors="replace")
                return all(f"independent {seat} generating" in text
                           for seat in PROVIDERS)

            wait_for(bound, 90, "the app never bound all three seats")

            for seat in PROVIDERS:
                page = personal[seat]
                for suffix in ("b", "c"):
                    path = f"/{seat}-{suffix}"
                    page.goto(origin + path, wait_until="domcontentloaded")
                    page.fill("#other", marker + seat + suffix)
                    with page.expect_response(
                        lambda response: response.url == origin + "/external",
                        timeout=15_000,
                    ):
                        page.click("#external-send")
                    # Wait for the app's A page to observe this signal and try
                    # to follow it, so each message maps to one attempt.
                    wait_for(
                        lambda path=path: any(item[1] == path for item in attempts),
                        10,
                        f"the Arena page never tried to follow {path}",
                    )

            if args.baseline:
                time.sleep(0.8)
                assert foreign, snapshot()
                print("BASELINE: the app followed an outside conversation:", foreign)
                return 0

            process.wait(timeout=200)
            if process.returncode != 0:
                raise AssertionError(
                    f"app exited {process.returncode}; see {app_log}"
                )

            session = json.loads(result.read_text())
            history = session.get("history", [])
            assert session.get("stage") == "done", session.get("stage")
            assert len(history) == 10, len(history)
            assert all(row.get("status") == "answered" for row in history), history

            personal_messages = sorted(external)
            expected_external = sorted(
                [f"/{seat}-{suffix}", marker + seat + suffix]
                for seat in PROVIDERS for suffix in ("b", "c")
            )
            assert personal_messages == expected_external, personal_messages
            assert len(attempts) == 6, attempts
            assert {item[1] for item in attempts} == {
                f"/{seat}-{suffix}" for seat in PROVIDERS for suffix in ("b", "c")
            }, attempts
            assert all(item[2] == item[1].rsplit("-", 1)[0] for item in attempts), attempts
            assert foreign == [], foreign
            assert outside_send == [], outside_send
            assert outside_answer == [], outside_answer

            assert len(arena) == 10, arena
            assert all(item[1] == f"/{item[0]}" for item in arena), arena

            by_seat: dict[str, list[dict]] = {
                seat: [row for row in history if row.get("provider") == seat]
                for seat in PROVIDERS
            }
            sent_by_seat: dict[str, list[list[str]]] = {
                seat: [item for item in arena if item[0] == seat]
                for seat in PROVIDERS
            }
            for seat in PROVIDERS:
                rows = by_seat[seat]
                sent = sent_by_seat[seat]
                assert len(sent) == len(rows) and rows, (seat, sent, rows)
                for item, row in zip(sent, rows):
                    assert item[2] == row.get("prompt"), (seat, item, row)
                    assert stage_hint(row.get("prompt", "")) == row.get("stage"), (
                        seat, row.get("stage"), row.get("prompt", ""),
                    )
                    assert row.get("round") == 1, row
                stages = [row.get("stage") for row in rows]
                assert stages[0] == "independent", (seat, stages)
                assert stages[1] == "critique", (seat, stages)
                assert stages[-1] == "vote", (seat, stages)
                assert stages == sorted(stages, key=["independent", "critique",
                                                     "proposal", "vote"].index), (
                    seat, stages,
                )
                assert stages.count("proposal") <= 1, (seat, stages)

            proposals = [row for row in history if row.get("stage") == "proposal"]
            votes = [row for row in history if row.get("stage") == "vote"]
            assert len(proposals) == 1, proposals
            assert len(votes) == 3, votes
            versions = {row.get("version") for row in votes}
            assert len(versions) == 1 and None not in versions, versions
            assert all(row.get("stance") == "agree" for row in votes), votes
            assert len({row.get("proposalDigest") for row in votes}) == 1, votes
            assert proposals[0].get("version") in versions, (proposals, versions)

            session_id = session.get("id")
            assert session_id, session
            durable_path = data / f"{session_id}.json"
            assert durable_path.exists(), durable_path
            durable = json.loads(durable_path.read_text())
            (out / "durable-session.json").write_text(
                json.dumps(durable, ensure_ascii=False, indent=2)
            )
            page_urls = durable.get("pageURLs", {})
            assert all(
                page_urls.get(seat, "").endswith(f"/{seat}") for seat in PROVIDERS
            ), page_urls

            # A read-only restore run uses the same serializer as the native
            # Save panel and records the complete Markdown export.
            with lock:
                signals.clear()
            restored = out / "restored.json"
            with restore_log.open("w") as log:
                subprocess.run(
                    [str(qa.executable), "--smoke-test", "--smoke-restore"],
                    env={**env, "ARENA_SMOKE_RESULT": str(restored)},
                    stdout=log, stderr=log, timeout=120, check=True,
                )
            assert json.loads(restored.read_text()) == session

            exported = (out / "export.md").read_text()
            assert session.get("report") in exported
            for row in history:
                assert row["prompt"] in exported, row
            assert marker not in exported, "private marker reached the Markdown export"

            assert marker not in json.dumps(session, ensure_ascii=False)
            for saved in data.rglob("*.json"):
                assert marker not in saved.read_text(errors="replace"), saved

            assert all(
                page.locator("#other").input_value() == marker + seat + "c"
                for seat, page in personal.items()
            )

            print(
                "PASS: three Arena seats stayed on their bound conversations; "
                "6 outside messages, 6 blocked A-page navigations, 10 correct "
                "seat/round deliveries, no outside prompt or private marker in "
                "the session or Markdown export"
            )
            return 0
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        server.shutdown()
        server.server_close()
        with lock:
            ledger = {
                "origin": origin_holder.get("origin", ""),
                "marker": marker,
                "requests": requests,
                "foreign": foreign,
                "external": external,
                "attempts": attempts,
                "arena": arena,
                "outsideSend": outside_send,
                "outsideAnswer": outside_answer,
                "sessionStage": (session or {}).get("stage", ""),
                "history": len((session or {}).get("history", [])),
            }
        (out / "ledger.json").write_text(
            json.dumps(ledger, ensure_ascii=False, indent=2)
        )
        (out / "events.json").write_text(
            json.dumps(
                {
                    "external": external,
                    "attempts": attempts,
                    "arena": arena,
                    "outsideSend": outside_send,
                    "outsideAnswer": outside_answer,
                },
                ensure_ascii=False,
                indent=2,
            )
        )


if __name__ == "__main__":
    raise SystemExit(main())
