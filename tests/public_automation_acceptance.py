"""Three-seat browser regression for G1/G2/G3/G4 and R02/R06.

A disposable MV3 copy points the three provider entries at separate HTTPS
fixtures on loopback and pre-grants that host. The product implementation,
site selectors and UI run unchanged. This does not exercise native Chrome
permission prompts or the real sites' current DOM and accounts.

The Gemini fixture only exposes the finished-action control
(`model-response gem-icon-button[data-test-id="regenerate-button"]`) when its
stream ends, because that seat requires it: a stop control that disappeared
plus stable text is not completion evidence there (a real run once saved only
the 9-character heading). ChatGPT and DeepSeek keep the stop-observed rule.
"""

import argparse
import functools
import json
import re
import shutil
import ssl
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

from browser_acceptance import find_chromium_executable

ROOT = Path(__file__).resolve().parents[1]

PROVIDERS = ("chatgpt", "gemini", "deepseek")
ENTRIES = (
    "https://chatgpt.com/",
    "https://gemini.google.com/app",
    "https://chat.deepseek.com/",
)
TEMPLATE = r"""<!doctype html><meta charset=utf-8>
<style>textarea,[contenteditable]{display:block;width:700px;min-height:30px}pre,article{display:block;min-height:18px;white-space:pre-wrap}</style>
<main id="log"></main>
CONTENT
<script>
const editor=document.querySelector('#editor');
const send=document.querySelector('#send');
const log=document.querySelector('#log');
const doneMarkup=DONE_MARKUP;
window.turns=[];
const put=(container, html)=>{container.insertAdjacentHTML('beforeend',html);return container.lastElementChild};
send.addEventListener('click',()=>{
 const prompt=editor.tagName==='TEXTAREA'?editor.value:editor.innerText;
 if(!prompt.trim())return;
 editor.value='';editor.replaceChildren();
 const user=put(log,USER);user.textContent=prompt;
 const article=put(log,ANSWER);
 const answer=article.matches(ANSWER_BODY)?article:article.querySelector(ANSWER_BODY);
 const stop=put(document.body,'<button aria-label="Stop generating">Stop</button>');
 const row={prompt,text:'',complete:false};window.turns.push(row);
 const seq=window.turns.length;
 const stage=prompt.includes('STANCE:')?'vote':(prompt.includes('起草候选')?'proposal':'answer');
 const tail=stage==='vote'?'\nSTANCE: agree':(stage==='proposal'?'\n建议先验证检索。[S1]':'\n测试结论。');
 const delay=seq===1&&PROVIDER==='deepseek'&&prompt.includes('隔离接管')?5200:(seq===1?DELAY:650);
 for(let i=1;i<=4;i++)setTimeout(()=>{
   row.text+=(i===1?'':' ')+PROVIDER+' '+seq+' 第'+i+'段的网页原文。';
   if(i===4){row.text+=tail;row.complete=true;stop.remove();if(doneMarkup)article.insertAdjacentHTML('beforeend',doneMarkup)}
   answer.textContent=row.text;
 },delay*i);
});
</script>"""

HTML = (
    (
        '<div id="editor" class="ProseMirror" role="textbox" contenteditable="true"></div><button id="send" data-testid="send-button">发送</button>',
        '<article data-content-search-unit-key="turn:user"></article>',
        "<article><pre data-response-body></pre></article>",
        "[data-response-body]",
        "",
    ),
    (
        '<rich-textarea><div id="editor" class="ql-editor" contenteditable="true"></div></rich-textarea><button id="send" aria-label="Send message">发送</button>',
        '<user-query style="display:block;white-space:pre-wrap"></user-query>',
        '<model-response><message-content style="display:block;white-space:pre-wrap"></message-content></model-response>',
        "message-content",
        # Same structure as the real finished toolbar: a visible native action
        # inside this round's model-response. Gemini only reports completion
        # through it (options.requireDoneMarker); the stop control alone is not
        # enough. Added at the end of the stream, never before.
        '<gem-icon-button data-test-id="regenerate-button" aria-label="重新生成" style="display:inline-block;padding:2px 8px">重新生成</gem-icon-button>',
    ),
    (
        '<textarea id="editor" name="search"></textarea><button id="send" aria-label="发送">发送</button>',
        '<div class="ds-message" style="white-space:pre-wrap"></div>',
        '<div class="ds-message"><pre class="ds-assistant-message-main-content"></pre></div>',
        ".ds-assistant-message-main-content",
        "",
    ),
)


