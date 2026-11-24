"""Exercise attachment delivery through all three native WKWebViews using synthetic files."""
import argparse
import base64
import html
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import zlib

from fixtures import PROVIDERS, markup
from qa_app import stage_qa_app


TEXT = "原文标记：风铃-7481\n数量,2"


def sample_png(rgb):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes([0, *rgb])))
        + chunk(b"IEND", b"")
    )


SAMPLES = {
    "01-红.png": sample_png((255, 0, 0)),
    "02-蓝.png": sample_png((0, 0, 255)),
    "03-说明.txt": TEXT.encode(),
}
EXPECTED_IMAGES = [
    {"name": name, "hash": hashlib.sha256(data).hexdigest()}
    for name, data in SAMPLES.items() if name.endswith(".png")
]


# Observe the File bytes supplied to the webpage, its upload previews and
# the actual sent user turn independently of what the workbench reports.
PAGE_JS = r"""
const mode=MODE, site=location.pathname.slice(1);
const files=document.querySelector('#files'), previews=document.querySelector('#previews');
const savedKey='attachment-turns:'+site;
log.innerHTML=localStorage.getItem(savedKey)||'';
const observe=(event,detail)=>fetch('/observed',{method:'POST',body:JSON.stringify({site,event,...detail})});
const addChip=(parent,name)=>{
 const chip=document.createElement('span');
 chip.setAttribute('data-arena-attachment','');
 chip.dataset.fileName=name;
 chip.setAttribute('aria-label',name);
 if(site==='chatgpt')chip.textContent=name;
 chip.style='display:inline-block;width:24px;height:24px';
 parent.append(chip);
};
const addFilePreview=(parent,file)=>{
 if(site!=='gemini'){addChip(parent,file.name);return;}
 const image=new Image(24,24);
 image.src=URL.createObjectURL(file);
 parent.append(image);
};
const getNames=parent=>Array.from(parent.querySelectorAll('[data-arena-attachment]'),node=>node.dataset.fileName);
const digest=async blob=>Array.from(
 new Uint8Array(await crypto.subtle.digest('SHA-256',await blob.arrayBuffer())),
 x=>x.toString(16).padStart(2,'0')).join('');
const describe=async file=>({name:file.name,hash:await digest(file)});

if(mode==='late-picker'){
 const alert=document.createElement('div');
 alert.setAttribute('role','alert');
 alert.style='display:block;width:30px;height:20px';
 previews.before(alert);
 files.remove();
 const start=performance.now();
 setTimeout(()=>{
   previews.before(files);
   observe('picker-mounted',{ms:performance.now()-start,notification:alert.textContent});
 },2200);
}
if(mode==='unknown'){
 addChip(previews,'我的私人草稿.png');
 const reportDraft=()=>observe('draft',{names:getNames(previews)});
 reportDraft();
 new MutationObserver(reportDraft).observe(previews,{childList:true,subtree:true,attributes:true});
}
let uploaded=[];
if(mode==='late-send'){
 send.hidden=true;
 editor.addEventListener('input',()=>{
   const text=editor.tagName==='TEXTAREA'?editor.value:editor.innerText;
   if(text.trim()&&uploaded.length)setTimeout(()=>{send.hidden=false},1150);
 });
}
files.addEventListener('change',()=>{
 uploaded=Array.from(files.files);
 previews.replaceChildren();
 const visible=mode==='partial'?uploaded.slice(0,1):uploaded.slice();
 if(mode==='swapped')visible.reverse();
 const render=()=>{for(const file of visible)addFilePreview(previews,file);};
 // The real Gemini preview can mount after the driver's bounded upload wait.
 // 31.5 s is just past the real 30 s submitTimeoutMs in this app's sites.json.
 if(mode==='late-preview')setTimeout(render,31500);else render();
 Promise.all(uploaded.map(describe)).then(items=>observe('upload',{items,names:getNames(previews)}));
});
const receive=(user,prompt)=>{
 const sent=uploaded.slice();
 const displayed=mode==='after-click'?sent.slice(0,1):sent;
 for(const file of displayed)addFilePreview(user,file);
 const names=getNames(user);
 const actualBlobs=Array.from(user.querySelectorAll('img'),async image=>
   digest(await (await fetch(image.src)).blob()));
 Promise.all([Promise.all(sent.map(describe)),Promise.all(actualBlobs)])
   .then(([items,blobHashes])=>observe('send',{prompt,items,names,blobHashes}));
 previews.replaceChildren();
 files.value='';
 uploaded=[];
 localStorage.setItem(savedKey,log.innerHTML);
};
"""


