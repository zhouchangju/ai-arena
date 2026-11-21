#!/usr/bin/env python3
"""Real Chromium acceptance for G1/R09 two-seat web automation.

Loads the unpacked MV3 extension, serves tests/web-driver-fixture.html on a
temporary loopback port, configures both seats through workspace.html's own
chrome.runtime.sendMessage, starts background automation, and polls the real
session/run while both fixture tabs are driven by web-driver.js.

Contract pinned from extension/automation.js and connections.js:
  automation.config {provider, config:{url, selectors}}
  create {question, providers:['local-a','local-b']}
  automation.start {id}; get {id}; automation.info for polling.

Passing means: 7 unique submissions, a proposal with real [S#] citations, both
seats voting explicitly on the same version, a non-draft done report, and no
external request or navigation. Any paused/stale/lastError terminal stops the
run.

Loopback access, replay-verified:
  * default headless Chromium cannot click the native optional-permission dialog,
    so this run loads a TEMPORARY COPY of the extension whose manifest moves the
    already-declared localhost/127.0.0.1 entries from optional_host_permissions
    to host_permissions. The production extension/ directory is never edited and
    is hash-checked before and after the run.
  * --headed / --interactive-permission load the original extension and require a
    real grant from the user-facing dialog; without the grant the run fails at
    that stage instead of faking access.

Run: python3 tests/auto_acceptance.py --out /tmp/ai-arena-auto
     python3 tests/auto_acceptance.py --out /tmp/ai-arena-auto --headed --interactive-permission
"""
from __future__ import annotations

import argparse, copy, functools, hashlib, json, os, re, shutil, sys, tempfile, threading, time, traceback
from html import unescape
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

try:
    from playwright.sync_api import Error as PWError, TimeoutError as PWTimeout, sync_playwright
except ImportError as exc:
    print(f"Playwright Python is required: {exc}", file=sys.stderr)
    raise SystemExit(2)

ROOT, TESTS, EXT = Path(__file__).resolve().parents[1], Path(__file__).resolve().parents[1] / "tests", Path(__file__).resolve().parents[1] / "extension"
FIXTURE = TESTS / "web-driver-fixture.html"
PROVIDERS = ("local-a", "local-b")
STANCES = {"agree", "conditional", "oppose"}
EXPECTED = 7
LOOPBACK = {"127.0.0.1", "localhost"}
QUESTION = ("G1/R09 自动验收固定题：只有两个周末时，个人笔记工具应先做移动端采集，"
            "还是先补桌面检索？请给出判断、最强依据、反例和改变主张的条件。")
DEFAULT_SELECTORS = {"input": "#composer", "send": "#send", "user": "#log .turn.user .msg",
                     "answer": "#log .turn.answer .msg", "stop": "#stop", "done": "#done"}
CALL_JS = """(payload) => new Promise((resolve) => {
  let done = false; const finish = (v) => { if (!done) { done = true; resolve(v); } };
  const timer = setTimeout(() => finish({__error: 'runtime message timeout'}), 25000);
  try { chrome.runtime.sendMessage(payload, (reply) => { clearTimeout(timer);
    const err = chrome.runtime.lastError;
    finish(err ? {__error: err.message || String(err)} : (reply ?? {__error: 'empty reply'}));
  }); } catch (e) { clearTimeout(timer); finish({__error: String(e && e.message || e)}); }
});"""


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def log(message):
    print(message, flush=True)


def selectors():
    """Use the fixture's own advertised selector block; never guess CSS."""
    text = FIXTURE.read_text(encoding="utf-8")
    match = re.search(r'<pre id="selectors">\s*(\{.*?\})\s*</pre>', text, re.S)
    match = match or re.search(r"__arenaFixtureSelectors\s*=\s*(\{.*?\});", text, re.S)
    if not match:
        return dict(DEFAULT_SELECTORS)
    found, aliases = json.loads(unescape(match.group(1))), {"composer": "input", "submit": "send", "prompt": "input"}
    out = dict(DEFAULT_SELECTORS)
    for key, value in found.items():
        if aliases.get(key, key) in out:
            out[aliases.get(key, key)] = value
    return out


