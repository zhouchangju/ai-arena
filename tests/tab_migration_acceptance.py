#!/usr/bin/env python3
"""G3: Verify the legacy tab log migration in one offline Chrome profile.

Run from the repository root: python3 tests/tab_migration_acceptance.py
The checkout must include commit 9749fda, the last revision with the tab logger.
"""

from __future__ import annotations

import io
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from playwright.sync_api import sync_playwright

from browser_acceptance import REPO_ROOT, Runtime, find_chromium_executable, wait_until


BASE_REVISION = "9749fda"
MIGRATION_KEY = "arena.migration.tabDebugCleanup.v1"
DEBUG_KEY = re.compile(r"dbg\.[0-9]{13}")
DEBUG_STEPS = {"get", "create-before", "created"}
OTHER_RECORDS = {
    "arena.ui": {"theme": "dark"},
    "dbg.preferences": {"step": "get"},
    "dbg.1795312800003": {"step": "another-feature"},
    "dbg.1795312800004.extra": {"step": "created"},
}
OLD_RECORDS = {
    "dbg.1795312800000": {"step": "get", "binding": 41, "url": "https://example.test/thread/one"},
    "dbg.1795312800001": {"step": "create-before", "targetUrl": "https://example.test/"},
    "dbg.1795312800002": {"step": "created", "id": 42, "pendingUrl": "https://example.test/thread/two"},
}


def debug_keys(records: dict) -> set[str]:
    return {
        key for key, value in records.items()
        if DEBUG_KEY.fullmatch(key) and isinstance(value, dict) and value.get("step") in DEBUG_STEPS
    }


def install_old_extension(root: Path) -> None:
    archive = subprocess.check_output(["git", "archive", BASE_REVISION, "extension/"], cwd=REPO_ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as package:
        package.extractall(root, filter="data")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="arena-tab-migration-") as temp, sync_playwright() as playwright:
        root = Path(temp).resolve()
        extension = root / "extension"
        install_old_extension(root)
        context = playwright.chromium.launch_persistent_context(
            root / "profile",
            executable_path=find_chromium_executable(),
            ignore_default_args=["--disable-extensions"],
            args=[
                f"--disable-extensions-except={extension}",
                f"--load-extension={extension}",
                "--disable-background-networking",
                "--no-proxy-server",
                "--host-resolver-rules=MAP * ~NOTFOUND",
            ],
        )
        try:
            context.route(re.compile(r"^https?://"), lambda route: route.abort())
            workers = context.service_workers
            worker = workers[0] if workers else context.wait_for_event("serviceworker", timeout=10_000)
            extension_id = worker.url.split("/")[2]
            workspace = f"chrome-extension://{extension_id}/workspace.html"
            page = context.new_page()
            page.goto(workspace, wait_until="domcontentloaded")
            runtime = Runtime(page)
            session = runtime.ok({
                "type": "create",
                "question": "G3 local persistence check",
                "providers": ["chatgpt", "claude"],
            })["session"]
            open_seat = {"type": "open", "id": session["id"], "provider": "chatgpt"}
            runtime.ok(open_seat)
            generated = debug_keys(page.evaluate("chrome.storage.local.get(null)"))
            assert generated, "The old extension did not generate any tab logs"
            page.evaluate("items => chrome.storage.local.set(items)", {**OTHER_RECORDS, **OLD_RECORDS})
            before = page.evaluate("chrome.storage.local.get(null)")
            assert all(before.get(key) == value for key, value in {**OTHER_RECORDS, **OLD_RECORDS}.items()), before
            assert MIGRATION_KEY not in before, before
            print(f"PASS baseline Chrome extension generated {len(generated)} tab logs", flush=True)

            # Reload the unpacked extension through the same Chrome control users click.
            shutil.rmtree(extension)
            shutil.copytree(REPO_ROOT / "extension", extension)
            manager = context.new_page()
            manager.goto("chrome://extensions")
            manager.locator("#devMode").click(timeout=5_000)
            manager.locator("extensions-item #dev-reload-button").click(timeout=5_000)
            page = context.new_page()

            def open_workbench() -> bool:
                page.goto(workspace, wait_until="domcontentloaded", timeout=2_000)
                return page.evaluate("chrome.runtime?.id") == extension_id

            wait_until(open_workbench, "workbench after Chrome extension reload")
            runtime = Runtime(page)
            runtime.list_sessions()

            def completed_records() -> dict | None:
                records = page.evaluate("chrome.storage.local.get(null)")
                return records if records.get(MIGRATION_KEY) is True else None

            after = wait_until(completed_records, "completed tab log migration")
            assert page.evaluate("chrome.runtime.id") == extension_id
            assert not debug_keys(after), after
            assert all(after.get(key) == value for key, value in OTHER_RECORDS.items()), after
            assert runtime.get(session["id"])["question"] == session["question"], session["id"]
            print("PASS migration removed the old logs, preserved unrelated records and reopened the saved debate", flush=True)

            runtime.ok(open_seat)
            runtime.ok(open_seat)
            assert not debug_keys(page.evaluate("chrome.storage.local.get(null)"))
            print("PASS subsequent provider opens generated no tab logs", flush=True)
        finally:
            context.close()


if __name__ == "__main__":
    main()
