#!/usr/bin/env python3
"""G1/G3/G4 isolated regression for three-seat reading and prompt receipts.

Run: python3 tests/seat_reading_acceptance.py [--out /tmp/arena-seat-reading]

Covers only the workspace layout change: three seats side by side on a wide
desktop, two/one on narrower screens, a short prompt excerpt with the exact
prompt behind it, a send status that needs a matching background receipt, and
the single-candidate layout. It uses synthetic replies and a disabled,
in-memory automation record; no site is opened and nothing is sent.
"""

from __future__ import annotations

import argparse
import tempfile
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from browser_acceptance import (
    REPO_ROOT,
    AcceptanceError,
    CheckLog,
    Runtime,
    WorkspaceUI,
    extension_id_from_path,
    find_chromium_executable,
    install_network_guard,
    read_providers,
)


QUESTION = "验收：三个周末如何安排笔记应用的故障复测？"
ANSWERS = {
    "chatgpt": "先核对桌面索引，记录复现次数。",
    "gemini": "分别记录同步延迟和采集失败。",
    "deepseek": "先验证采集端症状，再决定修复范围。",
}
STORE_KEY = "arena.automation.v1"


def grid_columns(page) -> int:
    return page.eval_on_selector(
        ".seat-grid",
        "el => getComputedStyle(el).gridTemplateColumns.split(' ').filter(Boolean).length",
    )


def card(page, task):
    return page.locator(f"article.seat-card[data-task-id='{task['id']}']")


def seed_receipt(page, session_id: str, task: dict, *, phase: str = "submitted") -> None:
    """Store one disabled run whose dispatch record belongs to this task only."""

    payload = {
        STORE_KEY: {
            "configs": {},
            "runs": {
                session_id: {
                    "id": session_id,
                    "enabled": False,
                    "completed": False,
                    "startedAt": int(time.time() * 1000),
                    "updatedAt": int(time.time() * 1000),
                    "stoppedAt": None,
                    "tabs": {},
                    "dispatch": {
                        str(task["id"]): {
                            "taskId": str(task["id"]),
                            "provider": task["provider"],
                            "phase": phase,
                            "bootId": "seat-reading-regression",
                            "stage": "independent",
                            "round": 1,
                            "voteInstruction": False,
                            "status": phase,
                            "at": int(time.time() * 1000),
                            "clickAttempted": True,
                        }
                    },
                    "seats": {},
                    "lastError": "",
                }
            },
        }
    }
    page.evaluate("payload => chrome.storage.local.set(payload)", payload)


def check_layout(page, ui: WorkspaceUI, session_id: str, checks: CheckLog, out: Path) -> None:
    session = ui.wait_for_stage(session_id, "independent")
    tasks = {task["provider"]: task for task in session["tasks"]}
    if len(tasks) != 3:
        raise AcceptanceError(f"Expected three independent seats, got {session['tasks']!r}")

    page.set_viewport_size({"width": 1440, "height": 900})
    page.locator(".seat-grid").wait_for()
    checks.check("A wide desktop shows all three seats in one row", grid_columns(page) == 3)
    page.screenshot(path=out / "three-seats-1440.png")

    page.set_viewport_size({"width": 1100, "height": 900})
    page.wait_for_timeout(150)
    checks.check("A mid-width window falls back to two columns", grid_columns(page) == 2)
    page.screenshot(path=out / "three-seats-1100.png")

    page.set_viewport_size({"width": 390, "height": 800})
    page.wait_for_timeout(150)
    narrow_columns = grid_columns(page)
    narrow_widths = page.evaluate("[document.documentElement.scrollWidth, innerWidth]")
    checks.check(
        "A narrow screen falls back to one column without horizontal overflow",
        narrow_columns == 1 and narrow_widths[0] <= narrow_widths[1],
        f"columns={narrow_columns}, scrollWidth={narrow_widths[0]}, innerWidth={narrow_widths[1]}",
    )
    page.screenshot(path=out / "three-seats-390.png")

    page.set_viewport_size({"width": 1440, "height": 900})
    first = tasks["chatgpt"]
    prompt = card(page, first).locator("details.prompt-box")
    excerpt = prompt.locator(".prompt-excerpt")
    status = prompt.locator(".prompt-status")
    checks.check(
        "The prompt entry starts with a visible short excerpt and a ready-to-send status",
        excerpt.is_visible()
        and len(excerpt.inner_text()) < len(first["prompt"])
        and status.inner_text() == "准备发送"
        and not prompt.evaluate("el => el.open"),
    )
    order = card(page, first).evaluate(
        """el => {
          const answer = el.querySelector('.answer-block, .answer-note');
          const actions = el.querySelector('.task-actions');
          return Boolean(answer && actions
            && (answer.compareDocumentPosition(actions) & Node.DOCUMENT_POSITION_FOLLOWING));
        }"""
    )
    checks.check("The answer slot reads directly after the prompt, before the action row", order)

    prompt.locator("summary").click()
    checks.check(
        "Opening the prompt shows the exact full text and hides the duplicate excerpt",
        prompt.locator("pre.prompt-text").is_visible()
        and prompt.locator("pre.prompt-text").text_content() == first["prompt"]
        and not excerpt.is_visible(),
    )
    page.screenshot(path=out / "prompt-full-1440.png")
    prompt.locator("summary").click()

    seed_receipt(page, session_id, first)
    page.reload(wait_until="domcontentloaded")
    page.locator(".seat-grid").wait_for()
    checks.check(
        "Only the task with a matching background receipt says it was sent",
        card(page, first).locator(".prompt-status").inner_text() == "已确认发送"
        and card(page, tasks["gemini"]).locator(".prompt-status").inner_text() == "准备发送"
        and card(page, tasks["deepseek"]).locator(".prompt-status").inner_text() == "准备发送",
    )
    page.screenshot(path=out / "receipt-1440.png")


