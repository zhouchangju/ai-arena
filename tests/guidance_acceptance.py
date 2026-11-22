#!/usr/bin/env python3
"""Real Chromium acceptance for R03 user guidance and the compound handoff.

G1/G2  The condition is saved while paused, attributed to its stage and round,
       and reaches both seats' newly created critique prompt verbatim.
G3     Existing prompts stay byte-for-byte unchanged across save and reload.
G4     The condition survives persistence, the report and the Markdown export;
       one compound copy/open click copies the real prompt and opens one tab.

Run from the repository root; nothing is installed or written to the repo:

    python3 tests/guidance_acceptance.py [--headed] [--out /tmp/arena-guide]

Exit code 0 means every check passed. Uses only the Chromium already installed
for Playwright (``browser_acceptance.find_chromium_executable``).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import time
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError, sync_playwright

from browser_acceptance import (
    AcceptanceError,
    Runtime,
    extension_id_from_path,
    find_chromium_executable,
    first_visible,
    wait_until,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
EXT_DIR = REPO_ROOT / "extension"
PROVIDERS = ["chatgpt", "claude"]
COMPOUND = re.compile(r"复制提示并打开原页")
GUIDE_LABEL = "要补充的条件"


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""), flush=True)
    if not ok:
        raise AcceptanceError(f"{name}: {detail}" if detail else name)


def provider_tabs(page):
    """Backend-created tabs are invisible to context.pages; ask the extension's tabs API."""
    return page.evaluate(
        "async () => (await chrome.tabs.query({}))"
        ".filter(t => (t.pendingUrl || t.url || '').startsWith('https://chatgpt.com/'))"
        ".map(({ id, windowId, openerTabId, groupId, active, url, pendingUrl }) => "
        "({ id, windowId, openerTabId, groupId, active, address: pendingUrl || url }))"
    )


def button(page, name: str):
    return page.get_by_role("button", name=name, exact=True).first


def guide_box(page):
    try:
        locator = page.get_by_label(re.compile(re.escape(GUIDE_LABEL))).first
        if locator.count() and locator.is_visible():
            return locator
    except PlaywrightError:
        pass
    locator = first_visible(page, [
        "#guide-input",
        "textarea.guide-input",
        f"textarea[aria-label*='{GUIDE_LABEL}']",
        "textarea[data-role='guidance']",
    ])
    if locator is None:
        raise AcceptanceError("No visible guidance textarea")
    return locator


