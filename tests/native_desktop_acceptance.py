"""Run the built macOS app against three local, streaming provider pages."""
import argparse
import base64
import json
import os
import subprocess
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from public_automation_acceptance import PROVIDERS, markup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--takeover", action="store_true")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    events = []
    cookie = "arena_native_" + uuid.uuid4().hex + "=1"
    restoring = threading.Event()
    restored_sites = set()
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            seat = urlparse(self.path).path.strip("/")
            if seat.startswith("pixel/") and seat[6:] in PROVIDERS:
                if restoring.is_set() and cookie in self.headers.get("Cookie", ""):
                    with lock:
                        restored_sites.add(seat[6:])
                png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jG2kAAAAASUVORK5CYII=")
                self.send_response(200)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Type", "image/png")
                self.end_headers()
                self.wfile.write(png)
                return
            if seat not in PROVIDERS:
                self.send_error(404)
                return
            page = markup(PROVIDERS.index(seat)).decode()
            page = page.replace("row.text+=tail;", "if(stage==='vote')row.text+=' 上轮示例：立场：反对。';row.text+=tail;")
            # Observe the messages that actually reached this provider surface.
            page = page.replace(
                "window.turns.push(row);",
                "window.turns.push(row);"
                "fetch('/observed',{method:'POST',body:JSON.stringify({site:location.pathname.slice(1),prompt})});",
            )
            page = page.replace(
                "answer.textContent=row.text;",
                "answer.textContent=row.text;"
                "if(row.complete)fetch('/observed',{method:'POST',body:JSON.stringify({site:location.pathname.slice(1),answer:row.text})});",
            )
            content = (page + f'<img src="/pixel/{seat}" alt="夹具图片">').encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            if not restoring.is_set():
                self.send_header("Set-Cookie", f"{cookie}; Max-Age=180; Path=/; SameSite=Lax")
            self.end_headers()
            self.wfile.write(content)

        def do_POST(self):
            if self.path != "/observed":
                self.send_error(404)
                return
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with lock:
                events.append(data)
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    result = out / "result.json"
    if result.exists():
        raise FileExistsError(f"Choose a fresh evidence directory: {out}")
    try:
        with tempfile.TemporaryDirectory() as data_dir:
            env = {
                **os.environ,
                "ARENA_FIXTURE_BASE": f"http://127.0.0.1:{server.server_port}",
                "ARENA_DATA_DIR": data_dir,
                "ARENA_SMOKE_RESULT": str(result),
            }
            executable = args.app / "Contents/MacOS/AIArena"
            with (out / "app.log").open("w") as log:
                flags = ["--smoke-test"] + (["--smoke-takeover"] if args.takeover else [])
                proc = subprocess.Popen([executable, *flags], env=env, stdout=log, stderr=log)
                try:
                    proc.wait(timeout=150)
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                        proc.wait(timeout=10)
                if proc.returncode != 0:
                    raise RuntimeError(f"App exited {proc.returncode}; see {out / 'app.log'}")
                restoring.set()
                restored = out / "restored.json"
                subprocess.run(
                    [executable, "--smoke-test", "--smoke-restore"],
                    env={**env, "ARENA_SMOKE_RESULT": str(restored)},
                    stdout=log, stderr=log, timeout=65, check=True,
                )
                assert json.loads(restored.read_text()) == json.loads(result.read_text())
                assert restored_sites == set(PROVIDERS), restored_sites
    finally:
        server.shutdown()
        server.server_close()
        (out / "original-pages.json").write_text(json.dumps(events, ensure_ascii=False, indent=2))
    raw = json.loads(result.read_text())
    session = raw.get("session", raw)
    history = session.get("history", [])
    assert session.get("stage") == "done", raw
    assert len(history) == 10 and all(x["status"] == "answered" for x in history)
    assert len(events) == (18 if args.takeover else 20), len(events)
    for site in PROVIDERS:
        saved = [x for x in history if x["provider"] == site]
        if args.takeover and site == "deepseek":
            assert saved[0]["answer"] == "夹具人工接管原文"
            saved = saved[1:]
        prompts = [e["prompt"] for e in events if e["site"] == site and "prompt" in e]
        answers = [e["answer"] for e in events if e["site"] == site and "answer" in e]
        assert [" ".join(p.split()) for p in prompts] == [" ".join(x["prompt"].split()) for x in saved], site
        assert answers == [x["answer"] for x in saved], site
    assert all(x["stance"] == "agree" for x in history if x["stage"] == "vote")
    assert len({x["proposalDigest"] for x in history if x["stage"] == "vote"}) == 1
    assert session["report"] in (out / "export.md").read_text()
    assert all(row["prompt"] in (out / "export.md").read_text() for row in history)
    print(f"PASS: 3 provider views; {len(events)//2} exactly matched automatic sends and replies; same-version votes, restore, session cookie and Markdown; takeover={args.takeover}")


if __name__ == "__main__":
    main()