def make_page(seat, mode):
    page = markup(PROVIDERS.index(seat)).decode()
    page = page.replace(
        '<main id="log"></main>',
        '<main id="log"></main><section data-arena-composer>'
        '<input id="files" type="file" accept="image/*" multiple><div id="previews"></div>',
    ).replace("<script>", "</section><script>")
    page = page.replace("window.turns=[];", "window.turns=[];\n" + PAGE_JS.replace("MODE", json.dumps(mode)))
    page = page.replace("user.textContent=prompt;", "user.textContent=prompt;receive(user,prompt);")
    if mode == "withhold":
        # The first process can verify the user turn but cannot collect this
        # answer. Record the exact fixture response for an isolated read replay.
        page += "<style>model-response { display:none!important }</style>"
        page = page.replace("answer.textContent=row.text;", "answer.textContent=row.text;"
                            "if(row.complete)observe('held-answer',{text:row.text});")
    page = page.replace("answer.textContent=row.text;", "answer.textContent=row.text;"
                        "if(row.complete)localStorage.setItem(savedKey,log.innerHTML);")
    return page.encode()


def exercise(executable, directory, case):
    directory.mkdir()
    inputs = directory / "inputs"
    inputs.mkdir()
    for name, data in SAMPLES.items():
        (inputs / name).write_bytes(data)
    events = []
    modes = {
        "delivery": {"chatgpt": "late-picker", "deepseek": "late-send"},
        "late-preview": {"chatgpt": "late-picker", "gemini": "late-preview", "deepseek": "late-send"},
        "faults": {"chatgpt": "partial", "gemini": "unknown", "deepseek": "after-click"},
        "swapped": {"gemini": "swapped"},
        "resume": {"gemini": "withhold"},
    }[case]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            seat = urlsplit(self.path).path.strip("/")
            if seat not in PROVIDERS:
                self.send_error(404)
                return
            body = make_page(seat, modes.get(seat, "normal"))
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != "/observed":
                self.send_error(404)
                return
            events.append({**json.loads(self.rfile.read(int(self.headers["Content-Length"]))),
                           "at": time.monotonic()})
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def launch(label, flags=(), *, timeout=100, expected_exit=0):
        result = directory / (label + ".json")
        env = {
            **os.environ, "ARENA_FIXTURE_BASE": f"http://127.0.0.1:{server.server_port}",
            "ARENA_DATA_DIR": str(directory / "data"), "ARENA_SMOKE_RESULT": str(result),
            "ARENA_SMOKE_TIMEOUT": str(timeout),
        }
        if label == "start":
            env["ARENA_SMOKE_ATTACHMENT_DIR"] = str(inputs)
            if case == "delivery":
                env["ARENA_SMOKE_COMPOSER_CAPTURE"] = str(directory / "composer.png")
        with (directory / (label + ".log")).open("w") as log:
            proc = subprocess.run([executable, "--smoke-test", *flags], env=env,
                                  stdout=log, stderr=log, timeout=timeout + 40)
        payload = json.loads(result.read_text())
        assert proc.returncode == expected_exit, (proc.returncode, label, payload.get("seatStates"))
        return payload

    def sent_to(seat):
        return [event for event in events if event["site"] == seat and event["event"] == "send"]

    try:
        if case == "swapped":
            diagnostic = launch("start", ["--smoke-prepare-recovery"])
            assert diagnostic["reason"] == "recovery-armed" and diagnostic["pendingProvider"] == "gemini"
            tasks = {task["provider"]: task for task in diagnostic["session"]["tasks"]}
            assert tasks["gemini"]["status"] == "pending" and "attachmentReceipt" not in tasks["gemini"]
            uploads = [event for event in events if event["site"] == "gemini" and event["event"] == "upload"]
            assert len(uploads) == 1 and uploads[0]["items"] == EXPECTED_IMAGES, uploads
            assert not sent_to("gemini"), events
            for seat in ("chatgpt", "deepseek"):
                assert tasks[seat]["attachmentReceipt"] == "verified" and len(sent_to(seat)) == 1
        elif case == "faults":
            diagnostic = launch("start", timeout=35, expected_exit=1)
            assert all("attachmentReceipt" not in t for t in diagnostic["session"]["tasks"]), diagnostic
            assert diagnostic["reason"] == "timeout" and diagnostic["session"]["stage"] == "independent"
            assert all(t["status"] == "pending" for t in diagnostic["session"]["tasks"]), diagnostic
            assert all(s["kind"] == "needsAction" for s in diagnostic["seatStates"].values()), diagnostic["seatStates"]
            assert not sent_to("chatgpt") and not sent_to("gemini"), events
            partial = [e for e in events if e["site"] == "chatgpt" and e["event"] == "upload"]
            assert len(partial) == 1 and partial[0]["names"] == [EXPECTED_IMAGES[0]["name"]], partial
            drafts = [e for e in events if e["site"] == "gemini"]
            assert drafts and all(e["event"] == "draft" and e["names"] == ["我的私人草稿.png"] for e in drafts), drafts
            third = sent_to("deepseek")
            assert len(third) == 1 and third[0]["items"] == EXPECTED_IMAGES, third
            assert third[0]["names"] == [EXPECTED_IMAGES[0]["name"]], third
            saved_id = diagnostic["session"]["id"]
            saved = json.loads((directory / "data" / (saved_id + ".json")).read_text())
            third_intent = next(i for i in saved["intents"] if i["taskId"].endswith(":deepseek"))
            assert third_intent["phase"] in ("uncertain", "inflight"), third_intent
            before = [e for e in events if e["event"] in ("send", "upload")]
            restarted = launch("restart", ["--smoke-check-restart"])
            assert restarted["session"]["stage"] == "independent"
            assert before == [e for e in events if e["event"] in ("send", "upload")], events
            resumed = launch("continue", ["--smoke-check-restart", "--continue-saved-discussion", saved_id])
            assert resumed["didContinue"] and resumed["session"]["stage"] == "independent", resumed
            assert all(task["status"] == "pending" for task in resumed["session"]["tasks"])
            assert before == [e for e in events if e["event"] in ("send", "upload")], events
        else:
            if case == "resume":
                before = launch("start", timeout=22, expected_exit=1)
                pending = next(task for task in before["session"]["tasks"] if task["provider"] == "gemini")
                assert before["reason"] == "timeout" and pending["status"] == "pending", pending
                assert pending["attachmentReceipt"] == "verified", pending
                assert all(len(sent_to(seat)) == 1 for seat in PROVIDERS), events
                for source in inputs.iterdir():
                    source.unlink()
                session_id = before["session"]["id"]
                saved = json.loads((directory / "data" / (session_id + ".json")).read_text())
                intent = next(i for i in saved["intents"] if i["taskId"] == pending["id"])
                assert intent["phase"] == "submitted" and len(intent["imagePixelDigests"]) == 2
                restarted = launch("restart", ["--smoke-check-restart"])
                assert restarted["session"]["stage"] == "independent"
                assert all(len(sent_to(seat)) == 1 for seat in PROVIDERS), events
                # Production binds rebuilt reads to a concrete HTTPS conversation.
                # Keep that restriction: test recovery against a locally simulated
                # response for that URL using this process's persisted evidence.
                held = [e["text"] for e in events if e["event"] == "held-answer" and e["site"] == "gemini"]
                assert len(held) == 1 and held[0], held
                check_bound_read(executable, directory, pending, intent, held[0])
                return
            else:
                session = launch("start")
            assert session["stage"] == "done", session
            assert [item["name"] for item in session["attachments"]] == list(SAMPLES)
            assert len(session["history"]) == 10
            for seat in PROVIDERS:
                saved = [row for row in session["history"] if row["provider"] == seat]
                delivered = sent_to(seat)
                assert len(delivered) == len(saved), (seat, delivered)
                assert all(" ".join(row["prompt"].split()) == " ".join(event["prompt"].split())
                           for row, event in zip(saved, delivered)), seat
                assert saved[0]["attachmentReceipt"] == "verified", saved[0]
                assert saved[0]["attachmentIDs"] == [item["id"] for item in session["attachments"]]
                if seat == "chatgpt":
                    own = [event for event in events if event["site"] == seat]
                    upload_index = next(index for index, event in enumerate(own) if event["event"] == "upload")
                    assert any(event["event"] == "picker-mounted" and event["ms"] >= 2000
                               and not event["notification"] for event in own[:upload_index]), own
                    assert sum(event["event"] == "upload" for event in own) == 1, own
                first, *later = delivered
                assert first["items"] == EXPECTED_IMAGES, first
                if seat == "gemini":
                    assert first["names"] == [], first
                    assert first["blobHashes"] == [image["hash"] for image in EXPECTED_IMAGES], first
                else:
                    assert first["names"] == [image["name"] for image in EXPECTED_IMAGES], first
                assert TEXT in first["prompt"] and all(row["status"] == "answered" for row in saved)
                assert all(not e["items"] and not e["names"] and not e["blobHashes"] for e in later), later
            if case == "late-preview":
                # The site mounted its previews after the driver's bounded upload
                # wait. The native layer must re-check that same upload once and
                # then send once: one upload, one send, at least 30 s after it.
                uploads = [event for event in events
                           if event["site"] == "gemini" and event["event"] == "upload"]
                assert len(uploads) == 1 and uploads[0]["items"] == EXPECTED_IMAGES, uploads
                first_send = sent_to("gemini")[0]
                assert first_send["at"] - uploads[0]["at"] >= 30, (uploads[0], first_send)
                saved = json.loads((directory / "data" / (session["id"] + ".json")).read_text())
                intent = next(i for i in saved["intents"]
                              if i["taskId"].endswith(":independent:gemini"))
                assert intent["imagePreparationStarted"] is True, intent
                assert intent["phase"] == "submitted", intent
                assert len(intent["imagePixelDigests"]) == 2, intent
            # Reopen after removing the original Finder items. Saved evidence and
            # export must remain usable; restoration cannot post another turn.
            for source in inputs.iterdir():
                source.unlink()
            assert launch("restore", ["--smoke-restore"]) == session
            assert sum(len(sent_to(seat)) for seat in PROVIDERS) == 10
            report = (directory / "export.md").read_text()
            assert all(name in report for name in SAMPLES), report
    finally:
        server.shutdown()
        server.server_close()
        (directory / "original-pages.json").write_text(json.dumps(events, ensure_ascii=False, indent=2))


