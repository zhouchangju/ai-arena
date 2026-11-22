#!/usr/bin/env python3
"""G1/G2/G3, R06/R07: recover interrupted discussions in real Chromium.

Run from the repository root with an installed Playwright Chromium:
    python3 tests/recovery_acceptance.py --out /tmp/ai-arena-recovery

The fixture is served on loopback. Its existing manifest permission is
pre-granted only in a temporary extension copy. DNS and routing block the
manual provider. No provider account is used. The first case stops the MV3
worker after closing the workbench. The second closes the provider tab while
it is streaming, then safely skips the unresolved task.
"""

from __future__ import annotations

import argparse
import functools
import json
import shutil
import tempfile
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

from auto_acceptance import EXT, TESTS, Quiet, fixture_pages, grant_loopback, prepare_extension, selectors
from browser_acceptance import (
    CheckLog, Runtime, WorkspaceUI, decline_provider_permissions, find_chromium_executable, wait_until,
)


AUTO = "local-a"
MANUAL = "chatgpt"
QUESTION = "中断恢复验收：只剩两个周末时，应先修桌面检索还是先验证移动端采集？"
TAB_LOSS_QUESTION = "自动席原页丢失验收：如何用一周验证检索漏失？"
MANUAL_ANSWER = "RECOVERY_MANUAL 独立原文：先验证检索漏失。\n反例：移动端可能才是主要采集渠道。"
MANUAL_CRITIQUE = "RECOVERY_CRITIQUE 先区分检索漏失和同步延迟，再比较两端的损失。"


def button(scope, name):
    return scope.get_by_role("button", name=name, exact=True)


def seat_task(session, provider):
    return next(task for task in session["tasks"] if task["provider"] == provider)


def card(page, provider):
    return page.locator(f'article.seat-card[data-provider="{provider}"]')


def fixture_texts(page, selector):
    return page.locator(selector).all_text_contents()


def provider_tabs(page):
    return page.evaluate("""async () => (await chrome.tabs.query({}))
      .filter(tab => (tab.pendingUrl || tab.url || '').startsWith('https://chatgpt.com/'))
      .map(tab => tab.id)""")


def begin_discussion(page, question):
    runtime = Runtime(page)
    decline_provider_permissions(page)
    page.locator("#question-input").fill(question)
    for provider in (AUTO, MANUAL):
        option = page.locator(f"button.provider-option[data-provider-id='{provider}']")
        if option.get_attribute("aria-pressed") != "true":
            option.click()
    button(page, "开始讨论").click()
    session = wait_until(
        lambda: next((item for item in runtime.list_sessions() if item["question"] == question), None),
        "session created through the workbench",
    )
    sid = session["id"]
    manual = seat_task(runtime.get(sid), MANUAL)
    wait_for_card(page, manual)
    WorkspaceUI(page, [], runtime).answer_task(sid, manual, MANUAL_ANSWER, stage="independent")
    return sid


def automation_state(runtime, sid):
    return runtime.ok({"type": "automation.info"})["runs"].get(sid)


def start_fixture(context, page, sid, selector_map):
    button(page, "开始自动化").click()
    runtime = Runtime(page)

    def find_started_fixture():
        started = automation_state(runtime, sid)
        if started and started["enabled"]:
            return fixture_pages(context).get("A")
        return None

    fixture = wait_until(find_started_fixture, "automation to open its loopback tab")
    fixture.locator(selector_map["user"]).first.wait_for(state="attached")
    return fixture


def worker_target(cdp, base):
    return next(
        (item["targetId"] for item in cdp.send("Target.getTargets")["targetInfos"]
         if item["type"] == "service_worker" and item["url"] == f"{base}/background.js"),
        None,
    )


def dispatch_record(page, sid, task_id):
    return page.evaluate("""async ([sid, taskId]) => {
      const key = 'arena.automation.v1';
      const stored = await chrome.storage.local.get(key);
      return stored[key]?.runs[sid]?.dispatch[taskId] ?? null;
    }""", [sid, task_id])


