#!/usr/bin/env python3
"""Explore the Arena workspace with Bombadil and a real MV3 backend."""

import argparse
import asyncio
import hashlib
import json
import mimetypes
import signal
from pathlib import Path
from tempfile import TemporaryDirectory

from playwright.async_api import async_playwright

from browser_acceptance import REPO_ROOT, extension_id_from_path, find_chromium_executable

ORIGIN = "http://127.0.0.1:8765"
WORKSPACE = f"{ORIGIN}/workspace.html"
BRIDGE = """(origin) => {
  if (location.origin !== origin) return;
  Object.defineProperty(window.chrome, 'runtime', { value: {
    id: 'arena-bombadil',
    sendMessage(message, callback) {
      arenaTestMessage(message).then(callback, (error) => callback({ ok: false, error: error.message }));
    },
  } });
}"""


def check_live_session(session, live_dir):
    providers = {"chatgpt", "gemini", "deepseek"}
    if session["stage"] != "done" or set(session["providers"]) != providers:
        raise ValueError("Saved backend session has no three-seat final report")
    history = {entry["id"]: entry for entry in session["history"]}
    for path in (live_dir / "requests").glob("*.json"):
        task = json.loads(path.read_text(encoding="utf-8"))
        reply = json.loads((live_dir / "replies" / path.name).read_text(encoding="utf-8"))
        entry = history[task["id"]]
        if (
            entry["status"] != "answered" or entry["provider"] != task["provider"]
            or entry["prompt"] != task["prompt"] or entry["answer"] != reply["text"].strip()
            or entry.get("stance") != reply.get("stance")
        ):
            raise ValueError(f"Saved transcript differs from handoff file {path.name}")

    independent = [task for task in history.values() if task["stage"] == "independent"]
    if len(independent) != 3 or len({task["prompt"] for task in independent}) != 1:
        raise ValueError("Seats did not receive the same independent prompt")
    for task in history.values():
        if task["stage"] == "critique" and task["round"] == 1:
            for peer in independent:
                if peer["provider"] != task["provider"] and peer["answer"] not in task["prompt"]:
                    raise ValueError(f"Peer material missing from {task['id']}")
    for version in {task["version"] for task in history.values() if task["stage"] == "vote"}:
        votes = [task for task in history.values() if task["stage"] == "vote" and task["version"] == version]
        if {vote["provider"] for vote in votes} != providers or len({vote["proposalDigest"] for vote in votes}) != 1:
            raise ValueError(f"Missing or inconsistent votes for candidate v{version}")
    if not any(task["stage"] == "vote" for task in history.values()):
        raise ValueError("Saved discussion has no votes")


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--reproduce", type=Path)
    parser.add_argument("--ext", type=Path, default=REPO_ROOT / "extension")
    parser.add_argument("--live-dir", type=Path, help="Private handoff directory for real model replies")
    args = parser.parse_args()
    extension = args.ext.resolve()
    executable = find_chromium_executable()
    extension_url = f"chrome-extension://{extension_id_from_path(extension)}/workspace.html"
    live = args.live_dir.resolve() if args.live_dir else None
    spec = Path(__file__).with_name("bombadil_live.js" if live else "bombadil_workbench.js")
    finished = asyncio.Event()

    if live:
        live.mkdir(mode=0o700, parents=True, exist_ok=True)
        (live / "requests").mkdir()
        (live / "replies").mkdir()

    async def live_exchange(route, endpoint):
        request = route.request
        if endpoint == "outcome" and request.method == "POST":
            (live / "outcome.json").write_text(request.post_data or "", encoding="utf-8")
            await route.fulfill(status=204)
            finished.set()
            return
        if endpoint == "requests" and request.method == "POST":
            for task in request.post_data_json:
                key = hashlib.sha256(task["id"].encode()).hexdigest()[:20]
                path = live / "requests" / f"{key}.json"
                task["promptSha256"] = hashlib.sha256(task["prompt"].encode()).hexdigest()
                if path.exists():
                    assert json.loads(path.read_text()) == task, f"Task {key} changed"
                else:
                    temporary = path.with_suffix(".tmp")
                    temporary.write_text(json.dumps(task, ensure_ascii=False), encoding="utf-8")
                    temporary.replace(path)
            await route.fulfill(status=204)
            return
        if endpoint == "replies" and request.method == "GET":
            replies = []
            for path in sorted((live / "replies").glob("*.json")):
                task_path = live / "requests" / path.name
                task = json.loads(task_path.read_text(encoding="utf-8"))
                reply = json.loads(path.read_text(encoding="utf-8"))
                if reply.get("promptSha256") != task["promptSha256"] or not reply.get("text", "").strip():
                    raise ValueError(f"Invalid reply for {path.stem}")
                if task["stage"] == "逐席确认" and reply.get("stance") not in {"agree", "conditional", "oppose"}:
                    raise ValueError(f"Vote {path.stem} requires an explicit stance")
                replies.append({**reply, "id": task["id"]})
            await route.fulfill(json=replies)
            return
        await route.fulfill(status=404)

    async def serve(route):
        url = route.request.url
        if not url.startswith(f"{ORIGIN}/"):
            await route.abort()
            return
        relative = url.removeprefix(f"{ORIGIN}/").split("?", 1)[0]
        if live and relative.startswith("__arena-live/"):
            await live_exchange(route, relative.removeprefix("__arena-live/"))
            return
        path = (extension / relative).resolve()
        if path.is_relative_to(extension) and path.is_file():
            content_type = mimetypes.guess_type(path)[0] or "application/octet-stream"
            await route.fulfill(path=path, content_type=content_type)
        else:
            await route.fulfill(status=404, body="Fixture not found")

    with TemporaryDirectory(prefix="arena-bombadil-") as profile:
        async with async_playwright() as playwright:
            context = await playwright.chromium.launch_persistent_context(
                profile,
                channel="chromium",
                executable_path=str(executable) if executable else None,
                args=[
                    f"--disable-extensions-except={extension}",
                    f"--load-extension={extension}",
                    "--remote-debugging-port=0",
                    "--remote-debugging-address=127.0.0.1",
                    "--disable-background-networking",
                    "--no-proxy-server",
                    "--host-resolver-rules=MAP * ~NOTFOUND",
                ],
            )
            process = None
            try:
                control = context.pages[0]
                await control.goto(extension_url)
                await control.locator("#question-input").wait_for()

                async def relay(source, message):
                    if source["frame"].url.split("#", 1)[0] != WORKSPACE:
                        raise ValueError("Unexpected message origin")
                    if message.get("type") not in {"list", "get", "create", "act", "automation.info"}:
                        raise ValueError("Unexpected test operation")
                    return await control.evaluate(
                        "message => chrome.runtime.sendMessage(message)", message
                    )

                await context.expose_binding("arenaTestMessage", relay)
                await context.add_init_script(f"({BRIDGE})({json.dumps(ORIGIN)})")
                await context.route("http*://**/*", serve)
                port = (Path(profile) / "DevToolsActivePort").read_text().splitlines()[0]
                command = [
                    "bombadil", "browser", "test-external", "--create-target",
                    "--remote-debugger", f"http://127.0.0.1:{port}",
                    "--chrome-grant-permissions=", "--instrument-javascript=",
                    "--width", str(args.width), "--height", "800",
                    "--output-path", str(args.trace.resolve()),
                ]
                if args.reproduce:
                    command.extend(("--reproduce", str(args.reproduce.resolve())))
                else:
                    command.extend(("--time-limit", f"{args.seconds}s", "--exit-on-violation"))
                process = await asyncio.create_subprocess_exec(
                    *command, WORKSPACE, str(spec)
                )
                if not live:
                    return await asyncio.wait_for(process.wait(), args.seconds + 40)

                process_done = asyncio.create_task(process.wait())
                outcome_seen = asyncio.create_task(finished.wait())
                try:
                    await asyncio.wait(
                        {process_done, outcome_seen}, timeout=args.seconds + 15,
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    if not finished.is_set():
                        return process.returncode or 1
                    # The outcome came from an observed report state in Bombadil.
                    # Let the browser action return to the trace, then stop polling.
                    await asyncio.sleep(0.5)
                    if process.returncode is None:
                        process.send_signal(signal.SIGINT)
                    await asyncio.wait_for(process_done, timeout=10)
                    if process.returncode not in (0, 130, -signal.SIGINT):
                        return process.returncode

                    outcome = json.loads((live / "outcome.json").read_text())
                    report_page = await context.new_page()
                    await report_page.goto(f"{extension_url}#s={outcome['id']}")
                    await report_page.locator("#report-title").wait_for()
                    session = await report_page.evaluate(
                        "id => chrome.runtime.sendMessage({type: 'get', id}).then(r => r.session)",
                        outcome["id"],
                    )
                    (live / "session.json").write_text(
                        json.dumps(session, ensure_ascii=False, indent=2), encoding="utf-8"
                    )
                    # Read the Blob made by the native export button. Bombadil takes over
                    # the browser-wide destination, so a Playwright download can be empty.
                    await report_page.evaluate("""() => {
                      const create = URL.createObjectURL;
                      URL.createObjectURL = function (blob) {
                        if (blob.type.startsWith("text/markdown")) {
                          window.arenaExport = blob.text();
                          URL.createObjectURL = create;
                        }
                        return create.call(URL, blob);
                      };
                    }""")
                    await report_page.get_by_role("button", name="导出 Markdown", exact=True).first.click()
                    exported = await report_page.evaluate("() => window.arenaExport")
                    check_live_session(session, live)
                    if not exported or session["question"] not in exported or any(
                        entry["sourceId"] not in exported for entry in session["history"] if entry.get("sourceId")
                    ):
                        raise ValueError("Native Markdown export is empty or missing discussion sources")
                    (live / "report.md").write_text(exported, encoding="utf-8")
                    print(f"Live acceptance exported {live / 'report.md'}", flush=True)
                    return 0
                finally:
                    outcome_seen.cancel()
            finally:
                if process and process.returncode is None:
                    process.terminate()
                    await process.wait()
                await context.close()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
