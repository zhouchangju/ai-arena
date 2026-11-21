#!/usr/bin/env python3
"""Focused real-browser regression for G1–G4 UX repairs.

Covers:

1. A skipped seat says "已跳过，本轮不计入结论" instead of promising that a
   late answer can be added. An existing local draft stays visible and
   copyable as a read-only "未提交的草稿", before and after a reload, and after
   the stage advances into archived history. The draft never enters the
   session, the report or the exported Markdown.
2. The recalled-pair hint tells the truth: change requires deselecting a seat
   first; the "two seats max" error appears only after a real third click.
3. With the editor and "更多操作" both open, a card exposes exactly one
   "跳过这一席" button.
4. A new draft collapses and resumes intact. Clearing a vote draft resets
   both its text and stance, while cancel preserves both.

Runs the unpacked extension in an isolated Chromium profile (no login, no
external HTTP(S)). Run from the repository root:

    python3 tests/ux_repairs.py

Exit code 0 means every check passed.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import browser_acceptance as ba  # noqa: E402  (shared launch/UI helpers, no installs)
from playwright.sync_api import (  # noqa: E402
    Error as PlaywrightError,
    TimeoutError as PlaywrightTimeoutError,
    sync_playwright,
)

CHECKS: list[dict[str, Any]] = []
DRAFT_TOKEN = "DRAFT-SKIP-7f3a 这段草稿只能只读留存，绝不能进入结论。"


def check(name: str, ok: bool, detail: str = "") -> None:
    CHECKS.append({"name": name, "ok": bool(ok), "detail": detail})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


def shot(page, out: Path, name: str) -> None:
    try:
        page.screenshot(path=str(out / f"{name}.png"), full_page=False)
    except PlaywrightError:
        pass


def session_visible(page) -> bool:
    try:
        return page.locator(".session-head").count() > 0
    except PlaywrightError:
        return False


def reopen(page, ui, question: str) -> None:
    """Reload the workspace and make sure the created session is on screen."""
    page.reload(wait_until="domcontentloaded")
    try:
        ba.wait_until(lambda: session_visible(page), "session view after reload", timeout=6.0)
    except ba.AcceptanceError:
        ui.open_history(question)
        ba.wait_until(lambda: session_visible(page), "session view from history", timeout=6.0)


def visible_skip_count(card) -> int:
    return card.locator(".skip-row button").evaluate_all(
        "els => els.filter(e => e.textContent.trim() === '跳过这一席' "
        "&& (e.offsetWidth || e.offsetHeight || e.getClientRects().length)).length"
    )


def draft_block(card):
    """The read-only unsubmitted-draft details on a skipped card/history entry."""
    blocks = card.locator("details.prompt-box").filter(has_text="未提交的草稿")
    return blocks.first if blocks.count() else None


def expand_details(node) -> None:
    if node is not None and not node.evaluate("el => el.open"):
        node.locator("summary").first.click(timeout=2000)


def card_for_task(ui, task: dict[str, Any]):
    return ui.task_card(task)


def check_draft_editor(page, ui, runtime):
    print("\n[3] Collapse and clear answer drafts")
    page.locator("#new-session").click()
    for provider_id in ui.selection_snapshot()["pressed"]:
        ui.select_provider(ui.by_id[provider_id])
    session_id, _ = ui.create_debate("草稿回归：是否先验证需求？", ["chatgpt", "claude"])
    seat = runtime.get(session_id)["tasks"][0]
    card = ui.open_task_editor(seat)
    field = card.locator("textarea.answer-input")
    clear = card.get_by_role("button", name="清除草稿", exact=True)
    check("Empty editor has no clear action", not clear.is_visible())
    field.fill(DRAFT_TOKEN)
    check("First draft exposes clear without changing focus",
          clear.is_visible() and field.evaluate("el => el === document.activeElement"))
    card.get_by_role("button", name="收起", exact=True).click()
    resume = card.get_by_role("button", name="继续草稿", exact=True)
    collapsed = not field.is_visible() and resume.is_visible()
    check("First draft collapses immediately", collapsed)
    if collapsed:
        resume.click()
    check("Reopening restores the draft exactly", field.input_value() == DRAFT_TOKEN)
    field.fill("")
    check("Manually emptying text hides clear", not clear.is_visible())
    card.get_by_role("button", name="收起", exact=True).click()
    check("Empty editor collapses with a fresh start", not field.is_visible() and not resume.is_visible())

    answers = {seat: "先验证使用频率，依据 [S1] 和 [S2]。" for seat in ("chatgpt", "claude")}
    for stage in ("independent", "critique", "proposal"):
        ui.answer_stage(session_id, stage, answers)
    vote = ui.wait_for_stage(session_id, "vote")["tasks"][0]
    card = ui.open_task_editor(vote)
    field = card.locator("textarea.answer-input")
    clear = card.get_by_role("button", name="清除草稿", exact=True)
    picked = card.locator(".stance-btn[aria-pressed=true]")
    card.get_by_role("button", name="反对", exact=True).click()
    check("Selecting a stance alone exposes clear", clear.is_visible())
    field.fill(DRAFT_TOKEN)
    page.reload()
    card.locator(".stance-btn").first.wait_for()
    check("Reload restores both reason and stance",
          field.input_value() == DRAFT_TOKEN and picked.inner_text() == "反对")

    dialog = page.locator("dialog.confirm")
    clear.click()
    confirmation = dialog.locator(".confirm-body").inner_text()
    check("Vote clear dialog names both fields", "立场" in confirmation and "理由" in confirmation)
    dialog.get_by_role("button", name="取消", exact=True).click()
    check("Cancel preserves both reason and stance",
          field.input_value() == DRAFT_TOKEN and picked.inner_text() == "反对")
    clear.click()
    dialog.get_by_role("button", name="清除草稿", exact=True).click()
    check("Confirm resets reason, stance and clear action",
          field.input_value() == "" and picked.count() == 0 and not clear.is_visible())

    field.fill("仍待验证。")
    card.get_by_role("button", name="记录表态", exact=True).click()
    check("Reason alone cannot submit the cleared stance",
          card.locator(".task-error").is_visible()
          and runtime.get(session_id)["tasks"][0]["status"] == "pending")


def main() -> int:
    parser = argparse.ArgumentParser(description="Focused UX repair regression (real Chromium)")
    parser.add_argument("--ext", help="extension directory (defaults to <repo>/extension)")
    parser.add_argument("--out", help="directory for screenshots (defaults to a temp dir)")
    parser.add_argument("--headed", action="store_true", help="show the Chromium window")
    args = parser.parse_args()

    try:
        ext_dir = ba.find_extension_dir(args.ext)
    except ba.AcceptanceError as exc:
        print(f"Not ready: {exc}", file=sys.stderr)
        return 2

    manifest = json.loads((ext_dir / "manifest.json").read_text(encoding="utf-8"))
    ui_path = ba.manifest_ui_path(ext_dir, manifest)
    providers = ba.read_providers(ext_dir)
    by_id = {provider.provider_id: provider for provider in providers}
    required = ["chatgpt", "claude", "gemini"]
    missing = [pid for pid in required if pid not in by_id]
    if missing:
        print(f"Providers {missing} are not declared in {ext_dir / 'providers.js'}", file=sys.stderr)
        return 2

    out_dir = Path(args.out).expanduser().resolve() if args.out else Path(tempfile.mkdtemp(prefix="ai-arena-ux-repairs-"))
    out_dir.mkdir(parents=True, exist_ok=True)
    profile_dir = Path(tempfile.mkdtemp(prefix="ai-arena-profile-"))
    attempts: list[str] = []
    question = "修复验收：跳过后的草稿还看得见吗？沿用上次两席又该怎么换人？"
    page_errors: list[str] = []
    console_errors: list[str] = []
    failure: Optional[BaseException] = None

    print("AI Arena UX repair regression")
    print(f"  extension: {ext_dir}")
    print(f"  output:    {out_dir}")

    with sync_playwright() as playwright:
        executable = ba.find_chromium_executable()
        context = playwright.chromium.launch_persistent_context(
            user_data_dir=str(profile_dir),
            headless=not args.headed,
            accept_downloads=True,
            executable_path=str(executable) if executable else None,
            args=[
                f"--disable-extensions-except={ext_dir}",
                f"--load-extension={ext_dir}",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-component-update",
                "--disable-background-networking",
                "--disable-sync",
                "--metrics-recording-only",
                "--no-proxy-server",
            ],
        )
        ba.install_network_guard(context, attempts)
        context.set_default_timeout(12000)

        try:
            try:
                worker = context.wait_for_event("serviceworker", timeout=15000)
                extension_id = worker.url.split("/")[2]
            except PlaywrightTimeoutError:
                extension_id = ba.extension_id_from_path(ext_dir)

            page = context.new_page()
            page.on("pageerror", lambda error: page_errors.append(str(error)))
            page.on("console", lambda message: console_errors.append(message.text) if message.type == "error" else None)
            page.goto(f"chrome-extension://{extension_id}/{ui_path.lstrip('/')}", wait_until="domcontentloaded", timeout=20000)
            runtime = ba.Runtime(page)
            ui = ba.WorkspaceUI(page, providers, runtime)

            # ---------------------------------------------------------------
            # Setup: two real seats.
            # ---------------------------------------------------------------
            session_id, _ = ui.create_debate(question, ["chatgpt", "claude"])
            ba.wait_until(lambda: session_visible(page), "session view after create", timeout=6.0)

            # ---------------------------------------------------------------
            # 2. Recalled pair hint and changing the recalled pair.
            # ---------------------------------------------------------------
            print("\n[2] Recalled pair hint and change")
            page.click("#new-session")
            status = page.locator(".home-seat-status")
            ba.wait_until(lambda: status.count() > 0, "home seat status", timeout=5.0)
            status_text = status.inner_text(timeout=3000)
            check(
                "Recalled hint names the pair and the real change path",
                "沿用上次的" in status_text
                and "ChatGPT" in status_text
                and "Claude" in status_text
                and "换人先点一下已选的 AI" in status_text
                and "改选直接点其他成员" not in status_text,
                status_text.strip(),
            )
            shot(page, out_dir, "01_recalled_pair_hint")

            error = page.locator(".inline-error")
            check(
                "No generic two-seat error before a third click",
                not error.is_visible(),
                error.inner_text(timeout=1000) if error.count() else "",
            )

            ui.select_provider(by_id["gemini"])
            ba.wait_until(lambda: error.is_visible(), "third-seat error", timeout=4.0)
            error_text = error.inner_text(timeout=2000)
            check(
                "Third click shows an actionable deselect-first error",
                "先点一下已选的 AI" in error_text and "已选两席" in error_text,
                error_text.strip(),
            )
            selected = ui.selection_snapshot()
            check(
                "Third click does not replace a recalled seat",
                sorted(selected["pressed"]) == ["chatgpt", "claude"],
                str(selected["pressed"]),
            )

            ui.select_provider(by_id["chatgpt"])  # deselect, per the hint
            ba.wait_until(lambda: not error.is_visible(), "error clears after deselect", timeout=4.0)
            ui.select_provider(by_id["gemini"])
            changed = ui.selection_snapshot()
            check(
                "Deselect then click really changes the recalled pair",
                sorted(changed["pressed"]) == ["claude", "gemini"] and "2 / 2" in changed["counter"],
                f"{changed['pressed']} · {changed['counter']}",
            )

            # Return to the created session without starting a new one.
            runtime_get = runtime.get(session_id)
            check("Session still intact after pair edit", runtime_get.get("question") == question, str(runtime_get.get("question")))
            ui.open_history(question)
            ba.wait_until(lambda: session_visible(page), "session view from history", timeout=6.0)

            # ---------------------------------------------------------------
            # 1a. Draft on an open editor: exactly one skip; skip keeps draft.
            # ---------------------------------------------------------------
            print("\n[1a] Skip a seat with an existing draft")
            session = runtime.get(session_id)
            seat_a = next(task for task in session["tasks"] if task["provider"] == "chatgpt")
            seat_b = next(task for task in session["tasks"] if task["provider"] == "claude")

            card = ui.open_task_editor(seat_a)
            textarea = card.locator("textarea.answer-input")
            textarea.fill(DRAFT_TOKEN)
            check("Draft is written locally before skip", textarea.input_value() == DRAFT_TOKEN, DRAFT_TOKEN[:24])

            check(
                "Editor alone exposes one skip button",
                visible_skip_count(card) == 1,
                f"visible={visible_skip_count(card)}",
            )
            card.locator("details.task-more summary").click(timeout=3000)
            ba.wait_until(lambda: card.locator("details.task-more[open]").count() == 1, "more actions open", timeout=3.0)
            check(
                "Editor + more actions still expose exactly one skip button",
                visible_skip_count(card) == 1,
                f"visible={visible_skip_count(card)}",
            )
            shot(page, out_dir, "02_editor_and_more_actions_one_skip")

            card.locator(".skip-row button").first.click(timeout=3000)
            dialog = page.locator("dialog.confirm")
            ba.wait_until(lambda: dialog.is_visible(), "skip confirmation", timeout=4.0)
            confirm_body = dialog.locator(".confirm-body").inner_text(timeout=2000)
            check(
                "Skip confirmation states effect and existing draft",
                "不计入结论" in confirm_body
                and "未提交的草稿" in confirm_body
                and "不会删除" in confirm_body
                and "不能再提交" in confirm_body,
                confirm_body.strip(),
            )
            shot(page, out_dir, "03_skip_confirmation")
            dialog.locator("button", has_text="跳过这一席").click(timeout=3000)

            ba.wait_until(
                lambda: next(
                    (task for task in runtime.get(session_id).get("tasks", []) if task.get("id") == seat_a["id"]),
                    {},
                ).get("status") == "skipped",
                "seat marked skipped",
                timeout=6.0,
            )
            skipped_task = next(
                task for task in runtime.get(session_id)["tasks"] if task["id"] == seat_a["id"]
            )
            card = card_for_task(ui, skipped_task)
            card_text = card.inner_text(timeout=3000)
            check(
                "Skipped card no longer promises a late answer",
                "已跳过，本轮不计入结论" in card_text and "可以补录" not in card_text,
                card_text.splitlines()[-6:],
            )
            check("Skipped card has no resubmit textarea", card.locator("textarea").count() == 0, "")
            draft = draft_block(card)
            check("Skipped card exposes a read-only unsubmitted draft", draft is not None, "")
            if draft is not None:
                check(
                    "Draft block is labelled read-only and not counted",
                    "只读" in draft.inner_text(timeout=2000) and "不计入结论" in draft.inner_text(timeout=2000),
                    draft.inner_text(timeout=2000).splitlines()[0],
                )
                expand_details(draft)
                pre = draft.locator("pre.prompt-text")
                check(
                    "Draft original text is visible",
                    pre.count() == 1 and pre.inner_text(timeout=2000).strip() == DRAFT_TOKEN,
                    pre.inner_text(timeout=2000)[:40] if pre.count() else "",
                )
                copy_button = draft.get_by_role("button", name="复制草稿原文")
                check("Draft has a copy control", copy_button.count() == 1, "")
                copy_button.click(timeout=3000)
                ba.wait_until(
                    lambda: "已复制草稿原文" in page.locator("#toast").inner_text(timeout=1000),
                    "draft copy toast",
                    timeout=4.0,
                )
                check("Draft copy reports success", "已复制草稿原文" in page.locator("#toast").inner_text(timeout=1000), "")
            shot(page, out_dir, "04_skipped_card_with_draft")

            stored_keys = page.evaluate(
                "() => Object.keys(JSON.parse(localStorage.getItem('aiArena.workspace.drafts.v1') || '{}'))"
            )
            check(
                "Skip keeps the existing local draft key",
                any(seat_a["id"] in key for key in stored_keys),
                str(stored_keys),
            )
            blob = json.dumps(runtime.get(session_id), ensure_ascii=False)
            check("Draft never becomes accepted session evidence", DRAFT_TOKEN not in blob, "session JSON excludes the draft token")

            # ---------------------------------------------------------------
            # 1b. Reload while still in the same stage.
            # ---------------------------------------------------------------
            print("\n[1b] Reload, then advance and reload again")
            reopen(page, ui, question)
            session = runtime.get(session_id)
            skipped_task = next(task for task in session["tasks"] if task["id"] == seat_a["id"])
            card = card_for_task(ui, skipped_task)
            draft = draft_block(card)
            check("Draft survives a reload on the skipped card", draft is not None, "")
            if draft is not None:
                expand_details(draft)
                pre = draft.locator("pre.prompt-text")
                check(
                    "Reloaded draft text is intact",
                    pre.count() == 1 and pre.inner_text(timeout=2000).strip() == DRAFT_TOKEN,
                    pre.inner_text(timeout=2000)[:40] if pre.count() else "",
                )
            check("Reloaded skipped card is still read-only", card.locator("textarea").count() == 0, "")
            shot(page, out_dir, "05_draft_after_reload")

            # ---------------------------------------------------------------
            # 1c. Advance the stage: draft moves with the archived history.
            # ---------------------------------------------------------------
            seat_b = next(task for task in runtime.get(session_id)["tasks"] if task["id"] == seat_b["id"])
            ui.answer_task(session_id, seat_b, "席 B 的正常回答原文：这段回答可以被采用。", stage="independent")
            ba.wait_until(
                lambda: runtime.get(session_id).get("stage") != "independent",
                "stage advances after the other seat answers",
                timeout=10.0,
            )
            session = runtime.get(session_id)
            archived = next(
                (entry for entry in session.get("history", []) if entry.get("id") == seat_a["id"]),
                None,
            )
            check(
                "Skipped seat is archived with an empty answer",
                archived is not None
                and archived.get("stage") == "independent"
                and archived.get("status") == "skipped"
                and not (archived.get("answer") or "").strip(),
                json.dumps(archived, ensure_ascii=False)[:220] if archived else "missing",
            )
            check(
                "Draft is not part of archived accepted evidence",
                DRAFT_TOKEN not in json.dumps(session, ensure_ascii=False),
                "session JSON excludes the draft token",
            )

            reopen(page, ui, question)
            ba.wait_until(lambda: page.locator(".history-section").count() == 1, "history section", timeout=6.0)
            history_item = page.locator(".timeline-item").filter(has_text="这一席在这一阶段缺席").first
            check("Archived skipped entry is visible after reload", history_item.count() == 1, "")
            draft = draft_block(history_item)
            check("Archived history retains the read-only draft", draft is not None, "")
            if draft is not None:
                expand_details(draft)
                pre = draft.locator("pre.prompt-text")
                check(
                    "Archived draft original text is readable",
                    pre.count() == 1 and pre.inner_text(timeout=2000).strip() == DRAFT_TOKEN,
                    pre.inner_text(timeout=2000)[:40] if pre.count() else "",
                )
                check(
                    "Archived draft offers no rerun or resubmit control",
                    history_item.locator("textarea").count() == 0
                    and history_item.get_by_role("button", name="继续草稿").count() == 0
                    and history_item.get_by_role("button", name="粘贴回答").count() == 0
                    and history_item.get_by_role("button", name="补录回答").count() == 0,
                    "",
                )
                copy_button = draft.get_by_role("button", name="复制草稿原文")
                check("Archived draft is copyable", copy_button.count() == 1, "")
            shot(page, out_dir, "06_draft_in_archived_history")

            # Narrow viewport: same read-only recovery.
            page.set_viewport_size({"width": 420, "height": 900})
            reopen(page, ui, question)
            narrow_item = page.locator(".timeline-item").filter(has_text="这一席在这一阶段缺席").first
            narrow_draft = draft_block(narrow_item)
            check("Narrow viewport still shows the archived draft", narrow_draft is not None, "")
            if narrow_draft is not None:
                expand_details(narrow_draft)
                narrow_pre = narrow_draft.locator("pre.prompt-text")
                check(
                    "Narrow draft text stays readable",
                    narrow_pre.count() == 1 and narrow_pre.inner_text(timeout=2000).strip() == DRAFT_TOKEN,
                    "",
                )
            shot(page, out_dir, "07_narrow_archived_draft")
            page.set_viewport_size({"width": 1280, "height": 900})

            # ---------------------------------------------------------------
            # 1d. Report and exported Markdown still exclude the draft.
            # ---------------------------------------------------------------
            finished = runtime.ok({"type": "act", "id": session_id, "action": "finish"}).get("session") or {}
            report = str(finished.get("report") or "")
            check("Finish produces a report", len(report.strip()) > 0, f"{len(report)} chars")
            check("Report excludes the unsubmitted draft", DRAFT_TOKEN not in report, "report text excludes the draft token")

            reopen(page, ui, question)
            export_path, exported = ui.export_markdown(out_dir)
            check("Exported Markdown excludes the unsubmitted draft", DRAFT_TOKEN not in exported, str(export_path))

            check_draft_editor(page, ui, runtime)
        except BaseException as exc:  # keep the failure visible after the browser closes
            failure = exc
        finally:
            context.close()

    check("No uncaught page errors", not page_errors, "; ".join(page_errors[:3]))
    check("No console errors", not console_errors, "; ".join(console_errors[:3]))
    check("No external HTTP(S) attempts", not attempts, str(attempts[:3]))

    passed = sum(1 for item in CHECKS if item["ok"])
    print(f"\n{passed}/{len(CHECKS)} checks passed")
    print(f"screenshots: {out_dir}")
    if failure is not None:
        print(f"FAILED: {failure}", file=sys.stderr)
        return 1
    return 0 if passed == len(CHECKS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