def recover_workbench(context, base, origin, out, evidence, checks):
    page = context.new_page()
    page.goto(f"{base}/workspace.html")
    runtime = Runtime(page)
    selector_map = selectors()
    permission = grant_loopback(page, "headless-test-copy")
    checks.check("Temporary copy has the declared loopback permission", permission["granted"])
    runtime.ok({
        "type": "automation.config", "provider": AUTO,
        "config": {
            "url": f"{origin}/web-driver-fixture.html?seat=A&speed=slow",
            "selectors": selector_map,
        },
    })

    sid = begin_discussion(page, QUESTION)
    before_start = runtime.get(sid)
    automatic = seat_task(before_start, AUTO)
    manual = seat_task(before_start, MANUAL)
    fixture = start_fixture(context, page, sid, selector_map)
    before = runtime.get(sid)
    run_before = automation_state(runtime, sid)
    evidence["before_close"] = {"session": before, "automation": run_before}
    checks.check(
        "A really submitted the exact independent prompt and is still generating",
        fixture_texts(fixture, selector_map["user"]) == [automatic["prompt"]]
        and fixture.locator(selector_map["stop"]).is_visible()
        and seat_task(before, AUTO)["status"] == "pending"
        and run_before["dispatch"][automatic["id"]]["phase"] in {"dispatching", "submitted"},
    )
    checks.check("B was already saved before interruption", seat_task(before, MANUAL)["answer"] == MANUAL_ANSWER)

    interrupted_url = page.url
    cdp = context.new_cdp_session(fixture)
    old_worker = worker_target(cdp, base)
    original_dispatch = dispatch_record(page, sid, automatic["id"])
    page.close()
    checks.check("The original workbench is closed and the same fixture tab survives",
                 page.is_closed() and fixture_pages(context).get("A") is fixture)
    checks.check("Chromium accepts termination of the original MV3 service worker",
                 bool(old_worker) and cdp.send("Target.closeTarget", {"targetId": old_worker})["success"])

    page = context.new_page()
    page.goto(f"{base}/workspace.html")
    history_item = page.locator(".history-item").filter(has_text=QUESTION)
    history_item.click()
    card(page, AUTO).wait_for()
    runtime = Runtime(page)
    resumed = runtime.get(sid)
    evidence["reopened"] = {"session": resumed, "url": page.url, "before_worker_stop": original_dispatch}
    cdp.detach()
    checks.check(
        "History reopened the same session with the same pending A task and prompt",
        page.url == interrupted_url and resumed["stage"] == "independent"
        and seat_task(resumed, AUTO) == automatic and card(page, AUTO).evaluate(
            "(card) => card.classList.contains('is-pending')"
        ),
    )
    checks.check("B is still rendered from the saved original", seat_task(resumed, MANUAL)["answer"] == MANUAL_ANSWER
                 and MANUAL_ANSWER.splitlines()[0] in card(page, MANUAL).inner_text())
    page.screenshot(path=str(out / "01_reopened_pending.png"))

    ui = WorkspaceUI(page, [], runtime)
    critique = ui.wait_for_stage(sid, "critique", timeout=22)
    independent = [entry for entry in critique["history"] if entry["stage"] == "independent"]
    exact_answer = fixture_texts(fixture, selector_map["answer"])[0]
    checks.check(
        "A is captured once from its original tab and B is retained once",
        len(independent) == 2 and {entry["id"]: entry["answer"] for entry in independent} == {
            automatic["id"]: exact_answer, manual["id"]: MANUAL_ANSWER,
        } and fixture_texts(fixture, selector_map["user"]).count(automatic["prompt"]) == 1,
    )
    checks.check(
        "Both recovered originals reach the other seat's critique prompt",
        MANUAL_ANSWER in seat_task(critique, AUTO)["prompt"]
        and exact_answer in seat_task(critique, MANUAL)["prompt"],
    )
    critique_a = seat_task(critique, AUTO)
    next_dispatch = wait_until(lambda: dispatch_record(page, sid, critique_a["id"]),
                               "the worker to dispatch the next task")
    checks.check(
        "The recovered discussion continues with a different actual worker boot",
        bool(original_dispatch["bootId"]) and bool(next_dispatch["bootId"])
        and next_dispatch["bootId"] != original_dispatch["bootId"],
        f"{original_dispatch['bootId']} → {next_dispatch['bootId']}",
    )
    evidence["reopened"]["after_worker_restart"] = next_dispatch
    fixture.locator("#speed").select_option("normal")
    critique_b = seat_task(critique, MANUAL)
    wait_for_card(page, critique_b)
    ui.answer_task(sid, critique_b, MANUAL_CRITIQUE, stage="critique")

    proposal = wait_until(lambda: current_stage(runtime, sid, "proposal", "vote"), "proposal or vote", timeout=25)
    if proposal["stage"] == "proposal" and proposal["tasks"][0]["provider"] == MANUAL:
        wait_for_card(page, proposal["tasks"][0])
        ui.answer_task(sid, proposal["tasks"][0], "建议先验证桌面检索漏失。[S1]", stage="proposal")
    vote = ui.wait_for_stage(sid, "vote", timeout=22)
    vote_a = seat_task(vote, AUTO)
    vote_b = seat_task(vote, MANUAL)
    wait_for_card(page, vote_b)
    button(card(page, MANUAL), "复制提示并打开原页").click()
    old_tabs = wait_until(lambda: provider_tabs(page), "original B browser tab")
    checks.check("B has one bound browser tab", len(old_tabs) == 1)
    page.evaluate("(id) => chrome.tabs.remove(id)", old_tabs[0])
    wait_until(lambda: not provider_tabs(page), "B tab closed")
    before_reopen = runtime.get(sid)
    checks.check(
        "Closing B's browser tab does not record an answer or move the vote to a new task",
        seat_task(before_reopen, MANUAL) == vote_b and vote_b["status"] == "pending",
    )

    button(card(page, MANUAL), "复制提示并打开原页").click()
    new_tabs = wait_until(lambda: provider_tabs(page), "reopened B browser tab")
    checks.check("Reopening B creates one replacement and preserves the vote task",
                 len(new_tabs) == 1 and new_tabs != old_tabs and seat_task(runtime.get(sid), MANUAL) == vote_b)
    evidence["provider_tabs"] = {"closed": old_tabs, "replacement": new_tabs}
    wait_until(lambda: seat_task(runtime.get(sid), AUTO)["status"] == "answered", "A's explicit vote", timeout=22)
    page.bring_to_front()
    card(page, MANUAL).locator("details.task-more > summary").click()
    button(card(page, MANUAL), "跳过这一席").click()
    button(page.get_by_role("dialog"), "跳过这一席").click()

    done = ui.wait_for_stage(sid, "done", timeout=15)
    page.get_by_text("部分完成", exact=False).first.wait_for()
    page.screenshot(path=str(out / "02_partial_report.png"))
    votes = {entry["id"]: entry for entry in done["history"] if entry["stage"] == "vote"}
    checks.check(
        "A explicitly agrees, B is absent on the same version, and no consensus is recorded",
        done["stopReason"] == "partial-votes" and set(votes) == {vote_a["id"], vote_b["id"]}
        and votes[vote_a["id"]]["stance"] == "agree"
        and votes[vote_b["id"]]["status"] == "skipped"
        and not votes[vote_b["id"]].get("stance") and not votes[vote_b["id"]].get("answer")
        and votes[vote_a["id"]]["version"] == votes[vote_b["id"]]["version"]
        and "全体一致" not in done["report"],
    )
    submissions = fixture_texts(fixture, selector_map["user"])
    fixture_answers = fixture_texts(fixture, selector_map["answer"])
    answered_automatically = [entry for entry in done["history"] if entry["provider"] == AUTO]
    evidence.update({
        "final": done, "fixture_submissions": submissions, "fixture_answers": fixture_answers,
    })
    checks.check(
        "Each auto task has exactly one DOM submission and one answered history entry",
        len(submissions) == len(set(submissions)) == len(answered_automatically)
        and len({entry["id"] for entry in done["history"]}) == len(done["history"])
        and [entry["answer"] for entry in answered_automatically] == fixture_answers
        and all(
            sent == entry["prompt"] or (
                entry["stage"] == "vote"
                and sent.startswith(f'{entry["prompt"]}\n【本机自动化表决格式】\n')
            )
            for sent, entry in zip(submissions, answered_automatically)
        ),
        f"{len(submissions)} submissions, {len(done['history'])} history rows",
    )

    with page.expect_download() as download:
        button(page.get_by_label("结论", exact=True), "导出 Markdown").click()
    exported = out / "report.md"
    download.value.save_as(str(exported))
    markdown = exported.read_text(encoding="utf-8")
    checks.check(
        "Native Markdown preserves both recovered originals and the absent vote",
        f"```\n{MANUAL_ANSWER}\n```" in markdown
        and f"```\n{exact_answer}\n```" in markdown
        and "- ChatGPT：缺席\n" in markdown and "- 状态：已跳过\n" in markdown
        and "- 部分完成：" in markdown,
    )
    evidence["export_bytes"] = exported.stat().st_size
    fixture.close()
    page.close()


