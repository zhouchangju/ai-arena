#!/usr/bin/env python3
"""G2/G3/G4 native Chromium acceptance for critique materials and source links.

Run: python3 tests/critique_context_acceptance.py [--out /tmp/arena-critique]
"""

from __future__ import annotations

import argparse
import tempfile
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


INDEPENDENT = {
    "chatgpt": "先核对桌面索引，记录复现次数。",
    "gemini": "复测方法如下。\n\n唯一反例：断网时客户端会直接丢弃新记录。\n"
              + ("复测记录保留采集和同步两部分。" * 120),
    "deepseek": "分别记录同步延迟和采集失败。",
}


def linked_sources(container, group):
    return container.locator(f"{group} a[data-source-id]").evaluate_all(
        "links => links.map(link => link.dataset.sourceId)"
    )


def open_source(page, container, group, source, checks):
    url = page.url
    container.locator(f"{group} a[data-source-id='{source['sourceId']}']").click()
    target = page.locator(f".timeline-item.is-cited[data-source-id='{source['sourceId']}']")
    checks.check(f"{group} opens and focuses {source['sourceId']} on the same session route", (
        target.locator(".timeline-answer").text_content() == source["answer"]
        and target.evaluate("""element => {
            const rect = element.getBoundingClientRect();
            return document.activeElement === element && rect.top < innerHeight && rect.bottom > 0;
        }""")
        and page.url == url
    ))


