#!/usr/bin/env python3
"""G2/G4 native Chromium regression for current-candidate conditions in the report.

Run: python3 tests/report_conditions_acceptance.py [--out /tmp/arena-conditions]
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


OLD_CONDITION = "V1_CONDITION 先补线上样本。"
OLD_OPPOSITION = "V1_OPPOSITION 线上样本无法检验离线采集。"
CONDITION = (
    "V2_CONDITION 有条件同意。\n\n"
    "## 条件原文\n"
    "- 复现离线问题之后，再承诺修复。\n"
    "- <svg onload='window.__arenaProbe = true'></svg> **原样展示** [S1]"
)


def finish_discussion(ui: WorkspaceUI):
    session_id, _ = ui.create_debate("验收：是否优先修复离线采集？", ["chatgpt", "gemini"])
    ui.answer_stage(session_id, "independent", {
        "chatgpt": "先确认问题的规模。",
        "gemini": "必须区分离线与线上。",
    })
    for version in (1, 2):
        ui.answer_stage(session_id, "critique", {
            "chatgpt": f"第 {version} 轮：补齐线下证据后再承诺日期。",
            "gemini": f"第 {version} 轮：用离线环境复现用户的情况。",
        })
        proposal = ui.wait_for_stage(session_id, "proposal")
        source = next(task["sourceId"] for task in reversed(proposal["history"]) if task["stage"] == "critique")
        candidate = proposal["tasks"][0]
        ui.answer_stage(session_id, "proposal", {
            candidate["provider"]: f"候选 v{version}：先复现，再决定修复范围。[{source}]",
        })
        ui.answer_stage(session_id, "vote", {
            "chatgpt": OLD_CONDITION if version == 1 else CONDITION,
            "gemini": OLD_OPPOSITION if version == 1 else "同意按复现结果决定。",
        }, stances={"chatgpt": "conditional", "gemini": "oppose" if version == 1 else "agree"})
    return ui.wait_for_stage(session_id, "done")


def check_report(page, width: int, current: dict, previous: list[dict], checks: CheckLog, out: Path):
    page.set_viewport_size({"width": width, "height": 800})
    page.reload(wait_until="domcontentloaded")
    report = page.locator("section.report")
    detail = report.locator("details.report-details")
    group = report.locator("#report-open-conditions")
    group.wait_for(state="visible")
    row = group.locator(".stance-row")
    reason = row.locator(".stance-reason")
    source = row.locator("a.report-cite")
    checks.check(f"{width}px shows one full v2 reason attributed to ChatGPT", (
        row.count() == 1 and row.locator(".stance-name").inner_text() == "ChatGPT"
        and row.locator(".stance-chip").inner_text() == "有条件同意"
        and reason.text_content() == CONDITION == current["answer"]
        and source.count() == 1 and source.get_attribute("data-source-id") == current["sourceId"]
    ))
    checks.check(f"{width}px default report excludes superseded votes and displays the reason once", (
        not detail.evaluate("element => element.open")
        and all(vote["answer"] not in report.inner_text() for vote in previous)
        and report.inner_text().count("V2_CONDITION") == 1
    ))
    checks.check(f"{width}px treats markup as literal and fits the viewport", (
        reason.locator("*").count() == 0
        and reason.evaluate("element => getComputedStyle(element).whiteSpace") == "pre-wrap"
        and page.evaluate("!window.__arenaProbe && document.documentElement.scrollWidth <= innerWidth")
    ))
    original_hash = page.evaluate("location.hash")
    report.locator("a[href='#report-open-conditions']").click()
    checks.check(f"{width}px top link focuses the conditions without changing the route or opening details", (
        group.evaluate("""element => {
            const rect = element.getBoundingClientRect();
            return element === document.activeElement && rect.top < innerHeight && rect.bottom > 0;
        }""")
        and page.evaluate("location.hash") == original_hash
        and not detail.evaluate("element => element.open")
    ))
    page.screenshot(path=out / f"conditions-{width}.png")
    source.click()
    original = page.locator(f".timeline-item.is-cited[data-source-id='{current['sourceId']}']")
    checks.check(f"{width}px source link reaches the current vote verbatim", (
        original.locator(".timeline-answer").text_content() == CONDITION
    ))
    detail.locator("summary").click()
    checks.check(f"{width}px original v1 votes remain in the opened report and cited history", (
        detail.evaluate("element => element.open")
        and all(
            vote["answer"] in detail.inner_text()
            and page.locator(f".timeline-item[data-source-id='{vote['sourceId']}'] .timeline-answer")
            .text_content() == vote["answer"]
            for vote in previous
        )
    ))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    out = args.out.expanduser().resolve() if args.out else Path(tempfile.mkdtemp(prefix="arena-conditions-"))
    if out.is_relative_to(REPO_ROOT):
        raise AcceptanceError("Write acceptance artifacts outside the repository.")
    out.mkdir(parents=True, exist_ok=True)
    extension = REPO_ROOT / "extension"
    executable = find_chromium_executable()
    checks = CheckLog()
    requests, errors = [], []
    with tempfile.TemporaryDirectory(prefix="arena-conditions-profile-") as profile, sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            profile, executable_path=str(executable) if executable else None, headless=True,
            accept_downloads=True, viewport={"width": 1280, "height": 800}, args=[
                f"--disable-extensions-except={extension}", f"--load-extension={extension}",
                "--disable-background-networking", "--no-proxy-server", "--host-resolver-rules=MAP * ~NOTFOUND",
            ],
        )
        try:
            install_network_guard(context, requests)
            page = context.new_page()
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.set_default_timeout(8000)
            page.goto(f"chrome-extension://{extension_id_from_path(extension)}/workspace.html")
            ui = WorkspaceUI(page, read_providers(extension), Runtime(page))
            session = finish_discussion(ui)
            votes = [task for task in session["history"] if task["stage"] == "vote"]
            previous = [vote for vote in votes if vote["version"] == 1]
            current, = [vote for vote in votes if vote["version"] == 2 and vote["stance"] == "conditional"]
            checks.check("Saved debate ends with conditional agreement on v2", (
                session["stopReason"] == "conditional-agreement"
                and {vote["answer"] for vote in previous} == {OLD_CONDITION, OLD_OPPOSITION}
            ))
            for width in (1280, 390):
                check_report(page, width, current, previous, checks, out)
            with page.expect_download() as download:
                page.locator("section.report").get_by_role("button", name="导出 Markdown", exact=True).click()
            exported = out / "report.md"
            download.value.save_as(exported)
            markdown = exported.read_text(encoding="utf-8")
            checks.check("Markdown preserves the exact current reason and labels v1 votes as prior", (
                f"附加条件：`chatgpt` — {CONDITION} [{current['sourceId']}]" in markdown
                and "往轮表决（不计入当前版本）" in markdown
                and all(f"{vote['answer']} [{vote['sourceId']}]" in markdown for vote in previous)
            ))
            checks.check("No external requests or workspace script errors", not requests and not errors, str(requests + errors))
        finally:
            context.close()
    print(f"\n{len(checks.checks)} checks passed. Artifacts: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