def check_single_candidate(page, ui: WorkspaceUI, session_id: str, checks: CheckLog) -> None:
    ui.answer_stage(session_id, "independent", ANSWERS)
    ui.answer_stage(session_id, "critique", {
        "chatgpt": "先按你的复现记录安排。",
        "gemini": "保留采集中断的反例。",
        "deepseek": "修复范围要写清判定规则。",
    })
    proposal = ui.wait_for_stage(session_id, "proposal")
    if len(proposal["tasks"]) != 1:
        raise AcceptanceError(f"Expected one candidate task, got {proposal['tasks']!r}")
    page.locator(".seat-grid.is-single").wait_for()
    checks.check(
        "A one-seat candidate keeps the single-column layout and its prompt entry",
        grid_columns(page) == 1
        and page.locator("article.seat-card").count() == 1
        and page.locator("article.seat-card .prompt-status").inner_text() == "准备发送",
    )
    checks.check(
        "Earlier rounds remain in the history after the stage advances",
        page.locator(".timeline-item").count() >= 6,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    out = args.out.expanduser().resolve() if args.out else Path(tempfile.mkdtemp(prefix="arena-seat-reading-"))
    if out.is_relative_to(REPO_ROOT):
        raise AcceptanceError("Write acceptance artifacts outside the repository.")
    out.mkdir(parents=True, exist_ok=True)

    extension = REPO_ROOT / "extension"
    executable = find_chromium_executable()
    checks = CheckLog()
    attempts, errors = [], []

    with tempfile.TemporaryDirectory(prefix="arena-seat-reading-profile-") as profile, sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            profile,
            executable_path=str(executable) if executable else None,
            headless=True,
            viewport={"width": 1440, "height": 900},
            reduced_motion="reduce",
            args=[
                f"--disable-extensions-except={extension}",
                f"--load-extension={extension}",
                "--disable-background-networking",
                "--no-proxy-server",
                "--host-resolver-rules=MAP * ~NOTFOUND",
            ],
        )
        try:
            install_network_guard(context, attempts)
            page = context.new_page()
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.set_default_timeout(8000)
            page.goto(f"chrome-extension://{extension_id_from_path(extension)}/workspace.html")
            ui = WorkspaceUI(page, read_providers(extension), Runtime(page))
            session_id, _ = ui.create_debate(QUESTION, ["chatgpt", "gemini", "deepseek"])
            check_layout(page, ui, session_id, checks, out)
            check_single_candidate(page, ui, session_id, checks)
            checks.check("No external requests or workspace script errors", not attempts and not errors, str(attempts + errors))
        finally:
            context.close()

    print(f"\n{len(checks.checks)} checks passed. Artifacts: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