def markup(index):
    content, user, answer, body, done = HTML[index]
    return functools.reduce(
        lambda value, pair: value.replace(*pair),
        [
            ("CONTENT", content),
            ("ANSWER_BODY", json.dumps(body)),
            ("USER", json.dumps(user)),
            ("ANSWER", json.dumps(answer)),
            ("DONE_MARKUP", json.dumps(done)),
            ("DELAY", str((650, 1600, 2700)[index])),
            ("PROVIDER", json.dumps(PROVIDERS[index])),
        ],
        TEMPLATE,
    ).encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(self.server.payload)

    def log_message(self, *_):
        pass


def call(page, payload):
    result = page.evaluate("(payload) => chrome.runtime.sendMessage(payload)", payload)
    if not result or not result.get("ok"):
        raise AssertionError(result)
    return result


def wait(page, fn, seconds=15):
    import time

    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        page.wait_for_timeout(180)
    raise AssertionError("timed out")


def start_discussion(page, question):
    page.locator("#question-input").fill(question)
    for provider in PROVIDERS:
        option = page.locator(f'button[data-provider-id="{provider}"]')
        if option.get_attribute("aria-pressed") != "true":
            option.click()
    page.get_by_role("button", name="开始讨论", exact=True).click()
    wait(page, lambda: "#s=" in page.url)
    return page.url.split("#s=")[-1]


def verify_takeover(page, ctx, origins, out):
    page.locator("#new-session").click()
    sid = start_discussion(page, "隔离接管验收，如何小规模验证采集需求？")
    card = page.locator('article.seat-card[data-provider="deepseek"]')

    def session():
        return call(page, {"type": "get", "id": sid})["session"]

    def save_diagnostics():
        (out / "takeover-pending.json").write_text(
            json.dumps(
                {
                    "session": session(),
                    "run": call(page, {"type": "automation.info"})["runs"].get(sid),
                    "tabs": [tab.url for tab in ctx.pages],
                },
                ensure_ascii=False,
                indent=2,
            )
        )

    try:
        card.locator(".seat-auto-preview:not([hidden])").wait_for(timeout=23000)
        card.get_by_role("button", name="手动接管", exact=True).click()
        editor = card.locator("textarea.answer-input")
        editor.wait_for()
    except Exception:
        save_diagnostics()
        raise

    def other_seats_finished():
        state = session()
        tasks = [task for task in state["tasks"] if task["provider"] != "deepseek"]
        return (
            state
            if len(tasks) == 2 and all(task["status"] == "answered" for task in tasks)
            else None
        )

    try:
        stalled = wait(page, other_seats_finished, seconds=25)
    except AssertionError:
        save_diagnostics()
        raise
    pending = next(task for task in stalled["tasks"] if task["provider"] == "deepseek")
    assert pending["status"] == "pending" and not pending.get("answer")
    source = next(tab for tab in ctx.pages if tab.url.startswith(origins[2] + "/"))
    original = wait(
        page,
        lambda: source.evaluate(
            "() => turns.length === 1 && turns[0].complete && turns[0].text"
        ),
        seconds=25,
    )
    page.screenshot(path=str(out / "takeover.png"), full_page=True)
    editor.fill(original)
    card.get_by_role("button", name="提交回答", exact=True).click()
    wait(page, lambda: session()["stage"] == "critique")
    saved = next(
        entry for entry in session()["history"] if entry["id"] == pending["id"]
    )
    assert saved["answer"] == original
    assert source.evaluate("turns.length") == 1
    run = call(page, {"type": "automation.info"})["runs"][sid]
    assert run["seats"]["deepseek"]["takenOver"] is True