def check_bound_read(executable, directory, task, intent, answer):
    root = Path(__file__).resolve().parents[1]
    resources = Path(executable).parent.parent / "Resources"
    config = json.loads((resources / "sites.json").read_text())["gemini"]
    address = "https://gemini.google.com/app/abc123def456"
    message = {"type": "arena.web.read", "taskId": task["id"], "verifiedReadPrompt": task["prompt"],
               "imageNames": [image["name"] for image in EXPECTED_IMAGES], "imagePixels": intent["imagePixelDigests"],
               "selectors": config["selectors"], "options": config["options"],
               "scope": {"origin": config["origin"], "homeHref": config["url"], "href": address, "allowNavigation": True}}
    request = directory / "bound-message.json"
    request.write_text(json.dumps(message, ensure_ascii=False))
    driver = resources / "web-driver.js"
    binary = directory / "bound-read"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", root / "tests/attachment_read_recovery.swift",
                    "-o", binary], check=True)
    for swapped in (False, True):
        images = list(SAMPLES.values())[:2]
        if swapped:
            images.reverse()
        tags = "".join('<img width="24" height="24" src="data:image/png;base64,'
                       + base64.b64encode(data).decode() + '">' for data in images)
        page = directory / ("swapped.html" if swapped else "restored.html")
        page.write_text(
            '<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" '
            """content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">"""
            '<style>user-query,model-response,message-content,gem-icon-button{display:block;white-space:pre-wrap}</style>'
            '<user-query>' + html.escape(task["prompt"]) + tags + '</user-query>'
            '<model-response><message-content>' + html.escape(answer) + '</message-content>'
            '<gem-icon-button data-test-id="regenerate-button">重新生成</gem-icon-button></model-response>'
            '<script>document.onclick=()=>window.fixtureClicks=(window.fixtureClicks||0)+1</script>'
        )
        raw = subprocess.check_output([binary, driver, page, request], text=True, timeout=25)
        observed = json.loads(raw)
        assert observed["clicks"] == 0, observed
        result = observed["result"]
        if swapped:
            assert result.get("error") == "attachment-receipt-mismatch", result
        else:
            assert result["status"] == "done" and result["text"] == answer, result
            assert result["detail"]["verifiedImageNames"] == message["imageNames"], result
        page.with_suffix(".json").write_text(raw)


def check_pasteboard(out):
    directory = out / "pasteboard"
    directory.mkdir()
    for name, data in SAMPLES.items():
        (directory / name).write_bytes(data)
    (directory / "unsupported.pdf").write_bytes(b"%PDF-1.4")
    root = Path(__file__).resolve().parents[1]
    binary = directory / "attachment-pasteboard-check"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        root / "desktop/ArenaEngine.swift", root / "desktop/ArenaEvaluation.swift",
        root / "desktop/ArenaAttachmentComposer.swift",
        root / "tests/attachment_pasteboard.swift", "-o", binary,
    ], check=True)
    subprocess.run([binary, directory], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--case", choices=("all", "pasteboard", "delivery", "late-preview", "faults",
                                           "swapped", "resume"), default="all")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.case in ("all", "pasteboard"):
        check_pasteboard(out)
    if args.case == "pasteboard":
        return
    with stage_qa_app(args.app, out / "qa-app") as qa:
        for case in (("delivery", "late-preview", "faults", "swapped", "resume")
                     if args.case == "all" else (args.case,)):
            exercise(qa.executable, out / case, case)
            print("PASS: WKWebView attachment " + case, flush=True)


if __name__ == "__main__":
    main()
