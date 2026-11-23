#!/usr/bin/env python3
"""G1–G4: Three-seat opposition, one targeted round, and a cited disagreement.

Run: python3 tests/vote_round_acceptance.py [--out /tmp/arena-vote-round]
Uses synthetic answers in the real extension UI and an isolated Chromium profile.
"""

from __future__ import annotations

import argparse
import sys
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

PROVIDERS = ["chatgpt", "gemini", "deepseek"]
QUESTION = "验收：只有两个周末，先上线移动端采集还是先验证桌面漏检？"
FIRST_OBJECTION = "V1_OPPOSITION 移动端采集失败没有复现，优先上线可能挤占桌面验证。"
FINAL_OBJECTION = "V2_OPPOSITION 小样本仍无法覆盖离线采集，暂不接受上线日期。"
STALE_VOTE = "STALE_VOTE 这一条旧表态不应进入任何原文。"
STANCES = {"chatgpt": "agree", "gemini": "agree", "deepseek": "oppose"}


def archived(session, stage, round_number, provider=None):
    return [
        entry for entry in session["history"]
        if entry["stage"] == stage and entry["round"] == round_number
        and (provider is None or entry["provider"] == provider)
    ]


def check_vote_round(page, ui: WorkspaceUI, runtime: Runtime, out_dir: Path, checks: CheckLog):
    session_id, _ = ui.create_debate(QUESTION, PROVIDERS)
    checks.check("Three public seats start from the same question", runtime.get(session_id)["providers"] == PROVIDERS)

    ui.answer_stage(session_id, "independent", {
        "chatgpt": "先测桌面漏检，暂缓决定要不要重写索引。",
        "gemini": "两端各做一次快速复现，再按严重程度排序。",
        "deepseek": "采集失败只在离线条件下出现，尚缺复现。",
    })
    ui.answer_stage(session_id, "critique", {
        "chatgpt": "优先上线假设移动端问题已经稳定复现。",
        "gemini": "若只测在线场景，就无法排除离线采集失败。",
        "deepseek": "如果移动端没有稳定复现，应保留桌面验证。",
    })
    first_proposal = ui.wait_for_stage(session_id, "proposal")
    first_sources = "".join(f"[{task['sourceId']}]" for task in archived(first_proposal, "critique", 1))
    first_drafter = first_proposal["tasks"][0]["provider"]
    first_candidate = f"CANDIDATE_V1 首周末完成桌面验证，次周末上线移动端采集。{first_sources}"
    ui.answer_stage(session_id, "proposal", {first_drafter: first_candidate})
    vote_one = ui.wait_for_stage(session_id, "vote")
    old_yes = next(task for task in vote_one["tasks"] if task["provider"] == "chatgpt")
    checks.check("All three original vote tasks are bound to v1", len(vote_one["tasks"]) == 3 and all(
        task["version"] == 1 and first_candidate in task["prompt"] for task in vote_one["tasks"]
    ))
    ui.answer_stage(session_id, "vote", {
        "chatgpt": "V1_CHATGPT 同意这个次序。",
        "gemini": "V1_GEMINI 同意按两个周末安排。",
        "deepseek": FIRST_OBJECTION,
    }, STANCES)

    targeted = ui.wait_for_stage(session_id, "critique")
    first_oppose, = archived(targeted, "vote", 1, "deepseek")
    first_source = first_oppose["sourceId"]
    checks.check("The archived v1 vote retains the third seat's explicit opposition", (
        first_oppose["version"], first_oppose["stance"], first_oppose["answer"]
    ) == (1, "oppose", FIRST_OBJECTION))
    checks.check("The v1 opposition opens critique round 2 for all three seats", (
        targeted["round"] == 2 and len(targeted["tasks"]) == 3
    ), f"round={targeted['round']}, tasks={len(targeted['tasks'])}")
    for task in targeted["tasks"]:
        prompt = task["prompt"]
        source_line = next((line for line in prompt.splitlines() if line.startswith(f"[{first_source} ·")), "missing")
        checks.check(f"{task['provider']} receives the targeted v1 objection verbatim with its source", (
            "定向质询" in prompt and first_candidate in prompt
            and f"[{first_source} · deepseek · vote · 第1轮]\n{FIRST_OBJECTION}" in prompt
        ), source_line)
        # Open and close each prompt in turn, since its body contains peer seat names.
        details = ui.task_card(task).locator("details.prompt-box").first
        details.locator("summary").click()
        checks.check(f"{task['provider']} visibly receives the saved targeted prompt", (
            details.locator("pre").is_visible() and details.locator("pre").text_content() == task["prompt"]
        ))
        details.locator("summary").click()

    ui.answer_stage(session_id, "critique", {
        "chatgpt": f"TARGET_RESPONSE 加一次离线采集复测，按结果决定是否上线。[{first_source}]",
        "gemini": "支持先复测，证据不足就推迟上线。",
        "deepseek": "如果离线复现覆盖目标场景，我会重新考虑反对。",
    })
    second_proposal = ui.wait_for_stage(session_id, "proposal")
    response, = archived(second_proposal, "critique", 2, "chatgpt")
    proposal_task, = second_proposal["tasks"]
    checks.check("The v2 drafter receives both the objection and the sourced targeted response", (
        proposal_task["version"] == 2 and FIRST_OBJECTION in proposal_task["prompt"]
        and response["answer"] in proposal_task["prompt"]
    ))
    second_candidate = f"CANDIDATE_V2 先验证桌面与离线采集，复测通过后才决定是否上线。[{response['sourceId']}]"
    ui.answer_stage(session_id, "proposal", {proposal_task["provider"]: second_candidate})
    vote_two = ui.wait_for_stage(session_id, "vote")
    checks.check("Fresh vote tasks ask all three seats to decide on the complete v2", (
        vote_two["round"] == 2 and len(vote_two["tasks"]) == 3 and all(
            task["version"] == 2 and second_candidate in task["prompt"]
            and "仅供对照，不代表本轮态度" in task["prompt"]
            for task in vote_two["tasks"]
        )
    ))
    current_yes = next(task for task in vote_two["tasks"] if task["provider"] == "chatgpt")
    for task in (old_yes, current_yes):
        error = runtime.error({"type": "act", "id": session_id, "action": "answer", "payload": {
            "taskId": task["id"], "stage": "vote", "round": 2, "version": 1,
            "stance": "agree", "text": STALE_VOTE,
        }})
        checks.check(f"Stale v1 submission is refused on a v{task['version']} task ID", "stale submission" in error, error)
    checks.check("Rejections leave all three v2 tasks untouched", runtime.get(session_id)["tasks"] == vote_two["tasks"])

    ui.answer_stage(session_id, "vote", {
        "chatgpt": "V2_CHATGPT 同意按复测结果决定。",
        "gemini": "V2_GEMINI 同意先验证桌面与离线采集。",
        "deepseek": FINAL_OBJECTION,
    }, STANCES)
    finished = ui.wait_for_stage(session_id, "done")
    final_votes = archived(finished, "vote", 2)
    final_oppose, = archived(finished, "vote", 2, "deepseek")
    final_source = final_oppose["sourceId"]
    checks.check("The second opposition ends the session, with a fresh v2 vote from every seat", (
        finished["round"] == 2 and finished["stopReason"] == "unresolved-opposition" and not finished["tasks"]
        and {task["round"] for task in finished["history"] if task["stage"] == "critique"} == {1, 2}
        and len(final_votes) == 3 and all(task["version"] == 2 for task in final_votes)
        and {task["provider"]: task["stance"] for task in final_votes} == STANCES
    ))

    page.reload(wait_until="domcontentloaded")
    report = page.locator("section.report")
    report.get_by_text("仍有明确反对", exact=True).wait_for()
    checks.check("After reload the report shows v2 and the unresolved objection", (
        second_candidate.split("[")[0] in report.inner_text() and FINAL_OBJECTION in report.inner_text()
    ))
    report.locator("details").first.locator("summary").click()
    for source, objection in ((first_source, FIRST_OBJECTION), (final_source, FINAL_OBJECTION)):
        report.get_by_role("link", name=f"跳到来源 {source} 的原文", exact=True).locator("visible=true").first.click()
        target = page.locator(f"article.timeline-item.is-cited[data-source-id='{source}']")
        checks.check(f"Report citation {source} jumps to the original objection", objection in target.inner_text())

    with page.expect_download() as download:
        report.get_by_role("button", name="导出 Markdown", exact=True).click()
    path = out_dir / "vote-round-report.md"
    download.value.save_as(path)
    exported = path.read_text(encoding="utf-8")
    checks.check("Markdown preserves both vote versions and cites the final disagreement separately", (
        "未解决分歧：当前版本仍有明确反对，未形成共识。" in exported
        and f"明确反对：`deepseek` — {FINAL_OBJECTION} [{final_source}]" in exported
        and "往轮表态（不计入当前版本）" in exported
        and f"v1 · `deepseek`：反对 — {FIRST_OBJECTION} [{first_source}]" in exported
        and first_candidate in exported and second_candidate in exported and response["answer"] in exported
        and STALE_VOTE not in exported
    ))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()
    out_dir = args.out.expanduser().resolve() if args.out else Path(tempfile.mkdtemp(prefix="ai-arena-vote-round-"))
    if out_dir.is_relative_to(REPO_ROOT):
        raise AcceptanceError("Write acceptance artifacts outside the repository.")
    out_dir.mkdir(parents=True, exist_ok=True)
    ext_dir = REPO_ROOT / "extension"
    executable = find_chromium_executable()
    checks = CheckLog()
    attempts, page_errors = [], []

    with tempfile.TemporaryDirectory(prefix="ai-arena-vote-round-profile-") as profile, sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            profile, executable_path=str(executable) if executable else None,
            headless=not args.headed, accept_downloads=True,
            args=[
                f"--disable-extensions-except={ext_dir}", f"--load-extension={ext_dir}",
                "--disable-background-networking", "--no-proxy-server", "--host-resolver-rules=MAP * ~NOTFOUND",
            ],
        )
        try:
            install_network_guard(context, attempts)
            context.set_default_timeout(8000)
            page = context.new_page()
            page.on("pageerror", lambda error: page_errors.append(str(error)))
            ext_id = extension_id_from_path(ext_dir)
            page.goto(f"chrome-extension://{ext_id}/workspace.html", wait_until="domcontentloaded")
            runtime = Runtime(page)
            ui = WorkspaceUI(page, read_providers(ext_dir), runtime)
            check_vote_round(page, ui, runtime, out_dir, checks)
            checks.check("No external site requests or page errors", not attempts and not page_errors, str(attempts + page_errors))
        finally:
            context.close()

    print(f"\n{len(checks.checks)} checks passed. Artifacts: {out_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AcceptanceError as exc:
        print(f"ACCEPTANCE FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
