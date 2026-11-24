#!/usr/bin/env python3
"""Isolated macOS UI acceptance for AI Arena (QA-only, no production edits).

Target: G1/G2/G3/G4. This tool builds a disposable copy of the current desktop
sources into a *separate* QA application bundle, injects ``qa_ui_driver.swift``
as the only ``@main`` entry, serves three loopback fixture pages, and drives the
real native window in the same process:

* NSAccessibility tree of this process (``AXUIElementCreateApplication(getpid())``)
  and ``AXPress`` for buttons / disclosures;
* the real ``NSTextView`` for typing;
* ``NSWindow`` resize and ``NSApp.appearance`` for wide/narrow and light/dark;
* ``cacheDisplay`` screenshots;
* CVDisplayLink ticks delivered to the main runloop plus main-runloop busy
  intervals, with sample count, p50/p95/max and over-budget counts.

No external AX client, no Screen Recording permission, no activation of the
window, no real accounts, no writes outside the evidence directory (/tmp) and a
temporary build directory. The production sources are only read and copied.

Run:

    python3 tests/qa_ui_acceptance.py --out /tmp/arena-ui-$(date +%s)

Exit code 0 means every configured step passed. A fresh directory is required.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from fixtures import PROVIDERS, markup  # noqa: E402
from qa_app import QA_BUNDLE_ID  # noqa: E402
from swift_sources import stage_desktop_sources  # noqa: E402

QUESTION = "【UI 验收】如果只有两个周末，个人笔记工具应先做移动端采集，还是先补桌面检索？请给出判断和一个可验证的理由。"

# Long fixture answers make the report genuinely scrollable and give the
# disclosure/scroll measurements real content. They stay plain text because the
# fixture pages only render text.
LONG_ANSWER = (
    "\n\n## 判断\n先补桌面检索，再用一个周末做移动端采集。理由是检索失败会同时伤害已有笔记的可用性，"
    "而采集缺失只影响新增条目；先修影响面更大的环节，才容易在下个周末验证。"
    "\n\n## 可验证的理由\n- 已有笔记的检索命中率可以直接用固定题集测量；采集量只能间接反映价值。"
    "\n- 检索补齐后，旧笔记立刻进入使用；采集补齐后还需要内容积累。"
    "\n- 两个周末的边界内，检索方案可以一次验收，采集流程需要设备与同步环境。"
)
LONG_PROPOSAL = (
    "\n\n## 候选结论\n先补桌面检索，并保留最小采集入口。"
    "\n\n## 成立条件\n- 固定 20 条真实问题的检索题集，命中率达到约定阈值。"
    "\n- 采集入口只保留粘贴与分享，不同时改同步。"
    "\n\n## 未决分歧\n移动端采集的收益是否足以占用第二个周末，仍需用真实使用频率判断。[S1]"
)
# 产品要求表态以最后一行的 STANCE: 为准。这里给真实、无条件的理由，并让
# STANCE: agree 严格落在最后一行；不能为了夹具方便把表态埋在中段。
LONG_VOTE = (
    "\n\n理由：检索缺失会直接降低已有笔记的可用性，而桌面检索能在两个周末内"
    "用固定题集验收，收益不依赖尚未验证的移动端采集。因此无条件同意当前候选。"
    "\nSTANCE: agree"
)


def long_page(index: int) -> bytes:
    """Patch the shared fixture page with long, report-shaped answers."""
    page = markup(index).decode()
    provider_token = json.dumps(PROVIDERS[index])
    answer = json.dumps(LONG_ANSWER, ensure_ascii=False)
    proposal = json.dumps(LONG_PROPOSAL, ensure_ascii=False)
    vote = json.dumps(LONG_VOTE, ensure_ascii=False)
    segment = json.dumps(
        "这一段用于本地 UI 验收：长报告需要真实段落、真实换行和足够的滚动高度，"
        "但不包含任何账号、网络或个人数据。",
        ensure_ascii=False,
    )
    page = page.replace(
        "const tail=stage==='vote'?'\\nSTANCE: agree':(stage==='proposal'?'\\n建议先验证检索。[S1]':'\\n测试结论。');",
        f"const tail=stage==='vote'?{vote}:(stage==='proposal'?{proposal}:{answer});",
    )
    chunk = (
        "row.text+=(i===1?'':' ')+" + provider_token
        + "+' '+seq+' 第'+i+'段的网页原文。';"
    )
    replacement = (
        "row.text+=(i===1?'':' ')+" + provider_token
        + "+' '+seq+' 第'+i+'段。'+" + segment + ";"
    )
    page = page.replace(chunk, replacement)
    return page.encode()


def observed_hook(page: bytes) -> bytes:
    text = page.decode()
    text = text.replace(
        "window.turns.push(row);",
        "window.turns.push(row);"
        "fetch('/observed',{method:'POST',body:JSON.stringify({site:location.pathname.slice(1),prompt})});",
    )
    text = text.replace(
        "answer.textContent=row.text;",
        "answer.textContent=row.text;"
        "if(row.complete)fetch('/observed',{method:'POST',body:JSON.stringify({site:location.pathname.slice(1),answer:row.text})});",
    )
    return text.encode()


class Fixture:
    def __init__(self, long_reports: bool):
        self.long_reports = long_reports
        self.events: list[dict] = []
        self.lock = threading.Lock()
        self.cookie = "arena_ui_" + uuid.uuid4().hex + "=1"
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                path = urlparse(self.path).path.strip("/")
                if path.startswith("pixel/") and path[6:] in PROVIDERS:
                    png = base64.b64decode(
                        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jG2kAAAAASUVORK5CYII="
                    )
                    self.send_response(200)
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Type", "image/png")
                    self.end_headers()
                    self.wfile.write(png)
                    return
                if path not in PROVIDERS:
                    self.send_error(404)
                    return
                index = PROVIDERS.index(path)
                page = long_page(index) if fixture.long_reports else markup(index)
                page = observed_hook(page)
                content = page + f'<img src="/pixel/{path}" alt="夹具图片">'.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(content)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Set-Cookie", f"{fixture.cookie}; Max-Age=600; Path=/; SameSite=Lax")
                self.end_headers()
                self.wfile.write(content)

            def do_POST(self):
                if self.path != "/observed":
                    self.send_error(404)
                    return
                data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                with fixture.lock:
                    fixture.events.append(data)
                self.send_response(204)
                self.end_headers()

            def log_message(self, *_):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def build_app(source: Path, build: Path, driver: Path, optimize: bool) -> Path:
    """Compile an isolated QA app from a frozen copy of the Swift sources."""
    src = build / "src"
    shutil.rmtree(src, ignore_errors=True)
    stage_desktop_sources(source, src)
    shutil.copy2(driver, src / "qa_ui_driver.swift")

    app = build / "AI Arena UI QA.app"
    shutil.rmtree(app, ignore_errors=True)
    resources = app / "Contents" / "Resources"
    (app / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)

    with (source / "desktop/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    info.update(
        CFBundleName="AI Arena UI QA",
        CFBundleDisplayName="AI Arena UI QA",
        CFBundleIdentifier=QA_BUNDLE_ID,
        CFBundleExecutable="AIQAUI",
        LSUIElement=True,
    )
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)

    icon = source / "desktop/assets/ArenaIcon.icns"
    if icon.is_file() and icon.stat().st_size:
        shutil.copy2(icon, resources / "ArenaIcon.icns")

    shutil.copy2(source / "shared/web-driver.js", resources / "web-driver.js")
    node_script = r"""
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, resources] = process.argv.slice(2);
const source = name => path.join(root, 'shared', name + '.js');
const { webSiteConfig } = await import(pathToFileURL(source('provider-web-configs')));
const sites = Object.fromEntries(['chatgpt', 'gemini', 'deepseek'].map(id => [id, webSiteConfig(id)]));
fs.writeFileSync(path.join(resources, 'sites.json'), JSON.stringify(sites));
const core = ['providers', 'core'].map(name => fs.readFileSync(source(name), 'utf8')
  .replace(/^import .* from ['"].*['"];\s*$/gm, '')
  .replace(/^export (?=(const|function) )/gm, '')).join('\n');
fs.writeFileSync(path.join(resources, 'arena-core.js'), core);
"""
    subprocess.run(
        ["node", "--input-type=module", "-", str(source), str(resources)],
        input=node_script,
        text=True,
        check=True,
    )

    binary = app / "Contents" / "MacOS" / "AIQAUI"
    command = [
        "xcrun", "swiftc",
        "-swift-version", "5",
        "-target", f"{os.uname().machine}-apple-macos13.0",
        "-parse-as-library",
        "-framework", "WebKit",
        "-framework", "SwiftUI",
        "-framework", "JavaScriptCore",
        "-framework", "CoreVideo",
        "-framework", "AppKit",
        *[str(path) for path in sorted(src.glob("*.swift"))],
        "-o", str(binary),
    ]
    command.insert(command.index("-o"), "-O" if optimize else "-Onone")
    compiled = subprocess.run(command, text=True, capture_output=True)
    (build / "compile.log").write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode != 0:
        raise SystemExit(
            "Swift build failed; see compile.log\n"
            + "\n".join(
                line for line in compiled.stderr.splitlines()
                if "error:" in line
            )[:4000]
        )

    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "-R",
         f'=identifier "{QA_BUNDLE_ID}"', str(app)],
        check=True,
    )
    return app


QA_EXECUTABLE = "AIQAUI"


def validate_qa_app(app: Path) -> Path:
    """Refuse anything that is not our signed, QA-identified bundle.

    This is the harness-side counterpart of the in-process preflight: a mistyped
    ``--app`` must never launch the personal app, its history, or a real site.
    """
    info_path = app / "Contents" / "Info.plist"
    if not info_path.is_file():
        raise SystemExit(f"not an app bundle: {app}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != QA_BUNDLE_ID:
        raise SystemExit(
            f"refusing to launch {app}: bundle id is "
            f"{info.get('CFBundleIdentifier')!r}, expected {QA_BUNDLE_ID!r}"
        )
    if info.get("CFBundleExecutable") != QA_EXECUTABLE:
        raise SystemExit(
            f"refusing to launch {app}: executable is "
            f"{info.get('CFBundleExecutable')!r}, expected {QA_EXECUTABLE!r}"
        )
    executable = app / "Contents" / "MacOS" / QA_EXECUTABLE
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise SystemExit(f"refusing to launch {app}: missing QA executable")
    verify = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "-R",
         f'=identifier "{QA_BUNDLE_ID}"', str(app)],
        capture_output=True, text=True,
    )
    if verify.returncode != 0:
        raise SystemExit(
            f"refusing to launch {app}: signature check failed\n{verify.stderr}"
        )
    return app


def default_steps(question: str) -> list[dict]:
    return [
        {"op": "waitSeats", "timeout": 50, "name": "seats-ready"},
        {"op": "capture", "name": "opening", "window": "main"},
        {"op": "inspect", "name": "opening", "window": "main"},
        {"op": "type", "text": question},
        {"op": "click", "label": "开始讨论", "window": "main", "expectText": "本场问题"},
        {"op": "waitStage", "stage": "independent", "timeout": 40},
        {"op": "capture", "name": "running", "window": "main"},
        {"op": "click", "label": "暂停", "window": "main", "settle": 0.7},
        {"op": "assertModel", "paused": True},
        {"op": "capture", "name": "paused", "window": "main"},
        {"op": "click", "label": "继续", "window": "main", "settle": 0.7},
        {"op": "waitStage", "stage": "done", "timeout": 260},
        {"op": "sleep", "seconds": 0.8},
        {"op": "capture", "name": "done", "window": "main"},
        {"op": "click", "label": "查看报告", "window": "main"},
        {"op": "waitWindow", "title": "本场详情", "timeout": 20},
        {"op": "inspect", "name": "report", "window": "details"},
        {"op": "capture", "name": "report", "window": "details"},
        {"op": "perf", "mode": "toggle", "window": "details", "label": "完整报告",
         "cycles": 3, "name": "report-expand-collapse", "capture": "report-expanded"},
        {"op": "perf", "mode": "scroll", "window": "details", "name": "report-scroll",
         "durationMs": 1800, "captureMid": "report-scrolling"},
        {"op": "capture", "name": "report-scrolled", "window": "details"},
        {"op": "appearance", "value": "dark"},
        {"op": "capture", "name": "report-dark", "window": "details"},
        {"op": "appearance", "value": "light"},
        {"op": "capture", "name": "report-light", "window": "details"},
        {"op": "resize", "window": "details", "width": 900, "height": 600},
        {"op": "capture", "name": "report-narrow", "window": "details"},
        {"op": "resize", "window": "details", "width": 1440, "height": 900},
        {"op": "capture", "name": "report-wide", "window": "details"},
        {"op": "click", "label": "候选全文", "window": "details", "expectValue": "已展开"},
        {"op": "capture", "name": "candidate-expanded", "window": "details"},
        {"op": "click", "labelContains": "起草 ·", "window": "details"},
        {"op": "waitText", "text": "返回报告", "window": "details"},
        {"op": "capture", "name": "source", "window": "details"},
        {"op": "click", "label": "返回报告", "window": "details"},
        {"op": "waitText", "text": "讨论报告", "window": "details"},
        {"op": "capture", "name": "back-to-report", "window": "details"},
        {"op": "reduceMotion", "value": True},
        {"op": "perf", "mode": "toggle", "window": "details", "label": "候选全文",
         "cycles": 2, "name": "candidate-toggle-reduce-motion", "settleMs": 180},
        {"op": "reduceMotion", "value": False},
        {"op": "openHistory"},
        {"op": "sleep", "seconds": 0.8},
        {"op": "capture", "name": "history", "window": "main"},
        {"op": "resize", "window": "main", "width": 900, "height": 600},
        {"op": "capture", "name": "history-narrow", "window": "main"},
        {"op": "inspect", "name": "history", "window": "main"},
    ]


def check_result(result: dict, requested: list[dict], require_default: bool) -> list[str]:
    problems: list[str] = []
    if not result.get("ok"):
        problems.append("result.ok is false: " + str(result.get("fatal", "")))
    steps = result.get("steps", [])
    if len(steps) != len(requested):
        problems.append(f"expected {len(requested)} steps, got {len(steps)}")
    for step in steps:
        if not step.get("ok", False):
            problems.append(f"step {step.get('index')} {step.get('name')} failed: {step.get('error')}")
    if not require_default:
        return problems
    names = {capture.get("name") for capture in result.get("captures", [])}
    required = {
        "opening", "running", "paused", "done", "report", "report-expanded",
        "report-scrolled", "report-dark", "report-light", "report-narrow",
        "report-wide", "candidate-expanded", "source", "back-to-report", "history",
        "history-narrow",
    }
    missing = sorted(required - names)
    if missing:
        problems.append("missing captures: " + ", ".join(missing))
    perf = result.get("metrics", [])
    if not any(metric.get("mode") == "scroll" for metric in perf):
        problems.append("no scroll performance metric")
    if not any(metric.get("mode") == "toggle" for metric in perf):
        problems.append("no disclosure toggle performance metric")
    scroll = next((metric for metric in perf if metric.get("mode") == "scroll"), None)
    if scroll:
        if scroll.get("samples", 0) < 30:
            problems.append(f"scroll display-link samples too small: {scroll.get('samples')}")
        if scroll.get("displayLink") != "CVDisplayLink(active displays)":
            problems.append("CVDisplayLink unavailable; scroll interval metric invalid")
    for metric in perf:
        if metric.get("overBudget") is None:
            problems.append(f"metric {metric.get('name')} missing overBudget")
    return problems


def summary_markdown(result: dict, events: list[dict]) -> str:
    lines = [
        "# AI Arena UI 验收",
        "",
        f"- ok: **{result.get('ok')}**",
        f"- bundle: `{result.get('bundleIdentifier')}`",
        f"- fixture: `{result.get('fixtureBase')}`",
        f"- 用时: {result.get('durationMs', 0) / 1000:.1f}s",
        f"- 回环观测消息: {len(events)}",
        "",
        "## 截图",
        "",
    ]
    for capture in result.get("captures", []):
        lines.append(
            f"- `{capture.get('file')}` · {capture.get('name')} · "
            f"{capture.get('window')} · {capture.get('pixels')}"
        )
    lines += ["", "## 性能样本（display link + 主线程，无屏幕录制）", ""]
    lines.append("| 指标 | 样本 | p50 ms | p95 ms | max ms | 超 1 帧 | 超 2 帧 |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for metric in result.get("metrics", []):
        stat = metric.get("intervalMs") if metric.get("mode") == "scroll" else metric.get("layoutMs")
        stat = stat or {}
        lines.append(
            f"| {metric.get('name')} | {metric.get('samples', 0)} | "
            f"{stat.get('p50', 0):.2f} | {stat.get('p95', 0):.2f} | "
            f"{stat.get('max', 0):.2f} | {metric.get('overBudget', 0)} | "
            f"{metric.get('overDoubleBudget', 0)} |"
        )
    lines += ["", "## 步骤", ""]
    for step in result.get("steps", []):
        mark = "ok" if step.get("ok") else "FAIL"
        lines.append(
            f"- {step.get('index'):02d} `{step.get('op')}` {step.get('name')} — "
            f"{mark} · {step.get('durationMs', 0):.0f}ms"
            + (f" · {step.get('error')}" if step.get("error") else "")
        )
    notes = result.get("notes", [])
    if notes:
        lines += ["", "## 标注", ""] + [f"- {note}" for note in notes]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path,
                        help="fresh evidence directory (use /tmp)")
    parser.add_argument("--steps", type=Path,
                        help="JSON array of driver steps (default: built-in scenario)")
    parser.add_argument("--source", type=Path, default=ROOT,
                        help="checkout to build from (default: this repository)")
    parser.add_argument("--from-head", action="store_true",
                        help="build a git HEAD snapshot instead of the working tree")
    parser.add_argument("--app", type=Path,
                        help="reuse a previously built QA app bundle")
    parser.add_argument("--keep-build", action="store_true",
                        help="keep the temporary build directory")
    parser.add_argument("--build-root", type=Path,
                        help="stable build directory; its QA app is reused unless --rebuild")
    parser.add_argument("--rebuild", action="store_true",
                        help="rebuild even if --build-root already contains the QA app")
    parser.add_argument("--optimize", action="store_true", default=True,
                        help="compile with -O (default; matches production build)")
    parser.add_argument("--fast-build", dest="optimize", action="store_false",
                        help="compile with -Onone for quicker iteration")
    parser.add_argument("--short-fixture", action="store_true",
                        help="use the short shared fixture answers instead of long reports")
    parser.add_argument("--timeout", type=float, default=330,
                        help="overall driver timeout in seconds")
    parser.add_argument("--question", default=QUESTION)
    args = parser.parse_args()

    out = args.out.resolve()
    if out.exists() and any(out.iterdir()):
        print(f"choose a fresh evidence directory: {out}", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)

    if args.steps:
        steps = json.loads(args.steps.read_text())
        if not isinstance(steps, list):
            print("--steps must contain a JSON array", file=sys.stderr)
            return 2
    else:
        steps = default_steps(args.question)
    (out / "steps.json").write_text(json.dumps(steps, ensure_ascii=False, indent=2))

    temporary_build = args.build_root is None
    build_root = Path(tempfile.mkdtemp(prefix="arena-ui-qa-")) if temporary_build else args.build_root.resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    fixture = Fixture(long_reports=not args.short_fixture)
    try:
        app = args.app
        cached = build_root / "AI Arena UI QA.app"
        if app is None and cached.exists() and not args.rebuild:
            app = cached
        if app is None:
            source = args.source.resolve()
            if args.from_head:
                snapshot = build_root / "snapshot"
                shutil.rmtree(snapshot, ignore_errors=True)
                snapshot.mkdir(parents=True)
                archive = subprocess.run(
                    ["git", "archive", "HEAD"], cwd=source, capture_output=True, check=True
                )
                subprocess.run(["tar", "-x", "-C", str(snapshot)], input=archive.stdout, check=True)
                source = snapshot
                print(f"source: git HEAD snapshot of {source}")
            else:
                print(f"source: working tree {source}")
            print("building isolated QA app…", flush=True)
            started = time.time()
            app = validate_qa_app(
                build_app(source, build_root, ROOT / "tests/qa_ui_driver.swift", args.optimize)
            )
            print(f"built {app} in {time.time() - started:.1f}s", flush=True)
        else:
            app = validate_qa_app(app.resolve())
            print(f"reusing QA app: {app}")

        result_path = out / "result.json"
        env = {
            **os.environ,
            "ARENA_FIXTURE_BASE": fixture.base,
            "ARENA_DATA_DIR": str(build_root / "data"),
            "ARENA_QA_UI_OUT": str(out),
            "ARENA_QA_UI_RESULT": str(result_path),
            "ARENA_QA_UI_STEPS": str(out / "steps.json"),
        }
        Path(env["ARENA_DATA_DIR"]).mkdir(parents=True, exist_ok=True)
        executable = app / "Contents" / "MacOS" / "AIQAUI"
        log_path = out / "app.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(
                [str(executable), "--qa-ui"],
                env=env,
                stdout=log,
                stderr=log,
                cwd=str(out),
            )
            deadline = time.time() + args.timeout
            seen = 0
            while process.poll() is None and time.time() < deadline:
                time.sleep(0.5)
                try:
                    snapshot = json.loads(result_path.read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    continue
                completed = len(snapshot.get("steps", []))
                while seen < completed:
                    step = snapshot["steps"][seen]
                    mark = "ok" if step.get("ok") else "FAIL"
                    print(
                        f"  {step.get('index', seen):02d} {step.get('op')} "
                        f"{step.get('name')} — {mark} "
                        f"({step.get('durationMs', 0):.0f}ms)",
                        flush=True,
                    )
                    seen += 1
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                print("driver timed out", file=sys.stderr)
                return 1
        if not result_path.exists():
            print(f"driver wrote no result; see {log_path}", file=sys.stderr)
            return 1
        result = json.loads(result_path.read_text())
        problems = check_result(result, steps, require_default=args.steps is None)
        (out / "summary.md").write_text(summary_markdown(result, fixture.events))
        if problems:
            print("FAIL", file=sys.stderr)
            for problem in problems:
                print(" - " + problem, file=sys.stderr)
            return 1
        print(f"PASS: {len(result['captures'])} captures, {len(result['steps'])} steps")
        scroll = next((m for m in result.get("metrics", []) if m.get("mode") == "scroll"), None)
        toggle = next((m for m in result.get("metrics", []) if m.get("mode") == "toggle"), None)
        if scroll:
            print(
                "  scroll: samples={samples} p95={p95:.2f}ms over-budget={over}".format(
                    samples=scroll.get("samples", 0),
                    p95=scroll.get("intervalMs", {}).get("p95", 0),
                    over=scroll.get("overBudget", 0),
                )
            )
        if toggle:
            print(
                "  toggle: samples={samples} p95={p95:.2f}ms over-budget={over}".format(
                    samples=toggle.get("samples", 0),
                    p95=toggle.get("layoutMs", {}).get("p95", 0),
                    over=toggle.get("overBudget", 0),
                )
            )
        print(f"evidence: {out}")
        return 0
    finally:
        fixture.close()
        if temporary_build and not args.keep_build:
            shutil.rmtree(build_root, ignore_errors=True)
        else:
            print(f"build kept: {build_root}")


if __name__ == "__main__":
    raise SystemExit(main())