def recover_closed_provider_tab(context, base, out, evidence, checks):
    page = context.new_page()
    page.goto(f"{base}/workspace.html")
    runtime = Runtime(page)
    selector_map = selectors()
    sid = begin_discussion(page, TAB_LOSS_QUESTION)
    automatic = seat_task(runtime.get(sid), AUTO)
    fixture = start_fixture(context, page, sid, selector_map)
    submitted = fixture_texts(fixture, selector_map["user"])
    active_run = automation_state(runtime, sid)
    checks.check(
        "The automatic provider tab disappears after exactly one submission while still generating",
        submitted == [automatic["prompt"]] and fixture.locator(selector_map["stop"]).is_visible()
        and seat_task(runtime.get(sid), AUTO) == automatic
        and active_run["dispatch"][automatic["id"]]["phase"] in {"dispatching", "submitted", "streaming"},
    )
    fixture.close()
    checks.check("The automatic provider's original tab is closed", fixture.is_closed())

    def paused_run():
        state = automation_state(runtime, sid)
        return state if state["seats"][AUTO]["paused"] else None

    paused = wait_until(paused_run, "only the missing automatic seat to become actionable", timeout=20)
    before_skip = runtime.get(sid)
    replacement = fixture_pages(context).get("A")
    evidence["closed_provider"] = {
        "before_close": active_run,
        "paused": paused,
        "before_skip": before_skip,
        "original_submissions": submitted,
        "automatic_replacement_opened": replacement is not None,
    }

    checks.check(
        "The same automatic task is still pending, the saved B reply survives, and Chrome did not resubmit",
        paused["seats"][AUTO]["taskId"] == automatic["id"] and seat_task(before_skip, AUTO) == automatic
        and seat_task(before_skip, MANUAL)["answer"] == MANUAL_ANSWER
        and replacement is None and paused["tabs"][AUTO]["tabId"] == active_run["tabs"][AUTO]["tabId"],
    )
    auto_card = card(page, AUTO)
    auto_card.get_by_text("自动待处理", exact=True).wait_for()
    button(auto_card, "粘贴回答").wait_for()
    automatic_panel = page.get_by_role("region", name="自动发送")
    recovery_hint = automatic_panel.get_by_text("已有完整回答可在工作台粘贴，也可跳过这一席。", exact=False)
    recovery_hint.wait_for()
    checks.check(
        "The visible recovery guidance points to real takeover controls and rules out resending",
        "不会自动重发" in recovery_hint.inner_text()
        and "开始自动化" not in recovery_hint.inner_text()
        and not button(automatic_panel, "开始自动化").is_visible(),
    )
    page.screenshot(path=str(out / "03_auto_tab_closed.png"))
    auto_card.locator("details.task-more > summary").click()
    button(auto_card, "跳过这一席").click()
    button(page.get_by_role("dialog"), "跳过这一席").click()
    ui = WorkspaceUI(page, [], runtime)
    critique = ui.wait_for_stage(sid, "critique")
    independent = [entry for entry in critique["history"] if entry["stage"] == "independent"]
    skipped = next(entry for entry in independent if entry["id"] == automatic["id"])
    checks.check(
        "Skipping the missing answer marks only that task absent and advances without inventing an answer",
        len(independent) == 2 and skipped["status"] == "skipped" and not skipped.get("answer")
        and next(entry for entry in independent if entry["provider"] == MANUAL)["answer"] == MANUAL_ANSWER
        and (
            (next_page := fixture_pages(context).get("A")) is None
            or automatic["prompt"] not in fixture_texts(next_page, selector_map["user"])
        ),
    )
    button(page, "结束讨论").click()
    button(page.get_by_role("dialog"), "结束讨论").click()
    done = ui.wait_for_stage(sid, "done")
    evidence["closed_provider"]["final"] = done
    checks.check("The interrupted second discussion remains partial after ending",
                 done["stopReason"] == "user-finished" and "全体一致" not in done["report"])