def check_critique(page, ui: WorkspaceUI, checks: CheckLog, out: Path):
    session_id, _ = ui.create_debate("验收：如何安排笔记应用的故障复测？", list(INDEPENDENT))
    ui.answer_stage(session_id, "independent", INDEPENDENT)
    critique = ui.wait_for_stage(session_id, "critique")
    prior = {task["provider"]: task for task in critique["history"] if task["stage"] == "independent"}
    tasks = {task["provider"]: task for task in critique["tasks"]}
    own, primary, secondary = (prior[provider]["sourceId"] for provider in INDEPENDENT)
    task = tasks["chatgpt"]
    own_critique = task["sourceId"]
    future = f"S{max(int(item['sourceId'][1:]) for item in critique['tasks']) + 1}"
    card = page.locator(f".seat-card[data-task-id='{task['id']}']")
    context = card.locator(".critique-context")
    context.wait_for(state="visible")

    checks.check("Pending critique shows its supplied peer materials without implying explicit citations", (
        set(linked_sources(context, ".critique-materials")) >= {primary, secondary}
        and not linked_sources(context, ".critique-citations")
        and all(prior[provider]["answer"] in task["prompt"] for provider in INDEPENDENT)
    ))
    prompt = card.locator("details.prompt-box")
    checks.check("At 390px the initial critique context is compact and the long prompt is collapsed", (
        not prompt.evaluate("element => element.open")
        and context.bounding_box()["height"] < 250
        and "唯一反例：断网时客户端会直接丢弃新记录。" not in context.inner_text()
        and page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    ))
    page.screenshot(path=out / "critique-pending-390.png")
    prompt.locator("summary").click()
    checks.check("The expanded prompt preserves the exact relayed material", (
        prompt.locator("pre").text_content() == task["prompt"]
    ))
    prompt.locator("summary").click()
    open_source(page, context, ".critique-materials", prior["deepseek"], checks)

    reply = (
        f"[{primary}] 属于能推翻原判断的反例。复核 {primary}，并对照原先的 {own}。\n\n"
        f"[{own_critique}]、[{future}]、[S999] 是无效占位，X{secondary}Y 只是标识。\n"
        "<svg onload='window.__critiqueProbe = true'></svg>"
    )
    ui.answer_task(session_id, task, reply, stage="critique")
    card.locator(".answer-text").wait_for()
    checks.check("Live reply links bare and bracketed sources once and preserves the exact reply", (
        set(linked_sources(context, ".critique-citations")) == {primary, own}
        and len(linked_sources(context, ".critique-citations")) == 2
        and card.locator(".answer-text").text_content() == reply
        and card.locator(".answer-text svg").count() == 0
        and page.evaluate("!window.__critiqueProbe")
    ))
    open_source(page, context, ".critique-citations", prior["gemini"], checks)
    long_source = page.locator(f".timeline-item[data-source-id='{primary}']")
    checks.check("A long archived source lands with its heading visible below the mobile top bar", (
        long_source.evaluate("""element => {
            const heading = element.querySelector('.timeline-meta').getBoundingClientRect();
            const bar = document.querySelector('.sidebar.is-history-compact');
            return getComputedStyle(bar).position === 'sticky'
                && element.getBoundingClientRect().height > innerHeight
                && heading.top >= bar.getBoundingClientRect().bottom
                && heading.bottom < innerHeight;
        }""")
    ))

    ui.answer_stage(session_id, "critique", {
        "gemini": "这个反例需要稳定复现。",
        "deepseek": "先收集采集端症状，再推断原因。",
    })
    proposal = ui.wait_for_stage(session_id, "proposal")
    candidate, = proposal["tasks"]
    ui.answer_stage(session_id, "proposal", {
        candidate["provider"]: (
            f"先验证离线采集，再决定修复范围。[{own_critique}]\n\n"
            f"[{secondary} · deepseek · independent · 第1轮]\n{INDEPENDENT['deepseek']}"
        ),
    })
    vote = ui.wait_for_stage(session_id, "vote")
    checks.check("The once-future reference is now a saved candidate source", (
        any(entry["sourceId"] == future and entry["stage"] == "proposal"
            and entry["status"] == "answered" for entry in vote["history"])
    ))
    page.reload(wait_until="domcontentloaded")
    archived = page.locator(f".timeline-item[data-source-id='{own_critique}']")
    persisted_context = archived.locator(".critique-context")
    persisted_context.wait_for(state="visible")
    checks.check("After reload the archived critique retains its exact reply and links only past citations", (
        archived.locator(".timeline-answer").text_content() == reply
        and set(linked_sources(persisted_context, ".critique-citations")) == {primary, own}
        and {primary, secondary} <= set(linked_sources(persisted_context, ".critique-materials"))
    ))
    no_refs = page.locator(f".timeline-item[data-source-id='{tasks['gemini']['sourceId']}']")
    checks.check("An uncited response keeps its materials without acquiring citations", (
        len(linked_sources(no_refs, ".critique-materials")) >= 2
        and not linked_sources(no_refs, ".critique-citations")
    ))
    archived.scroll_into_view_if_needed()
    page.screenshot(path=out / "critique-archived-390.png")
    open_source(page, persisted_context, ".critique-citations", prior["chatgpt"], checks)

    ui.answer_stage(session_id, "vote", {
        "chatgpt": "接受按离线复测安排。",
        "gemini": "同意先复测。",
        "deepseek": "仍需纳入恢复联网前的重复编辑。",
    }, stances={"chatgpt": "agree", "gemini": "agree", "deepseek": "oppose"})
    targeted = ui.wait_for_stage(session_id, "critique")
    objection, = [entry for entry in targeted["history"] if entry.get("stance") == "oppose"]
    second_task = next(task for task in targeted["tasks"] if task["provider"] == candidate["provider"])
    second_context = page.locator(f".seat-card[data-task-id='{second_task['id']}'] .critique-context")
    second_context.wait_for()
    checks.check("Targeted critique lists the candidate and opposition, excluding a nested copied source block", (
        set(linked_sources(second_context, ".critique-materials")) == {future, objection["sourceId"]}
        and not linked_sources(second_context, ".critique-citations")
    ))
    open_source(page, second_context, ".critique-materials", objection, checks)
    skipped = page.locator(".seat-card[data-provider='deepseek']")
    skipped.locator("details.task-more > summary").click()
    skipped.get_by_role("button", name="跳过这一席", exact=True).click()
    page.get_by_role("dialog").get_by_role("button", name="跳过这一席", exact=True).click()
    skipped.locator(".status-chip.is-skipped").wait_for()
    checks.check("A skipped active critique retains its original materials without adding reply citations", (
        set(linked_sources(skipped, ".critique-materials")) == {future, objection["sourceId"]}
        and not linked_sources(skipped, ".critique-citations")
    ))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    out = args.out.expanduser().resolve() if args.out else Path(tempfile.mkdtemp(prefix="arena-critique-"))
    if out.is_relative_to(REPO_ROOT):
        raise AcceptanceError("Write acceptance artifacts outside the repository.")
    out.mkdir(parents=True, exist_ok=True)
    extension = REPO_ROOT / "extension"
    executable = find_chromium_executable()
    checks = CheckLog()
    attempts, errors = [], []

    with tempfile.TemporaryDirectory(prefix="arena-critique-profile-") as profile, sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            profile, executable_path=str(executable) if executable else None, headless=True,
            viewport={"width": 390, "height": 800}, reduced_motion="reduce", args=[
                f"--disable-extensions-except={extension}", f"--load-extension={extension}",
                "--disable-background-networking", "--no-proxy-server", "--host-resolver-rules=MAP * ~NOTFOUND",
            ],
        )
        try:
            install_network_guard(context, attempts)
            page = context.new_page()
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.set_default_timeout(8000)
            page.goto(f"chrome-extension://{extension_id_from_path(extension)}/workspace.html")
            check_critique(page, WorkspaceUI(page, read_providers(extension), Runtime(page)), checks, out)
            checks.check("No external requests or workspace script errors", not attempts and not errors, str(attempts + errors))
        finally:
            context.close()

    print(f"\n{len(checks.checks)} checks passed. Artifacts: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
