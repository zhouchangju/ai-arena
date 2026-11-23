"""Reproduce prior Arena prompts and a handwritten edit in the native WKWebViews."""
import argparse
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from fixtures import PROVIDERS, markup
from qa_app import stage_qa_app


OLD = {
    "chatgpt": "【原始问题】\n上一场的独立作答 🚲\n\n请给出判断。",
    "gemini": "【原始问题】\n上一场还没点发送的提示。",
    "deepseek": "【原始问题】\n上一场的其他席位提示。",
}
HUMAN = OLD["deepseek"] + "\n我自己补了一句，稍后发送。"
DRAFTS = {
    **OLD,
    "chatgpt": OLD["chatgpt"].replace("\n", "\u00a0").replace("🚲", "\u200b🚲"),
    "deepseek": HUMAN,
}


def seed_history(directory):
    session_id = "arena-draft-fixture"
    intents = []
    for provider, prompt in OLD.items():
        delivered = provider != "gemini"
        intents.append({
            "taskId": f"{session_id}:r1:independent:{provider}",
            "stage": "independent", "round": 1, "prompt": prompt,
            "phase": "submitted" if delivered else "prepared",
            "preparedAt": 1, "submittedAt": 2 if delivered else None,
            **({} if delivered else {"composerFilled": True}),
        })
    # A long previous discussion must not crowd out its first prompt.
    for round_number in range(1, 4):
        for stage in ("critique", "proposal", "vote"):
            intents.append({
                "taskId": f"{session_id}:r{round_number}:{stage}:chatgpt",
                "stage": stage, "round": round_number, "phase": "submitted",
                "prompt": f"旧场后续提示 {round_number} {stage}",
                "preparedAt": round_number + 2, "submittedAt": round_number + 3,
            })
    (directory / f"{session_id}.json").write_text(json.dumps({
        "version": 1, "id": session_id, "question": "上一场",
        "createdAt": 1, "updatedAt": 10, "sessionJSON": '{"stage":"done"}',
        "intents": intents, "manualProviders": [], "pageURLs": {},
    }))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    result = out / "result.json"
    if result.exists():
        raise FileExistsError(result)
    events = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            seat = urlparse(self.path).path.strip("/")
            if seat not in PROVIDERS:
                self.send_error(404)
                return
            page = markup(PROVIDERS.index(seat)).decode().replace(
                "window.turns=[];",
                f'''window.turns=[];
const text=()=>editor.tagName==='TEXTAREA'?editor.value:editor.innerText;
const observe=(key,value)=>fetch('/observed',{{method:'POST',
  body:JSON.stringify({{seat:{json.dumps(seat)},[key]:value}})}});
if(editor.tagName==='TEXTAREA')editor.value={json.dumps(DRAFTS[seat])};
else editor.innerText={json.dumps(DRAFTS[seat])};
send.addEventListener('click',()=>observe('click',text()));
setTimeout(()=>observe('draft',text()),3000);''',
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(page.encode())

        def do_POST(self):
            if self.path != "/observed":
                self.send_error(404)
                return
            events.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with stage_qa_app(args.app, out / "qa-app") as qa, tempfile.TemporaryDirectory() as data:
            seed_history(Path(data))
            with (out / "app.log").open("w") as log:
                proc = subprocess.run(
                    [qa.executable, "--smoke-test", "--smoke-prepare-recovery"],
                    env={**os.environ, "ARENA_FIXTURE_BASE": f"http://127.0.0.1:{server.server_port}",
                         "ARENA_DATA_DIR": data, "ARENA_SMOKE_RESULT": str(result),
                         "ARENA_SMOKE_TIMEOUT": "30"},
                    stdout=log, stderr=log, timeout=50,
                )
    finally:
        server.shutdown()
        server.server_close()
        (out / "original-pages.json").write_text(json.dumps(events, ensure_ascii=False, indent=2))

    session = json.loads(result.read_text())
    assert proc.returncode == 0, session.get("seatStates")
    assert session["pendingProvider"] == "deepseek", session["seatStates"]
    state = session["seatStates"]["deepseek"]
    assert state["kind"] == "needsAction" and "未发送草稿" in state["detail"], state
    for task in session["session"]["tasks"]:
        seat = task["provider"]
        clicks = [row["click"] for row in events if row["seat"] == seat and "click" in row]
        if seat == "deepseek":
            assert not clicks, clicks
            snapshots = [row["draft"] for row in events if row["seat"] == seat and "draft" in row]
            assert snapshots and all(text == HUMAN for text in snapshots), snapshots
        else:
            assert task["status"] == "answered", task
            assert clicks == [task["prompt"]], (seat, clicks)
    print("PASS: WKWebView replaced both confirmed and pre-click Arena drafts once; handwritten edit preserved with zero clicks")


if __name__ == "__main__":
    main()
