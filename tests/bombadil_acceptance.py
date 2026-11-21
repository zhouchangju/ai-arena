#!/usr/bin/env python3
"""Explore the Arena workspace with Bombadil and a real MV3 backend."""

import argparse
import asyncio
import json
import mimetypes
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


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--reproduce", type=Path)
    parser.add_argument("--ext", type=Path, default=REPO_ROOT / "extension")
    args = parser.parse_args()
    extension = args.ext.resolve()
    executable = find_chromium_executable()
    extension_url = f"chrome-extension://{extension_id_from_path(extension)}/workspace.html"
    spec = Path(__file__).with_name("bombadil_workbench.js")

    async def serve(route):
        url = route.request.url
        if not url.startswith(f"{ORIGIN}/"):
            await route.abort()
            return
        path = (extension / url.removeprefix(f"{ORIGIN}/").split("?", 1)[0]).resolve()
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
                return await asyncio.wait_for(process.wait(), args.seconds + 40)
            finally:
                if process and process.returncode is None:
                    process.terminate()
                    await process.wait()
                await context.close()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
