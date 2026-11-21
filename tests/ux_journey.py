#!/usr/bin/env python3
"""Screenshot-first UX journey for the AI Arena workspace.

Runs the real unpacked extension in an isolated Chromium profile and walks the
journey a person actually takes: home -> seat selection -> returning-user
restore -> pending answers -> peer handoff -> critique -> proposal -> vote ->
report citations. It also captures narrow viewport, dark color scheme, focus
order and a keyboard-only start.

Nothing is installed and no provider site is visited (external HTTP(S) is
blocked). Screenshots are viewport shots by default so what is captured is what
the user sees at that size. Run from the repository root:

    python3 tests/ux_journey.py --ext extension --out .git/glass/qa/after --label after
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import browser_acceptance as ba  # noqa: E402  (shared launch/UI helpers, no installs)
from playwright.sync_api import sync_playwright  # noqa: E402

CHECKS: list[dict[str, Any]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    CHECKS.append({"name": name, "ok": bool(ok), "detail": detail})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


def shot(page, out: Path, name: str) -> Path:
    path = out / f"{name}.png"
    page.screenshot(path=str(path), full_page=False)
    print(f"  shot: {path.name}")
    return path


def expand_stage_prompts(page) -> None:
    """Open this stage's prompt details only, so history does not scroll us away."""
    details = page.locator(".stage details.prompt-box")
    for index in range(min(details.count(), 6)):
        node = details.nth(index)
        try:
            if node.is_visible() and not node.evaluate("el => el.open"):
                node.locator("summary").first.click(timeout=2000)
        except Exception:
            continue


def focus_stage(page) -> None:
    page.locator(".stage").first.scroll_into_view_if_needed()
    page.evaluate("() => { const s = document.querySelector('.stage'); if (s) s.scrollIntoView({block: 'start'}); }")


def active(page) -> dict[str, Any]:
    return page.evaluate(
        """() => {
          const el = document.activeElement;
          if (!el || el === document.body) return { tag: 'BODY' };
          const style = getComputedStyle(el);
          return {
            tag: el.tagName,
            id: el.id || '',
            cls: (el.className || '').toString().slice(0, 60),
            name: (el.getAttribute('aria-label') || el.innerText || el.value || '').trim().slice(0, 40),
            outline: `${style.outlineWidth} ${style.outlineStyle} ${style.outlineColor}`,
          };
        }"""
    )