def chromium():
    env = os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
    if env and Path(env).expanduser().is_file():
        return Path(env).expanduser()
    cache = Path.home() / "Library" / "Caches" / "ms-playwright"
    patterns = ["chromium-*/chrome-mac-arm64/*.app/Contents/MacOS/*", "chromium-*/chrome-mac/*.app/Contents/MacOS/*",
                "chromium-*/chrome-linux64/chrome", "chromium-*/chrome-linux/chrome"]
    found = [p for pattern in patterns for p in cache.glob(pattern) if p.is_file()]
    return max(found, key=lambda p: int(re.search(r"chromium-(\d+)", str(p)).group(1))) if found else None


def hostname_of(pattern):
    try:
        return (urlsplit(pattern).hostname or "").lower()
    except ValueError:
        return ""


def prepare_extension(source, keep_original):
    """Decide which extension directory Chrome loads; never edit the production one.

    Replay finding: default headless Chromium cannot show or accept the native
    optional-permission dialog, so `chrome.permissions.request` never resolves and
    automation stops at "尚未授予 http://127.0.0.1/* 的访问权限". For that path only a
    temporary COPY is loaded, and the loopback entries already declared under
    optional_host_permissions are moved into host_permissions *in the copy*.
    Headed / --interactive-permission runs load the original extension and require a
    real grant through the dialog.
    """
    manifest_path = source / "manifest.json"
    digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if keep_original:
        return source, {
            "mode": "original-optional-permission",
            "loaded_path": str(source),
            "production_manifest_sha256": digest,
            "note": ("Original unpacked extension. Loopback hosts stay optional, so the run must "
                     "obtain a real grant from the user-facing permission dialog."),
        }

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    optional = list(manifest.get("optional_host_permissions") or [])
    moved = [pattern for pattern in optional if hostname_of(pattern) in LOOPBACK]
    remaining = [pattern for pattern in optional if pattern not in moved]
    if not moved:
        raise AssertionError(
            "headless test copy needs loopback entries in optional_host_permissions; "
            f"found {optional!r}"
        )

    target = Path(tempfile.mkdtemp(prefix="ai-arena-auto-ext-")) / source.name
    shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__", ".DS_Store", ".git"))
    patched = copy.deepcopy(manifest)
    hosts = list(patched.get("host_permissions") or [])
    for pattern in moved:
        if pattern not in hosts:
            hosts.append(pattern)
    patched["host_permissions"] = hosts
    if remaining:
        patched["optional_host_permissions"] = remaining
    else:
        patched.pop("optional_host_permissions", None)
    (target / "manifest.json").write_text(
        json.dumps(patched, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return target, {
        "mode": "headless-test-copy",
        "loaded_path": str(target),
        "production_manifest_sha256": digest,
        "test_copy_manifest_sha256": hashlib.sha256((target / "manifest.json").read_bytes()).hexdigest(),
        "moved_optional_to_host_permissions": moved,
        "remaining_optional_host_permissions": remaining,
        "note": ("TEST COPY ONLY. Default headless Chromium cannot click the native "
                 "optional-permission dialog, so the loopback entries already listed in "
                 "optional_host_permissions were moved into host_permissions inside this "
                 "temporary copy. No production file was edited."),
    }


CONTAINS_JS = """async () => {
  if (!chrome.permissions || typeof chrome.permissions.contains !== 'function') {
    return {supported: false, granted: false};
  }
  const origins = ['http://127.0.0.1/*', 'http://localhost/*'];
  return {supported: true, granted: await chrome.permissions.contains({origins})};
}"""

REQUEST_JS = """() => {
  const origins = ['http://127.0.0.1/*', 'http://localhost/*'];
  window.__arenaGrant = null;
  const b = document.createElement('button');
  b.id = '__arena_grant'; b.textContent = 'grant';
  b.style.cssText = 'position:fixed;left:0;top:0;z-index:2147483647';
  b.onclick = () => {
    try {
      chrome.permissions.request({origins}, (granted) => {
        const err = chrome.runtime.lastError;
        window.__arenaGrant = {granted: Boolean(granted), error: err ? err.message : ''};
      });
    } catch (e) {
      window.__arenaGrant = {granted: false, error: String(e)};
    }
  };
  document.body.append(b);
  return true;
}"""


def call(page, payload):
    reply = page.evaluate(CALL_JS, payload)
    if not isinstance(reply, dict) or "__error" in reply:
        raise AssertionError(f"{payload.get('type')} failed: {reply}")
    return reply


def ok(page, payload):
    reply = call(page, payload)
    if not reply.get("ok"):
        raise AssertionError(f"{payload.get('type')} refused: {reply.get('error', reply)}")
    return reply


def wait_until(page, probe, timeout=15000, interval=0.1):
    """Poll from Python instead of page.wait_for_function.

    wait_for_function injects a string expression that the extension page's
    MV3 CSP blocks (unsafe-eval), aborting the run before any seat is driven.
    page.evaluate calls a function object, so it works under the same CSP.
    """
    deadline = time.monotonic() + timeout / 1000.0
    while True:
        try:
            if probe():
                return True
        except PWError:
            pass  # navigation / context swap: keep polling until the deadline
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)


def fixture_pages(context):
    pages = {}
    for page in context.pages:
        match = re.search(r"web-driver-fixture\.html\?[^#]*seat=([AB])(?:&|$)", page.url)
        if match:
            pages[match.group(1)] = page
    return pages


def user_texts(page, css):
    try:
        values = page.eval_on_selector_all(css, "els => els.map(e => e.innerText || e.textContent || '')")
    except PWError:
        return []
    return [re.sub(r"\s+", " ", value).strip() for value in values if str(value).strip()]


def grant_loopback(page, mode):
    """Make loopback access usable and report exactly how it was obtained.

    headless-test-copy: host_permissions in the temporary copy already grant it; no
    dialog is involved and the harness fails if the grant is missing.
    original-optional-permission: a real click on a real page control asks Chrome;
    the run only continues when the user-facing dialog actually granted access.
    """
    state = page.evaluate(CONTAINS_JS)
    if not state.get("supported"):
        log("  permission: chrome.permissions API unavailable; loopback origin checks still apply")
        return {"supported": False, "granted": False, "dialog": False, "mode": mode}
    if state.get("granted"):
        source = "test-copy host_permissions" if mode == "headless-test-copy" else "existing grant"
        log(f"  permission: loopback already granted via {source}")
        return {"supported": True, "granted": True, "dialog": False, "mode": mode, "source": source}
    if mode == "headless-test-copy":
        raise AssertionError(
            "test copy grants http://127.0.0.1/* and http://localhost/* from host_permissions, "
            "but chrome.permissions.contains still returned false"
        )

    log("  permission: requesting the optional host permission (native dialog must be granted)")
    page.evaluate(REQUEST_JS)
    page.click("#__arena_grant")
    granted = False
    if wait_until(page, lambda: page.evaluate("() => window.__arenaGrant ?? null") is not None, timeout=20000):
        result = page.evaluate("() => window.__arenaGrant")
        log(f"  permission: {result}")
        granted = bool(result and result.get("granted"))
    else:
        log("  permission: the native dialog request never resolved")
    try:
        page.evaluate("() => document.getElementById('__arena_grant')?.remove()")
    except PWError:
        pass
    if not granted:
        raise AssertionError(
            "optional loopback host permission was not granted by the real dialog; "
            "rerun with --headed and grant it, or omit --interactive-permission for the "
            "isolated headless test copy"
        )
    return {"supported": True, "granted": True, "dialog": True, "mode": mode}


def main():
    parser = argparse.ArgumentParser(description="AI Arena G1/R09 automation acceptance")
    parser.add_argument("--out", required=True, help="directory for screenshots/results")
    parser.add_argument("--headed", action="store_true")
    parser.add_argument("--interactive-permission", action="store_true",
                        help="load the original extension and require a real grant of the optional "
                             "loopback host permission (needs --headed; headless cannot show the dialog)")
    parser.add_argument("--keep-profile", action="store_true")
    parser.add_argument("--timeout", type=float, default=150.0)
    args = parser.parse_args()

    if args.interactive_permission and not args.headed:
        print("--interactive-permission needs --headed: headless Chromium cannot show the "
              "native optional-permission dialog", file=sys.stderr)
        return 2

    out = Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not FIXTURE.is_file() or not (EXT / "manifest.json").is_file():
        print("Not ready: fixture or unpacked extension is missing", file=sys.stderr)
        return 2

    selectors_map = selectors()
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=str(TESTS)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_port}"
    profile = Path(tempfile.mkdtemp(prefix="ai-arena-auto-profile-"))
    results = {"question": QUESTION, "selectors": selectors_map, "checks": [],
               "external_requests": [], "page_errors": [], "fixture_origin": origin}
    checks, external, page_errors = results["checks"], results["external_requests"], results["page_errors"]
    context = page = pw = None
    extension_info = None
    started = time.monotonic()

    def check(name, condition, detail=""):
        checks.append({"name": name, "ok": bool(condition), "detail": detail})
        log(f"  [{'PASS' if condition else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
        if not condition:
            raise AssertionError(f"{name}: {detail}" if detail else name)

    try:
        pw = sync_playwright().start()
        executable = chromium()
        load_dir, extension_info = prepare_extension(EXT, args.headed or args.interactive_permission)
        results["extension"] = extension_info
        log(f"AI Arena automation acceptance\n  extension: {load_dir}\n  source:    {EXT}\n"
            f"  fixture:   {origin}\n  output:    {out}")
        if extension_info["mode"] == "headless-test-copy":
            log("  manifest:  TEST COPY ONLY — optional_host_permissions -> host_permissions: "
                + ", ".join(extension_info["moved_optional_to_host_permissions"]))
        else:
            log("  manifest:  original — optional loopback permission requires a real dialog grant")
        context = pw.chromium.launch_persistent_context(
            user_data_dir=str(profile), headless=not args.headed,
            executable_path=str(executable) if executable else None,
            args=[f"--disable-extensions-except={load_dir}", f"--load-extension={load_dir}", "--no-first-run",
                  "--no-default-browser-check", "--disable-background-networking", "--disable-component-update",
                  "--disable-sync", "--no-proxy-server"])
        context.set_default_timeout(15000)

        def guard(route):
            url = route.request.url
            if url.startswith(("http://", "https://")) and urlsplit(url).hostname not in LOOPBACK:
                external.append(url)
                route.abort()
            else:
                route.continue_()

        context.route("**/*", guard)

        def watch(target):
            target.on("pageerror", lambda error: page_errors.append(f"{target.url}: {error}"))

        context.on("page", watch)
        try:
            worker = context.wait_for_event("serviceworker", timeout=15000)
        except PWTimeout:
            worker = context.service_workers[0] if context.service_workers else None
        if worker is None:
            raise AssertionError("extension service worker did not start")
        extension_id = worker.url.split("/")[2]
        page = context.new_page()
        page.goto(f"chrome-extension://{extension_id}/workspace.html")
        if not wait_until(
            page,
            lambda: page.evaluate(
                "() => !!(globalThis.chrome && chrome.runtime && chrome.runtime.id)"
            ),
            timeout=15000,
        ):
            raise AssertionError("workspace page never exposed chrome.runtime")
        permission_info = grant_loopback(page, extension_info["mode"])
        results["permission"] = permission_info
        check("loopback host access is really granted for both seats",
              bool(permission_info.get("granted")), json.dumps(permission_info, ensure_ascii=False))
        if extension_info["mode"] == "headless-test-copy":
            moved = extension_info["moved_optional_to_host_permissions"]
            check("test copy moved only localhost/127.0.0.1 optional host permissions",
                  bool(moved) and all(hostname_of(item) in LOOPBACK for item in moved),
                  f"moved={moved} remaining={extension_info['remaining_optional_host_permissions']}")
        page.screenshot(path=str(out / "00_configured.png"), full_page=True)

        for provider in PROVIDERS:
            seat = provider[-1].upper()
            ok(page, {"type": "automation.config", "provider": provider,
                      "config": {"url": f"{origin}/web-driver-fixture.html?seat={seat}",
                                 "selectors": selectors_map}})
        check("both automation.config calls accepted", True)

        session = ok(page, {"type": "create", "question": QUESTION, "providers": list(PROVIDERS)}).get("session") or {}
        session_id = session.get("id")
        check("session uses exactly local-a/local-b", session.get("providers") == list(PROVIDERS) and bool(session_id),
              f"id={session_id} providers={session.get('providers')}")
        check("initial stage is independent", session.get("stage") == "independent")
        started_reply = ok(page, {"type": "automation.start", "id": session_id})
        check("automation.start accepted", bool(started_reply.get("run")))

        observed, stages, run = {}, [], None
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            session = ok(page, {"type": "get", "id": session_id}).get("session") or {}
            run = (call(page, {"type": "automation.info"}).get("runs") or {}).get(session_id) or run
            if session.get("stage") not in stages:
                stages.append(session.get("stage"))
                log(f"  stage -> {session.get('stage')}")
            if run:
                if run.get("lastError"):
                    raise AssertionError(f"automation lastError: {run['lastError']}")
                for provider, seat in (run.get("seats") or {}).items():
                    status = str(seat.get("status") or "")
                    if seat.get("paused") or status in {"paused", "stale", "unconfigured", "error", "failed"}:
                        raise AssertionError(f"{provider} terminal seat {status}: {seat.get('detail', '')}")
            for seat, target in fixture_pages(context).items():
                observed[seat] = user_texts(target, selectors_map["user"])
            if session.get("stage") == "done":
                break
            time.sleep(0.4)
        else:
            raise AssertionError(f"not done within {args.timeout:.0f}s; stages={stages}")

        for seat, target in fixture_pages(context).items():
            observed[seat] = user_texts(target, selectors_map["user"])
            target.screenshot(path=str(out / f"01_seat_{seat}.png"), full_page=True)
            check(f"seat {seat} stayed on fixture origin", target.url.startswith(origin + "/web-driver-fixture.html"))
        page.screenshot(path=str(out / "02_final.png"), full_page=True)

        history, report = session.get("history") or [], session.get("report") or ""
        submissions = {seat: texts for seat, texts in observed.items()}
        total = sum(map(len, submissions.values()))
        results["submissions"] = submissions
        check("done with a non-empty report", session.get("stage") == "done" and bool(report.strip()))
        check("report names both seats", all(provider in report for provider in PROVIDERS))
        check("exactly seven unique submissions", total == EXPECTED and len(history) == EXPECTED,
              f"dom={total} history={len(history)} per_seat={ {k: len(v) for k, v in submissions.items()} }")
        check("no seat submitted the same prompt twice", all(len(v) == len(set(v)) for v in submissions.values()))
        check("both seats submitted", set(submissions) == {"A", "B"} and all(submissions.values()))

        proposals = [e for e in history if e.get("stage") == "proposal" and e.get("status") == "answered"]
        check("exactly one answered proposal", len(proposals) == 1)
        proposal_text = proposals[0].get("answer", "") if proposals else ""
        refs = re.findall(r"\[(S\d+)\]", proposal_text)
        known = {e.get("sourceId") for e in history if e.get("sourceId")} or set(re.findall(r"### \[(S\d+)\]", report))
        check("proposal cites at least one [S#]", bool(refs), f"refs={refs}")
        check("all proposal citations resolve", bool(refs) and set(refs) <= known, f"refs={refs} known={sorted(known)}")
        check("report is not a draft", "草稿" not in report and "缺少可核实" not in report)

        votes = {e.get("provider"): e for e in history if e.get("stage") == "vote"}
        check("both seats explicitly voted", set(votes) == set(PROVIDERS) and all(
            e.get("status") == "answered" and e.get("stance") in STANCES for e in votes.values()),
            "stances=" + json.dumps({k: v.get("stance") for k, v in votes.items()}, ensure_ascii=False))
        check("votes target one candidate version", len({e.get("version") for e in votes.values()}) == 1,
              f"versions={[e.get('version') for e in votes.values()]}")
        check("report reflects unanimous agreement", "全体一致" in report and all(
            e.get("stance") == "agree" for e in votes.values()))
        check("seven dispatch records all answered", bool(run) and len(run.get("dispatch") or {}) == EXPECTED
              and all(i.get("phase") == "answered" for i in (run.get("dispatch") or {}).values()),
              f"dispatch={len((run or {}).get('dispatch') or {})}")
        bad_pages = [p.url for p in context.pages if p.url.startswith(("http://", "https://"))
                     and urlsplit(p.url).hostname not in LOOPBACK]
        check("no external request or navigation", not external and not bad_pages,
              f"requests={external[:3]} pages={bad_pages[:3]}")
        check("no page JavaScript errors", not page_errors, "; ".join(page_errors[:3]))
        check("production manifest is byte-identical to the pre-run file",
              hashlib.sha256((EXT / "manifest.json").read_bytes()).hexdigest()
              == extension_info["production_manifest_sha256"],
              "extension/manifest.json untouched")

        (out / "report.md").write_text(report, encoding="utf-8")
        results.update({"ok": True, "session_id": session_id, "stages": stages, "history": history, "run": run,
                        "elapsed_seconds": round(time.monotonic() - started, 2)})
        log(f"  PASS in {results['elapsed_seconds']}s")
    except Exception as error:  # noqa: BLE001 - acceptance reports every failure
        results.update({"ok": False, "error": f"{type(error).__name__}: {error}",
                        "traceback": traceback.format_exc(), "elapsed_seconds": round(time.monotonic() - started, 2)})
        log(f"  FAIL: {error}")
        if context is not None:
            try:
                if page is not None:
                    page.screenshot(path=str(out / "99_failure.png"), full_page=True)
                for seat, target in fixture_pages(context).items():
                    target.screenshot(path=str(out / f"99_failure_seat_{seat}.png"), full_page=True)
            except Exception:
                pass
    finally:
        try:
            if context is not None:
                context.close()
        except Exception:
            pass
        try:
            if pw is not None:
                pw.stop()
        except Exception:
            pass
        if extension_info and extension_info.get("mode") == "headless-test-copy":
            shutil.rmtree(Path(extension_info["loaded_path"]).parent, ignore_errors=True)
        try:
            source_digest = hashlib.sha256((EXT / "manifest.json").read_bytes()).hexdigest()
            results["production_manifest_unchanged"] = bool(
                extension_info and source_digest == extension_info.get("production_manifest_sha256")
            )
        except Exception:
            results["production_manifest_unchanged"] = False
        log(f"  production manifest unchanged: {results['production_manifest_unchanged']}")
        server.shutdown()
        server.server_close()
        (out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
        if not args.keep_profile:
            shutil.rmtree(profile, ignore_errors=True)
    return 0 if results.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