def main(out):
    out.mkdir(exist_ok=True, parents=True)
    with tempfile.TemporaryDirectory() as dirname:
        root = Path(dirname)
        key, cert = root / "key", root / "cert"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(key),
                "-out",
                str(cert),
                "-days",
                "1",
                "-subj",
                "/CN=127.0.0.1",
            ],
            check=True,
            capture_output=True,
        )
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        servers = []
        for index in range(3):
            srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            srv.payload = markup(index)
            srv.socket = tls.wrap_socket(srv.socket, server_side=True)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            servers.append(srv)
        ext = root / "extension"
        shutil.copytree(ROOT / "extension", ext)
        registry = ext / "providers.js"
        text = registry.read_text()
        origins = [f"https://127.0.0.1:{server.server_port}" for server in servers]
        for url, origin in zip(ENTRIES, origins):
            text = text.replace(url, origin + "/")
        registry.write_text(text)
        path = ext / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["host_permissions"] = ["https://127.0.0.1/*"]
        path.write_text(json.dumps(manifest))
        try:
            with sync_playwright() as p:
                ctx = p.chromium.launch_persistent_context(
                    str(root / "profile"),
                    headless=True,
                    executable_path=str(find_chromium_executable()),
                    args=[
                        f"--disable-extensions-except={ext}",
                        f"--load-extension={ext}",
                        "--ignore-certificate-errors",
                        "--no-proxy-server",
                        "--disable-quic",
                        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
                        "--disable-background-networking",
                    ],
                )
                worker = (
                    ctx.service_workers[0]
                    if ctx.service_workers
                    else ctx.wait_for_event("serviceworker", timeout=15000)
                )
                page = ctx.new_page()
                page.goto(worker.url.rsplit("/", 1)[0] + "/workspace.html")
                sid = start_discussion(
                    page, "隔离三席验收，应该优先验证哪个笔记工具问题？"
                )

                def runtime():
                    return call(page, {"type": "get", "id": sid})["session"]

                previews = {provider: set() for provider in PROVIDERS}
                saw_mixed = False

                def observe():
                    nonlocal saw_mixed
                    session = runtime()
                    cards = page.evaluate(
                        """() => Object.fromEntries(Array.from(document.querySelectorAll('.seat-card')).map(card=>[
                        card.dataset.provider, {preview:card.querySelector('.seat-auto-preview:not([hidden])')?.textContent || '',
                        saved:card.classList.contains('is-answered')}
                    ]))"""
                    )
                    for provider, card in cards.items():
                        if card["preview"]:
                            previews[provider].add(card["preview"])
                    if (
                        session["stage"] == "independent"
                        and cards.get("chatgpt", {}).get("saved")
                        and cards.get("deepseek", {}).get("preview")
                    ):
                        if not saw_mixed:
                            page.screenshot(
                                path=str(out / "uneven-streams.png"), full_page=True
                            )
                        saw_mixed = True
                    return session if session["stage"] == "done" else None

                try:
                    result = wait(page, observe, 58)
                except AssertionError:
                    (out / "pending.json").write_text(
                        json.dumps(
                            {
                                "session": runtime(),
                                "run": call(page, {"type": "automation.info"})["runs"][
                                    sid
                                ],
                                "tabs": [v.url for v in ctx.pages],
                            },
                            ensure_ascii=False,
                            indent=2,
                        )
                    )
                    raise
                articles = {
                    PROVIDERS[i]: next(
                        v for v in ctx.pages if v.url.startswith(origin + "/")
                    ).evaluate("window.turns")
                    for i, origin in enumerate(origins)
                }
                history = result["history"]
                assert sum(map(len, articles.values())) == len(history) == 10, (
                    articles,
                    history,
                )
                for provider, turns in articles.items():
                    saved = [
                        entry for entry in history if entry["provider"] == provider
                    ]
                    assert len(turns) == len(saved)
                    for turn, entry in zip(turns, saved):
                        assert (
                            re.sub(r"\s+", " ", turn["prompt"]).strip()
                            == re.sub(r"\s+", " ", entry["prompt"]).strip()
                        )
                        assert turn["text"] == entry["answer"], (turn, entry)
                assert all(
                    len(previews[p]) >= 2 for p in ("gemini", "deepseek")
                ), previews
                assert saw_mixed, previews
                try:
                    page.locator("#report-title").wait_for(timeout=8000)
                except Exception:
                    (out / "workbench-at-done.txt").write_text(
                        page.locator("body").inner_text()
                    )
                    raise
                page.screenshot(path=str(out / "done.png"), full_page=True)
                for tab in ctx.pages:
                    if any(tab.url.startswith(origin + "/") for origin in origins):
                        tab.close()
                verify_takeover(page, ctx, origins, out)
                (out / "result.json").write_text(
                    json.dumps(
                        {
                            "total": len(history),
                            "saw_mixed": saw_mixed,
                            "previews": {k: len(v) for k, v in previews.items()},
                            "stopReason": result["stopReason"],
                            "single_seat_takeover": True,
                        },
                        ensure_ascii=False,
                        indent=2,
                    )
                )
                print((out / "result.json").read_text(), flush=True)
                ctx.close()
        finally:
            for srv in servers:
                srv.shutdown()
                srv.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    main(parser.parse_args().out.resolve())