def wait_for_card(page, task):
    page.locator(f'article.seat-card[data-task-id="{task["id"]}"]').wait_for()


def current_stage(runtime, sid, *stages):
    session = runtime.get(sid)
    return session if session["stage"] in stages else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.out.expanduser().resolve()
    if out.is_relative_to(EXT.parent):
        parser.error("--out must point outside the repository")
    out.mkdir(parents=True, exist_ok=True)
    checks = CheckLog()
    evidence = {"checks": checks.checks, "blocked_external_routes": []}
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=str(TESTS)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_port}"
    load_dir, manifest = prepare_extension(EXT, False)
    evidence["manifest"] = manifest

    try:
        with tempfile.TemporaryDirectory(prefix="ai-arena-recovery-profile-") as profile, sync_playwright() as pw:
            executable = find_chromium_executable()
            context = pw.chromium.launch_persistent_context(
                profile, accept_downloads=True, headless=True,
                executable_path=str(executable) if executable else None,
                args=[
                    f"--disable-extensions-except={load_dir}", f"--load-extension={load_dir}",
                    "--no-first-run", "--disable-background-networking", "--disable-component-update",
                    "--disable-sync", "--no-proxy-server",
                    "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
                ],
            )
            try:
                def guard(route):
                    url = route.request.url
                    if url.startswith(("http://", "https://")) and not url.startswith(f"{origin}/"):
                        evidence["blocked_external_routes"].append(url)
                        route.abort()
                        return
                    route.continue_()

                context.route("**/*", guard)
                worker = context.service_workers[0] if context.service_workers else context.wait_for_event("serviceworker")
                browser_version_page = context.pages[0]
                cdp = context.new_cdp_session(browser_version_page)
                evidence["chromium"] = cdp.send("Browser.getVersion")["product"]
                cdp.detach()
                base = f"chrome-extension://{worker.url.split('/')[2]}"
                recover_workbench(context, base, origin, out, evidence, checks)
                recover_closed_provider_tab(context, base, out, evidence, checks)
            finally:
                context.close()
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(load_dir.parent)
        (out / "results.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
