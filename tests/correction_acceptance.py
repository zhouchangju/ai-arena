#!/usr/bin/env python3
"""Real-browser acceptance for the narrow "改正录入" correction path.

Covers only G1/G2/G3/G4 for one scoped gap: a manually relayed answer that
was accidentally pasted can be corrected *before* the rest of its independent
or critique round freezes.

The harness drives the real unpacked extension in an isolated Chromium profile
with external HTTP(S) blocked. It:

1. answers one seat through the visible UI and checks that "改正录入" is tucked
   inside that card's existing "更多操作", not shown as a front action;
2. opens the correction editor, checks it is prefilled with the saved text,
   corrects it, and verifies the card marks "已更正" while the other seat is
   still pending;
3. verifies the original text stays visible as provenance and that the backend
   still holds exactly one answer record for that seat;
4. answers the other seat and verifies the next-round prompt that reaches it
   contains the corrected text, never the replaced one;
5. reloads, opens the archived history entry, verifies "已更正" and the
   original text survive, and that the frozen entry offers no correction.

Run from the repository root (nothing is installed):

    python3 tests/correction_acceptance.py --out /tmp/ai-arena-correction

Exit code 0 means every check passed.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
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
ORIGINAL = "CORRECTION_ORIGINAL_4d2 我误粘贴的原文：先做完整移动端。"
CORRECTED = "CORRECTION_FIXED_8b1 更正后的原文：先用手机快捷入口验证采集频次。"
QUESTION = "验收：误粘贴的一席回答，能否在另一席还没提交前改正？"


def check(name: str, ok: bool, detail: str = "") -> None:
    CHECKS.append({"name": name, "ok": bool(ok), "detail": detail})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


def shot(page, out: Path, name: str) -> None:
    try:
        page.screenshot(path=str(out / f"{name}.png"), full_page=False)
    except PlaywrightError:
        pass


def open_details(node) -> None:
    """Expand a native <details> only when it is closed."""
    try:
        if node.count() == 0:
            return
        if node.first.evaluate("el => !!el.open"):
            return
        node.first.locator("summary").first.click(timeout=2500)
    except PlaywrightError:
        return


def main() -> int:
    parser = argparse.ArgumentParser(description="Real-Chromium correction acceptance")
    parser.add_argument("--ext", help="extension directory (defaults to <repo>/extension)")
    parser.add_argument("--out", help="directory for screenshots (defaults to a temp dir)")
    parser.add_argument("--headed", action="store_true")
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
    missing = [pid for pid in ("chatgpt", "claude") if pid not in by_id]
    if missing:
        print(f"Providers {missing} are not declared in {ext_dir / 'providers.js'}", file=sys.stderr)
        return 2

    out_dir = Path(args.out).expanduser().resolve() if args.out else Path(
        tempfile.mkdtemp(prefix="ai-arena-correction-")
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    profile_dir = Path(tempfile.mkdtemp(prefix="ai-arena-correction-profile-"))
    attempts: list[str] = []
    page_errors: list[str] = []
    failure: Optional[BaseException] = None

    print("AI Arena correction acceptance")
    print(f"  extension: {ext_dir}")
    print(f"  output:    {out_dir}")

    with sync_playwright() as playwright:
        executable = ba.find_chromium_executable()
        context = playwright.chromium.launch_persistent_context(
            user_data_dir=str(profile_dir),
            headless=not args.headed,
            accept_downloads=True,
            viewport={"width": 1280, "height": 900},
            device_scale_factor=2,
            color_scheme="light",
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
            page.goto(
                f"chrome-extension://{extension_id}/{ui_path.lstrip('/')}",
                wait_until="domcontentloaded",
                timeout=20000,
            )
            runtime = ba.Runtime(page)
            ui = ba.WorkspaceUI(page, providers, runtime)

            # ---------------------------------------------------------------
            # Setup: answer exactly one of two seats.
            # ---------------------------------------------------------------
            print("\n[1] One live answered seat")
            session_id, _ = ui.create_debate(QUESTION, ["chatgpt", "claude"])
            session = runtime.get(session_id)
            seat_a = next(task for task in session["tasks"] if task["provider"] == "chatgpt")
            ui.answer_task(session_id, seat_a, ORIGINAL)
            ba.wait_until(
                lambda: next(
                    (task for task in runtime.get(session_id)["tasks"] if task["id"] == seat_a["id"]),
                    {},
                ).get("status") == "answered",
                "first answer saved",
                timeout=8.0,
            )
            session = runtime.get(session_id)
            seat_b = next(task for task in session["tasks"] if task["provider"] == "claude")
            check(
                "The other seat is still pending, so the round is open",
                seat_b.get("status") == "pending",
                f"stage={session.get('stage')} pending={seat_b.get('status')}",
            )

            card = ui.task_card(seat_a)
            check(
                "Answered card marks the saved text, not a correction",
                "已收到" in card.inner_text() and "已更正" not in card.inner_text(),
                card.inner_text().replace("\n", " / ")[:140],
            )
            correct_button = card.locator("button", has_text="改正录入")
            check("The correction exists on the answered live card", correct_button.count() == 1, f"count={correct_button.count()}")
            if correct_button.count() == 1:
                check(
                    "Correction is tucked under the existing 更多操作, not a front action",
                    correct_button.first.is_visible() is False
                    and card.locator("details.task-more summary.task-more-summary").count() == 1,
                    "closed details keeps it out of the way",
                )
            shot(page, out_dir, "01_answered_live_card")

            # ---------------------------------------------------------------
            # Open and save the correction.
            # ---------------------------------------------------------------
            print("\n[2] Correct the live answer")
            more = card.locator("details.task-more").first
            open_details(more)
            correct_button = card.locator("button", has_text="改正录入")
            check("Opening 更多操作 reveals the correction", correct_button.count() == 1 and correct_button.first.is_visible(), "")
            correct_button.first.click(timeout=4000)

            card = ui.task_card(seat_a)
            editor = card.locator("textarea.correction-input")
            check("Correction editor opens on the answered card", editor.count() == 1, "")
            if editor.count() == 1:
                check(
                    "Correction editor is prefilled with the saved text",
                    editor.first.input_value() == ORIGINAL,
                    editor.first.input_value()[:40],
                )
                editor.first.fill(CORRECTED)
            card.get_by_role("button", name="保存更正").click(timeout=4000)
            ba.wait_until(
                lambda: "CORRECTION_FIXED_8b1" in ui.task_card(seat_a).inner_text(timeout=4000),
                "corrected text renders",
                timeout=8.0,
            )
            ba.wait_until(
                lambda: "已更正录入" in page.locator("#toast").inner_text(timeout=1500),
                "correction toast",
                timeout=5.0,
            )
            check("Saving the correction reports success", "已更正录入" in page.locator("#toast").inner_text(timeout=1500), "")

            card = ui.task_card(seat_a)
            card_text = card.inner_text()
            check(
                "Card shows the corrected text and marks 已更正",
                "CORRECTION_FIXED_8b1" in card_text and "已更正" in card_text,
                card_text.replace("\n", " / ")[:180],
            )
            check(
                "Replaced text is gone from the live answer body",
                "CORRECTION_ORIGINAL_4d2" not in card.locator(".answer-text").inner_text(timeout=2000),
                "",
            )
            revision = card.locator("details.prompt-box-revision")
            check("Card keeps a 更正前后 provenance block", revision.count() == 1, "")
            if revision.count() == 1:
                open_details(revision)
                check(
                    "Provenance shows the original text next to the corrected one",
                    "CORRECTION_ORIGINAL_4d2" in revision.first.inner_text(timeout=2000)
                    and "首次提交" in revision.first.inner_text(timeout=2000),
                    revision.first.inner_text(timeout=2000).replace("\n", " / ")[:120],
                )
            shot(page, out_dir, "02_corrected_live_card")

            # The correction replaces one answer; it does not create a second.
            session = runtime.get(session_id)
            saved = next(task for task in session["tasks"] if task["id"] == seat_a["id"])
            check(
                "Backend keeps one corrected answer plus the original provenance",
                saved.get("status") == "answered"
                and saved.get("answer") == CORRECTED
                and saved.get("originalAnswer") == ORIGINAL
                and len(saved.get("corrections") or []) == 1
                and (saved.get("corrections") or [{}])[0].get("previousText") == ORIGINAL,
                json.dumps(saved, ensure_ascii=False)[:200],
            )
            check(
                "The round did not advance and has exactly one answered seat",
                session.get("stage") == "independent"
                and len([task for task in session["tasks"] if task.get("status") == "answered"]) == 1
                and len(session.get("history") or []) == 0,
                f"stage={session.get('stage')} history={len(session.get('history') or [])}",
            )
            pending_card = ui.task_card(seat_b)
            check(
                "The still-pending seat offers no correction",
                pending_card.locator("button", has_text="改正录入").count() == 0,
                "",
            )

            # ---------------------------------------------------------------
            # The next round must receive only the corrected text.
            # ---------------------------------------------------------------
            print("\n[3] Next round uses the corrected text")
            ui.answer_task(
                session_id,
                seat_b,
                "SECOND_SEAT_TEXT 这一席正常提交，用于触发下一轮。",
                stage="independent",
            )
            session = ba.wait_until(
                lambda: (lambda value: value if value.get("stage") == "critique" else None)(runtime.get(session_id)),
                "critique stage",
                timeout=10.0,
            )
            next_task = next(task for task in session["tasks"] if task["provider"] == "claude")
            prompt = str(next_task.get("prompt") or "")
            check(
                "The next-round prompt carries the corrected text",
                "CORRECTION_FIXED_8b1" in prompt,
                "corrected token present" if "CORRECTION_FIXED_8b1" in prompt else "missing",
            )
            check(
                "The replaced text is not relayed onward",
                "CORRECTION_ORIGINAL_4d2" not in prompt,
                "replaced token absent" if "CORRECTION_ORIGINAL_4d2" not in prompt else "leaked",
            )
            check(
                "Correction is gone once the round freezes",
                page.locator("button", has_text="改正录入").count() == 0,
                f"remaining controls={page.locator('button', has_text='改正录入').count()}",
            )
            shot(page, out_dir, "03_next_round_prompt")

            # ---------------------------------------------------------------
            # Reload: archived history keeps provenance, no correction control.
            # ---------------------------------------------------------------
            print("\n[4] Archived history after reload")
            page.reload(wait_until="domcontentloaded")
            ba.wait_until(lambda: page.locator(".history-section").count() == 1, "history section", timeout=8.0)
            entries = page.locator(".timeline-item").filter(has_text="CORRECTION_FIXED_8b1")
            check(
                "History shows exactly one archived answer for the corrected seat",
                entries.count() == 1,
                f"count={entries.count()}",
            )
            if entries.count() == 1:
                entry = entries.first
                entry_text = entry.inner_text()
                check(
                    "Archived entry is marked 已更正 and keeps the corrected text",
                    "已更正" in entry_text and "CORRECTION_FIXED_8b1" in entry_text,
                    entry_text.replace("\n", " / ")[:140],
                )
                revision = entry.locator("details.prompt-box-revision")
                check("Archived entry keeps a 更正前后 block", revision.count() == 1, "")
                if revision.count() == 1:
                    open_details(revision)
                    check(
                        "Archived provenance still shows the original text",
                        "CORRECTION_ORIGINAL_4d2" in revision.first.inner_text(timeout=2000),
                        revision.first.inner_text(timeout=2000).replace("\n", " / ")[:120],
                    )
                check(
                    "Archived answer is not offered for another edit",
                    entry.locator("button", has_text="改正录入").count() == 0
                    and entry.locator("textarea").count() == 0,
                    "",
                )
            shot(page, out_dir, "04_archived_corrected_history")

            # ---------------------------------------------------------------
            # Hygiene: no external requests and no page errors.
            # ---------------------------------------------------------------
            external = [url for url in attempts if not url.startswith(("chrome-extension://", "data:", "blob:"))]
            check("No external network request was attempted", not external, "; ".join(external[:3]))
            check("No page error surfaced", not page_errors, "; ".join(page_errors[:2]))
        except BaseException as exc:  # noqa: BLE001 - report the failing step
            failure = exc
        finally:
            context.close()

    passed = sum(1 for item in CHECKS if item["ok"])
    failed = len(CHECKS) - passed
    print(f"\n{passed} passed, {failed} failed")
    if failure is not None:
        print(f"FAILED: {failure}", file=sys.stderr)
        return 1
    return 0 if failed == 0 and CHECKS else 1


if __name__ == "__main__":
    raise SystemExit(main())