def open_session(page, base: str, session_id: str, question: str) -> None:
    page.goto(f"{base}/workspace.html#s={session_id}", wait_until="domcontentloaded", timeout=20000)
    # A fragment-only navigation does not re-run boot(); reload so the hash route loads.
    page.reload(wait_until="domcontentloaded")
    page.get_by_role("heading", name=re.compile(re.escape(question[:18]))).first.wait_for(timeout=12000)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--headed", action="store_true")
    parser.add_argument("--out", default="")
    args = parser.parse_args()
    out_dir = Path(args.out or tempfile.mkdtemp(prefix="ai-arena-guide-")).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    if REPO_ROOT.resolve() in out_dir.parents:
        raise SystemExit("Refusing to write acceptance artifacts inside the repository.")
    profile = tempfile.mkdtemp(prefix="ai-arena-guide-profile-")
    question = "ARENA_GUIDE_QUESTION 个人笔记工具是否先做移动端？"
    note = f"ARENA_GUIDE_NOTE_{int(time.time())} 只有一周实测移动采集不少于三次才接受移动端优先"
    marker = f"ARENA_CLI_MARKER_{int(time.time())}"
    attempts: list[str] = []

    with sync_playwright() as playwright:
        executable = find_chromium_executable()
        context = playwright.chromium.launch_persistent_context(
            profile,
            headless=not args.headed,
            accept_downloads=True,
            executable_path=str(executable) if executable else None,
            args=[
                f"--disable-extensions-except={EXT_DIR}",
                f"--load-extension={EXT_DIR}",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-background-networking",
                "--disable-sync",
                "--no-proxy-server",
                # Block DNS even if Chromium starts an extension-created tab before routing attaches.
                "--host-resolver-rules=MAP * ~NOTFOUND",
            ],
        )
        context.route("https://chatgpt.com/**", lambda route: (
            attempts.append(route.request.url),
            route.fulfill(status=200, content_type="text/html", body="<title>mock chatgpt</title>ok"),
        ))
        worker = context.service_workers[0] if context.service_workers else context.wait_for_event("serviceworker", timeout=15000)
        ext_id = worker.url.split("/")[2] or extension_id_from_path(EXT_DIR)
        base = f"chrome-extension://{ext_id}"
        try:
            context.grant_permissions(["clipboard-read", "clipboard-write"])
        except PlaywrightError as exc:
            print(f"  [INFO] clipboard permission unavailable: {exc}", flush=True)
        page = context.new_page()
        page.goto(f"{base}/workspace.html", wait_until="domcontentloaded", timeout=20000)
        runtime = Runtime(page)

        created = runtime.ok({"type": "create", "question": question, "providers": PROVIDERS})["session"]
        sid = created["id"]
        open_session(page, base, sid, question)
        before = {task["id"]: task["prompt"] for task in created["tasks"]}
        check("Seeded session has two distinct immutable independent prompts",
              len(before) == 2 and all(question in prompt for prompt in before.values()), json.dumps(list(before.values()))[:120])

        button(page, "暂停").click()
        wait_until(lambda: runtime.get(sid).get("paused"), "visible pause to persist")
        box = guide_box(page)
        box.fill(note)
        button(page, "保存条件").click()
        saved = wait_until(lambda: (lambda s: s if any(note in str(g.get("text")) for g in s.get("guidance") or []) else None)(runtime.get(sid)), "saved guidance")
        entry = next(g for g in saved["guidance"] if note in str(g.get("text")))
        check("Saved condition records its own text, stage and round",
              entry.get("stage") == "independent" and entry.get("round") == 1, json.dumps(entry, ensure_ascii=False)[:160])
        check("Saved condition does not rewrite the pending independent prompts",
              all(task.get("prompt") == prompt for task in saved["tasks"] for prompt in [before.get(task["id"])]), "independent prompts unchanged")
        page.screenshot(path=str(out_dir / "01_guidance_saved.png"))

        button(page, "继续讨论").click()
        wait_until(lambda: not runtime.get(sid).get("paused"), "visible resume")
        for task in saved["tasks"]:
            runtime.ok({"type": "act", "id": sid, "action": "answer",
                        "payload": {"taskId": task["id"], "text": f"ARENA_ANSWER_{task['provider']} 先验证采集频次。"}})
        critique = wait_until(lambda: (lambda s: s if s.get("stage") == "critique" else None)(runtime.get(sid)), "critique stage")
        check("Both newly created critique prompts carry the exact saved condition",
              len(critique["tasks"]) == 2 and all(note in task.get("prompt", "") for task in critique["tasks"]), "condition present in both seats")
        old = [t for t in critique.get("history") or [] if t.get("stage") == "independent"]
        check("Archived independent prompts remain byte-for-byte identical",
              len(old) == 2 and all(t.get("prompt") == before.get(t["id"]) and note not in t.get("prompt", "") for t in old), "history prompts unchanged")

        page.reload(wait_until="domcontentloaded")
        page.locator("article.seat-card").first.wait_for(timeout=12000)
        check("Saved condition is visible again after reload",
              note in page.locator("body").inner_text(timeout=4000), "condition text rendered")
        finished = runtime.ok({"type": "act", "id": sid, "action": "finish"})["session"]
        check("Final report contains the user condition", note in str(finished.get("report") or ""), "report text")
        page.reload(wait_until="domcontentloaded")
        page.get_by_role("heading", name=re.compile(re.escape(question[:18]))).first.wait_for(timeout=12000)
        with page.expect_download() as download:
            button(page, "导出 Markdown").click()
        exported = Path(download.value.path()).read_text(encoding="utf-8")
        check("Markdown export contains the user condition", note in exported, f"{len(exported)} chars")

        seeded = runtime.ok({"type": "create", "question": f"{question}（交接）", "providers": PROVIDERS})["session"]
        open_session(page, base, seeded["id"], f"{question}（交接）")
        task = next(t for t in seeded["tasks"] if t["provider"] == "chatgpt")
        card = page.locator("article.seat-card").filter(has_text="chatgpt").first
        compound = card.get_by_role("button", name=COMPOUND)
        check("Pending manual seat exposes one compound copy/open button", compound.count() == 1, f"matches={compound.count()}")
        source = page.evaluate("""async () => {
            const { id, windowId } = await chrome.tabs.getCurrent();
            const groupId = await chrome.tabs.group({ tabIds: id });
            return { id, windowId, groupId };
        }""")
        page.bring_to_front()
        page.evaluate("text => navigator.clipboard.writeText(text)", marker)
        marker_written = page.evaluate("() => navigator.clipboard.readText()") == marker
        check("Clipboard marker round-trips before the compound click", marker_written, "marker readable")
        compound.first.click()
        opened = wait_until(lambda: provider_tabs(page), "compound click to open mock provider")
        check("Compound click opens the mock provider tab", len(opened) == 1, f"tabs={opened}")
        child = wait_until(
            lambda: next((tab for tab in provider_tabs(page) if tab["groupId"] == source["groupId"]), None),
            "provider tab to join the workbench Chrome tab group",
        )
        check("New provider keeps the workbench as opener in its Chrome window and group",
              child["windowId"] == source["windowId"] and child.get("openerTabId") == source["id"],
              f"source={source}, child={child}")
        page.bring_to_front()
        compound.first.click()
        reopened = wait_until(
            lambda: next((tab for tab in provider_tabs(page) if tab["active"]), None),
            "second compound click to activate the provider",
        )
        ids = [tab["id"] for tab in provider_tabs(page)]
        check("Two compound clicks reuse the first mock provider tab",
              ids == [child["id"]] and reopened["id"] == child["id"], f"tab_ids={ids}")
        other_window = page.evaluate("id => chrome.windows.create({ tabId: id })", child["id"])
        check("The existing provider tab is now bound from a different window",
              provider_tabs(page)[0]["windowId"] == other_window["id"] != source["windowId"],
              f"other_window={other_window['id']}")
        page.bring_to_front()
        compound.first.click()
        returned = wait_until(
            lambda: next((tab for tab in provider_tabs(page) if tab["windowId"] == source["windowId"]
                         and tab["groupId"] == source["groupId"] and tab["active"]), None),
            "off-window provider tab to return to the workbench",
        )
        check("Off-window binding returns the same page to its workbench and group",
              [tab["id"] for tab in provider_tabs(page)] == [child["id"]]
              and returned.get("openerTabId") == source["id"] and returned["address"] == reopened["address"],
              f"provider_tab={returned}")
        page.bring_to_front()
        copied = page.evaluate("() => navigator.clipboard.readText()")
        check("Compound click actually copied the stored prompt, not the CLI marker",
              copied == task["prompt"] and marker not in copied,
              f"marker_present={marker in copied}, chars={len(copied)}")
        page.screenshot(path=str(out_dir / "02_compound_handoff.png"), full_page=False)
        print(f"\nArtifacts: {out_dir}\nMock provider requests: {len(attempts)}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AcceptanceError as exc:
        print(f"ACCEPTANCE FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