def rgb_luminance(value: str) -> float:
    parts = [int(p) for p in value.replace("rgba(", "").replace("rgb(", "").rstrip(")").split(",")[:3]]
    r, g, b = (c / 255 for c in parts)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture the AI Arena workspace user journey")
    parser.add_argument("--ext", default=str(ba.REPO_ROOT / "extension"))
    parser.add_argument("--out", required=True)
    parser.add_argument("--label", default="run")
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()

    ext_dir = ba.find_extension_dir(args.ext)
    out = Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    providers = ba.read_providers(ext_dir)
    by_id = {p.provider_id: p for p in providers}
    manifest = json.loads((ext_dir / "manifest.json").read_text(encoding="utf-8"))
    ui_path = ba.manifest_ui_path(ext_dir, manifest)
    question = "UX 走查：个人笔记工具值不值得先做移动端？我只有两个周末。"

    profile = Path(ba.tempfile.mkdtemp(prefix="ai-arena-ux-"))
    attempts: list[str] = []

    with sync_playwright() as playwright:
        executable = ba.find_chromium_executable()
        context = playwright.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=not args.headed,
            viewport={"width": 1280, "height": 800},
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
                "--no-proxy-server",
                "--host-resolver-rules=MAP * ~NOTFOUND",
            ],
        )
        ba.install_network_guard(context, attempts)
        context.set_default_timeout(10000)
        try:
            context.grant_permissions(["clipboard-read", "clipboard-write"])
        except Exception as exc:
            print(f"  [INFO] clipboard permission unavailable: {exc}")
        page = context.new_page()
        page_errors: list[str] = []
        page.on("pageerror", lambda err: page_errors.append(str(err)))

        try:
            worker = None
            try:
                worker = context.wait_for_event("serviceworker", timeout=15000)
            except Exception:
                worker = context.service_workers[0] if context.service_workers else None
            ext_id = worker.url.split("/")[2] if worker else ba.extension_id_from_path(ext_dir)
            page.goto(f"chrome-extension://{ext_id}/{ui_path.lstrip('/')}", wait_until="domcontentloaded")
            ba.wait_until(lambda: page.locator("#question-input").count() == 1, "workspace render")
            runtime = ba.Runtime(page)
            ui = ba.WorkspaceUI(page, providers, runtime)

            # ---------- 1. home ----------
            print(f"\n[{args.label}] home")
            shot(page, out, "01_home_desktop")
            first_focus = active(page)
            check("Q uses the question field as the initial focus", first_focus.get("id") == "question-input", json.dumps(first_focus, ensure_ascii=False))

            tab_order = []
            for _ in range(12):
                page.keyboard.press("Tab")
                tab_order.append(active(page))
            check(
                "Tab order stays inside visible controls and shows a focus outline",
                all(item.get("tag") != "BODY" for item in tab_order)
                and any("solid" in str(item.get("outline")) for item in tab_order),
                " → ".join(f"{item.get('tag')}#{item.get('id')}" for item in tab_order[:6]),
            )
            check("Focus is visibly outlined", any("solid" in str(item.get("outline")) for item in tab_order), tab_order[0]["outline"])

            # Keyboard-only seat selection on the first provider chip.
            first_pid = providers[0].provider_id
            page.locator(f"button.provider-option[data-provider-id='{first_pid}']").focus()
            page.keyboard.press("Enter")
            pressed = page.locator(f"button.provider-option[data-provider-id='{first_pid}']").get_attribute("aria-pressed")
            check("Enter toggles a focused seat chip", pressed == "true", f"{first_pid} aria-pressed={pressed}")
            page.keyboard.press("Enter")

            # ---------- 2. selection + returning-user restore ----------
            print(f"\n[{args.label}] selection")
            ui.set_question(question)
            for pid in ("chatgpt", "claude"):
                page.locator(f"button.provider-option[data-provider-id='{pid}']").click()
            snapshot = ui.selection_snapshot()
            check("Two seats show 2 / 2 and pressed state", snapshot["pressed"] == ["chatgpt", "claude"] and "2 / 2" in snapshot["counter"], snapshot["counter"])
            shot(page, out, "02_home_selected")

            page.reload(wait_until="domcontentloaded")
            ba.wait_until(lambda: page.locator("#question-input").count() == 1, "home after reload")
            restored = page.locator("#question-input").input_value()
            restored_snapshot = ui.selection_snapshot()
            check(
                "Returning user gets the typed question and both seats back",
                restored == question and restored_snapshot["pressed"] == ["chatgpt", "claude"] and "2 / 2" in restored_snapshot["counter"],
                f"question_restored={restored == question} pressed={restored_snapshot['pressed']}",
            )
            shot(page, out, "03_home_returning")

            # ---------- 3. keyboard start -> pending answers ----------
            print(f"\n[{args.label}] pending")
            page.locator("#question-input").focus()
            page.keyboard.press("Control+Enter")
            sessions = ba.wait_until(lambda: [s for s in runtime.list_sessions() if s.get("question") == question], "new session from Ctrl+Enter")
            session_id = str(sessions[0]["id"])
            ba.wait_until(lambda: "独立作答" in page.locator("body").inner_text(timeout=4000), "independent stage")
            pending_text = page.locator(".stage-count").inner_text()
            check("Ctrl+Enter creates the session and both seats are pending", "待回答 2" in pending_text, pending_text)
            handoff = page.get_by_role("button", name="复制提示并打开原页")
            check("Pending seat offers one-click prompt+site handoff", handoff.count() == 2, f"{handoff.count()} handoff buttons")
            check("Pending seat offers paste/submit without leaving the page", page.get_by_role("button", name="粘贴回答").count() == 2)
            next_step = page.locator("[aria-label='当前可执行的下一步']")
            check("A next-step strip names the seat to hand off first", next_step.count() == 1 and "下一步" in next_step.inner_text(), next_step.inner_text() if next_step.count() else "missing")
            check("The first next seat is marked in its card", page.locator("article.seat-card.is-next").count() == 1)
            shot(page, out, "04_session_pending")

            # Exercise the copy-only action here; guidance_acceptance verifies the compound handoff.
            first_seat = page.locator("article.seat-card.is-next")
            first_seat.locator("details.task-more summary").click()
            page.bring_to_front()
            first_seat.get_by_role("button", name="复制提示", exact=True).click()
            ba.wait_until(
                lambda: "粘回" in next_step.inner_text(timeout=4000),
                "next step paste prompt",
            )
            check("After copying, the next step asks for the pasted answer", True)
            shot(page, out, "04b_next_step_paste")

            # ---------- 4. first answer: pending remainder stays legible ----------
            session = runtime.get(session_id)
            tasks = {str(t["provider"]): t for t in session.get("tasks") or []}
            ui.answer_task(session_id, tasks["chatgpt"], "UX_ALPHA 我主张先做移动端：记录多发生在通勤路上；若两周内只能只读，则应改为先做快速采集入口。")
            pending_after = page.locator(".stage-count").inner_text()
            check("After one answer the other seat is still marked pending", "待回答 1" in pending_after and "已收到 1 / 2" in pending_after, pending_after)
            shot(page, out, "05_session_one_answered")

            # While the peer is still pending, the saved answer can be corrected in place.
            answered_card = page.locator("article.seat-card.is-answered").first
            more_a = answered_card.locator("summary.task-more-summary")
            if more_a.count():
                more_a.click()
            fix = answered_card.get_by_role("button", name="改正录入")
            check("A saved answer offers in-place correction while the peer is pending", fix.count() == 1)
            if fix.count():
                fix.click()
                corrected = "UX_ALPHA_FIXED 我主张先做移动端，并补上：只在通勤场景验证采集频次。"
                page.locator("textarea.answer-input").first.fill(corrected)
                page.get_by_role("button", name="保存更正").click()
                ba.wait_until(lambda: "UX_ALPHA_FIXED" in json.dumps(runtime.get(session_id), ensure_ascii=False), "corrected answer saved")
                check("Correction replaces the saved text and marks the seat corrected", "已更正" in page.locator("article.seat-card.is-answered").first.inner_text())
                provenance = page.locator("article.seat-card.is-answered details").filter(has_text="更正前后").first
                if provenance.count():
                    provenance.locator("summary").click()
                    prov_text = provenance.inner_text()
                    check("Correction keeps the first submitted text for provenance", "UX_ALPHA " in prov_text, prov_text.replace("\n", " / ")[:120])
                shot(page, out, "05b_answer_corrected")

            page.locator("button", has_text="粘贴回答").first.click()
            editor = page.locator("textarea.answer-input").first
            editor.fill("UX_BETA 我反对直接做移动端：没有证据表明采集频率高；若一周采集少于三次，优先级应反转。")
            action_texts = page.locator(".task-actions").all_inner_texts()
            leaked = any(re.search(r"(^|\s)null(\s|$)", text) for text in action_texts)
            null_buttons = page.get_by_role("button", name="null", exact=True).count()
            check(
                "Opening an answer editor leaves no placeholder text in any card",
                null_buttons == 0 and not leaked,
                f"null_buttons={null_buttons} actions={' | '.join(t.replace(chr(10), ' / ') for t in action_texts)!r}",
            )
            shot(page, out, "06_answer_editor")
            page.get_by_role("button", name="提交回答").first.click()
            ba.wait_until(lambda: "交叉质询" in page.locator("body").inner_text(timeout=4000), "critique stage")
            expand_stage_prompts(page)
            focus_stage(page)
            shot(page, out, "07_critique_relay")
            relay = page.locator("body").inner_text()
            check("Critique screen shows both relayed original answers", ("UX_ALPHA_FIXED" in relay or "UX_ALPHA" in relay) and "UX_BETA" in relay)

            # ---------- 5. critique / proposal / vote ----------
            print(f"\n[{args.label}] vote")
            ui.answer_stage(session_id, "critique", {
                "chatgpt": "UX_CRIT_A 接受反例，修正为先用手机快捷入口验证采集频次。",
                "claude": "UX_CRIT_B 维持反对，但同意先验证采集频次。",
            })
            ba.wait_until(lambda: "候选结论" in page.locator("body").inner_text(timeout=4000), "proposal stage")
            focus_stage(page)
            shot(page, out, "08_proposal")
            ui.answer_stage(session_id, "proposal", {
                "chatgpt": "UX_PROP_A 候选结论：先做手机快速采集入口，第二周补桌面检索。依据 [S1] 与 [S2]。",
                "claude": "UX_PROP_B 候选结论：先测一周采集频次，不承诺完整移动端。依据 [S2]，保留 [S1] 条件。",
            })
            ba.wait_until(lambda: "逐席确认" in page.locator("body").inner_text(timeout=4000), "vote stage")
            page.get_by_role("button", name="粘贴回答").first.click()
            stance = page.locator("button.stance-btn[data-stance='conditional']").first
            stance.click()
            page.locator("textarea.answer-input").first.fill("UX_VOTE_A 有条件同意：先验证一周采集频次。")
            focus_stage(page)
            shot(page, out, "09_vote_stance")
            check("Vote exposes pressed stance buttons", stance.get_attribute("aria-pressed") == "true")
            page.get_by_role("button", name="记录表态").first.click()
            ui.answer_stage(session_id, "vote", {
                "chatgpt": "UX_VOTE_A 有条件同意：先验证一周采集频次。",
                "claude": "UX_VOTE_B 有条件同意：若不足三次则改为桌面优先。",
            }, stances={"chatgpt": "conditional", "claude": "conditional"})
            session = ba.wait_until(lambda: (lambda s: s if s.get("stage") == "done" else None)(runtime.get(session_id)), "done stage")
            check("Final report is generated", len(str(session.get("report") or "").strip()) > 120, f"{len(str(session.get('report') or ''))} chars")

            # ---------- 6. report citations ----------
            print(f"\n[{args.label}] report")
            page.locator("section.report").scroll_into_view_if_needed()
            shot(page, out, "10_report_top")
            cite = page.locator("button.report-cite, a.report-cite").first
            check("Report renders clickable citations", cite.count() == 1)
            cite.scroll_into_view_if_needed()
            shot(page, out, "11_report_citations")
            cite.click()
            ba.wait_until(lambda: page.locator(".timeline-item.is-cited").count() == 1, "cited source highlight")
            check("Clicking a citation highlights its source entry", page.locator(".timeline-item.is-cited").count() == 1)
            shot(page, out, "12_citation_target")

            # ---------- 7. reload durability + history ----------
            page.reload(wait_until="domcontentloaded")
            ba.wait_until(lambda: page.locator("section.report").count() == 1, "report after reload")
            check("Report and history survive reload", question[:12] in page.locator(".sidebar").inner_text())
            shot(page, out, "13_report_after_reload")

            # ---------- 8. returning pair + narrow viewport ----------
            print(f"\n[{args.label}] recall + narrow")
            page.locator("#new-session").click()
            ba.wait_until(lambda: page.locator("#question-input").count() == 1, "home narrow")
            recall = ui.selection_snapshot()
            check(
                "A new discussion recalls the last pair without retyping",
                recall["pressed"] == ["chatgpt", "claude"] and "沿用上次" in page.locator("body").inner_text(),
                f"pressed={recall['pressed']}",
            )
            shot(page, out, "14_home_recall")
            page.locator("button.provider-option[data-provider-id='gemini']").click()
            body_text = page.locator("body").inner_text()
            third_error = page.locator(".inline-error").inner_text() if page.locator(".inline-error").is_visible() else ""
            resolved = not ("最多两席" in third_error and "改选直接点其他成员" in body_text)
            check(
                "Changing a recalled pair works the way the recall note says",
                resolved,
                f"error={third_error!r}",
            )
            shot(page, out, "14b_home_third_seat")
            page.set_viewport_size({"width": 420, "height": 800})
            overflow = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
            check("Narrow home has no horizontal overflow", overflow <= 0, f"overflow={overflow}px")
            shot(page, out, "15_home_narrow")
            history_toggle = page.locator("#history-nav-toggle")
            history_visible = history_toggle.is_visible()
            if history_visible:
                history_toggle.click()
            check("Narrow screens put history behind a labelled toggle", history_visible and history_toggle.get_attribute("aria-expanded") == "true", f"visible={history_visible}")
            if history_visible:
                page.keyboard.press("Escape")
                check(
                    "Escape closes the history drawer and returns focus to its toggle",
                    history_toggle.get_attribute("aria-expanded") == "false" and active(page).get("id") == "history-nav-toggle",
                    json.dumps(active(page), ensure_ascii=False),
                )
                history_toggle.click()
            history = page.locator("#history-nav-panel .history-item").first
            if history.count() == 0:
                history = page.locator(".history-item").first
            check("History remains reachable on narrow screens", history.count() == 1 and history.is_visible())
            history.click()
            ba.wait_until(lambda: page.locator("section.report").count() == 1, "report narrow")
            try:
                ba.wait_until(lambda: active(page).get("tag") in ("H1", "MAIN") or active(page).get("id") == "view", "focus back in content", timeout=3.0)
                check("Choosing a discussion moves focus into the content", active(page).get("tag") in ("H1", "MAIN") or active(page).get("id") == "view", json.dumps(active(page), ensure_ascii=False))
            except Exception:
                check("Choosing a discussion moves focus into the content", False, json.dumps(active(page), ensure_ascii=False))
            overflow = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
            check("Narrow report has no horizontal overflow", overflow <= 0, f"overflow={overflow}px")
            page.locator("section.report").scroll_into_view_if_needed()
            shot(page, out, "16_report_narrow")

            # ---------- 9. dark color scheme ----------
            print(f"\n[{args.label}] dark")
            page.set_viewport_size({"width": 1280, "height": 800})
            page.emulate_media(color_scheme="dark")
            page.reload(wait_until="domcontentloaded")
            ba.wait_until(lambda: page.locator("body").inner_text(timeout=3000).strip(), "dark render")
            page.evaluate("window.scrollTo(0, 0)")
            colors = page.evaluate(
                """() => {
                  const html = getComputedStyle(document.documentElement);
                  const body = getComputedStyle(document.body);
                  const card = document.querySelector('.report, .home-compose, .seat-card');
                  return {
                    htmlBg: html.backgroundColor,
                    bodyBg: body.backgroundColor,
                    fg: body.color,
                    card: card ? getComputedStyle(card).backgroundColor : '',
                  };
                }"""
            )
            surface = colors["htmlBg"] if colors["bodyBg"].endswith(", 0)") or colors["bodyBg"] == "rgba(0, 0, 0, 0)" else colors["bodyBg"]
            dark_ok = rgb_luminance(surface) < 0.3 and rgb_luminance(colors["fg"]) > 0.5
            check("Dark color scheme switches surface and text", dark_ok, json.dumps(colors, ensure_ascii=False))
            shot(page, out, "17_dark_session")
            page.locator("#new-session").click()
            ba.wait_until(lambda: page.locator("#question-input").count() == 1, "home dark")
            shot(page, out, "18_dark_home")
            page.emulate_media(color_scheme="light")

            # ---------- 9. skipped-seat recovery affordance ----------
            print(f"\n[{args.label}] recovery")
            recovery = runtime.ok({"type": "create", "question": "走查：跳过一席后是否还能补录？", "providers": ["chatgpt", "claude"]})["session"]
            page.goto(f"chrome-extension://{ext_id}/{ui_path.lstrip('/')}#s={recovery['id']}", wait_until="domcontentloaded")
            page.reload(wait_until="domcontentloaded")
            page.locator("article.seat-card").first.wait_for()
            rc = page.locator("article.seat-card").first
            rc.get_by_role("button", name="粘贴回答").click()
            rc = page.locator("article.seat-card").first
            rc.locator("textarea.answer-input").first.fill("UX_RECOVERY_DRAFT 跳过前写下、但没提交的草稿。")
            more = rc.locator("summary.task-more-summary")
            if more.count():
                more.click()
            skip_buttons = rc.get_by_role("button", name="跳过这一席")
            visible_skips = sum(1 for i in range(skip_buttons.count()) if skip_buttons.nth(i).is_visible())
            check("A seat does not show the same destructive skip twice", visible_skips <= 1, f"visible skips={visible_skips}")
            rc.get_by_role("button", name="跳过这一席").first.click()
            page.locator("dialog.confirm").wait_for()
            page.locator("dialog.confirm").get_by_role("button", name="跳过这一席").click()
            ba.wait_until(lambda: page.locator("article.seat-card.is-skipped").count() == 1, "skipped seat")
            skipped = page.locator("article.seat-card.is-skipped").first
            skipped_text = skipped.inner_text()
            recovery_control = skipped.get_by_role("button", name=re.compile("补录|继续草稿|粘贴回答|修改回答|重新填"))
            promising = "补录" in skipped_text
            check(
                "Skipped seat either offers recovery or stops promising it",
                (not promising) or recovery_control.count() > 0,
                f"promises={promising} controls={recovery_control.count()}",
            )
            check(
                "An unsubmitted draft stays readable on a skipped seat",
                "未提交的草稿" in skipped_text or "UX_RECOVERY_DRAFT" in skipped_text,
                skipped_text.replace("\n", " / ")[:160],
            )
            skipped.scroll_into_view_if_needed()
            shot(page, out, "19_skipped_card")
            page.locator("#new-session").click()
            ba.wait_until(lambda: page.locator("#question-input").count() == 1, "home after recovery")

            # ---------- 10. connections screen ----------
            print(f"\n[{args.label}] connections")
            conn = context.new_page()
            conn.goto(f"chrome-extension://{ext_id}/connections.html", wait_until="domcontentloaded")
            ba.wait_until(lambda: conn.locator(".seat, .field, main").count() > 0, "connections render")
            shot(conn, out, "20_connections_desktop")
            save_buttons = conn.get_by_role("button", name=re.compile("保存"))
            check("Connections screen exposes per-seat save controls", save_buttons.count() >= 2, f"{save_buttons.count()} save buttons")
            conn.set_viewport_size({"width": 420, "height": 800})
            overflow = conn.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
            check("Narrow connections screen has no horizontal overflow", overflow <= 0, f"overflow={overflow}px")
            shot(conn, out, "21_connections_narrow")
            conn.close()

            # ---------- 11. health ----------
            check("No uncaught page errors", not page_errors, "; ".join(page_errors[:3]))
            hosts = ba.external_request_hosts(attempts)
            check("No external HTTP(S) request attempted", not hosts, ", ".join(attempts[:5]))

            summary = {
                "label": args.label,
                "extension": str(ext_dir),
                "viewport": "1280x800 @2x; narrow 420x800",
                "checks": CHECKS,
                "passed": sum(1 for c in CHECKS if c["ok"]),
                "failed": sum(1 for c in CHECKS if not c["ok"]),
                "shots": sorted(p.name for p in out.glob("*.png")),
            }
            (out / f"ux_{args.label}.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"\n{summary['passed']} passed, {summary['failed']} failed; shots in {out}")
            return 0 if summary["failed"] == 0 else 1
        finally:
            context.close()
            ba.shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
