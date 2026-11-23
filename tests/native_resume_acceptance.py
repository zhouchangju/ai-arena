"""Isolated explicit-continuation check for the native macOS workbench.

Scenario:

1. A first process starts a three-seat discussion against loopback fixtures.
   Two seats finish their first independent answer. The third seat's send
   button is intentionally disabled, so its submit stays pre-click and its
   persisted delivery intent is `.prepared`.
2. That process exits. The test verifies the saved session has two answers and
   one prepared intent, then enables the third seat's send button.
3. A second process is launched with the exact saved session id:
   `--continue-saved-discussion <id> --smoke-continue-recovery`.
4. Only the missing first-round answer may be sent. The two seats that already
   answered must show zero additional first-round sends (same `submittedAt`,
   no prompt observed on their fixture pages). The discussion must then finish
   all normal rounds and produce a report that keeps a conditional vote.

Nothing here touches real sites or real user history: the pages are loopback
fixtures under a fresh ARENA_DATA_DIR.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from public_automation_acceptance import PROVIDERS, markup
from qa_app import stage_qa_app


def normalize(text):
    return " ".join(str(text).split())


def main():
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "result-1.json").exists():
        raise FileExistsError(f"Choose a fresh evidence directory: {out}")

    data_dir = tempfile.mkdtemp(prefix="arena-resume-data-", dir=out)
    phase = [1]
    events = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            seat = urlparse(self.path).path.strip("/")
            if seat not in PROVIDERS:
                self.send_error(404)
                return
            page = markup(PROVIDERS.index(seat)).decode()
            # Later proposal prompts contain earlier votes, whose text includes
            # "STANCE:". Check the drafting instruction first so v2/v3 keep a
            # real citation instead of being misread as votes.
            page = page.replace(
                "const stage=prompt.includes('STANCE:')?'vote':(prompt.includes('起草候选')?'proposal':'answer');",
                "const stage=prompt.includes('起草候选')?'proposal':(prompt.includes('STANCE:')?'vote':'answer');",
            )
            # Observe every prompt/answer that actually reached this surface.
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
            if seat == "deepseek" and phase[0] == 1:
                # Visible but disabled: the driver fills the composer, waits for
                # the send control, and reports a pre-click `send-pending`.
                page = page.replace(
                    '<button id="send" aria-label="发送">',
                    '<button id="send" aria-label="发送" disabled>',
                )
            if seat == "gemini":
                # Keep one conditional vote so the report must preserve a
                # disagreement instead of being normalised into unanimity.
                page = page.replace(
                    r"'\nSTANCE: agree'",
                    r"'\n条件：需要补一组小样本证据。\nSTANCE: conditional'",
                )
            content = page.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(content)

        def do_POST(self):
            if self.path != "/observed":
                self.send_error(404)
                return
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with lock:
                data["phase"] = phase[0]
                events.append(data)
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    qa = stage_qa_app(args.app, out / "qa-app")
    print(
        "QA launch: %s (%s, %s); source build left untouched"
        % (qa.app, qa.version, "ad hoc")
    )
    executable = qa.executable
    base_env = {
        **os.environ,
        "ARENA_FIXTURE_BASE": f"http://127.0.0.1:{server.server_port}",
        "ARENA_DATA_DIR": data_dir,
    }

    try:
        result_1 = out / "result-1.json"
        with (out / "app-1.log").open("w") as log:
            first = subprocess.run(
                [executable, "--smoke-test", "--smoke-prepare-recovery"],
                env={**base_env, "ARENA_SMOKE_RESULT": str(result_1)},
                stdout=log,
                stderr=log,
                timeout=150,
            )
        if first.returncode != 0:
            raise AssertionError(
                f"prepare process exited {first.returncode}; see {out / 'app-1.log'}"
            )

        armed = json.loads(result_1.read_text())
        assert armed["reason"] == "recovery-armed", armed
        assert armed["stage"] == "independent", armed
        session_id = armed["sessionID"]
        assert session_id, armed
        provider = armed["pendingProvider"]
        assert armed["pendingPhase"] == "prepared", armed
        assert "已填入" in armed["statuses"][provider], armed["statuses"]
        assert armed["seatStates"][provider]["kind"] == "sending", armed["seatStates"]

        session_1 = armed["session"]
        answers_1 = [task for task in session_1["tasks"] if task["status"] == "answered"]
        pending_1 = [task for task in session_1["tasks"] if task["status"] == "pending"]
        assert len(answers_1) == 2, session_1["tasks"]
        assert len(pending_1) == 1 and pending_1[0]["provider"] == provider, session_1
        answered_seats = {row["provider"] for row in answers_1}
        assert answered_seats == set(PROVIDERS) - {provider}, answered_seats

        session_file = Path(data_dir) / f"{session_id}.json"
        saved_1 = json.loads(session_file.read_text())
        intents_1 = {item["taskId"]: item for item in saved_1["intents"]}
        prepared_task = pending_1[0]["id"]
        assert intents_1[prepared_task]["phase"] == "prepared", intents_1[prepared_task]

        first_round = {row["provider"]: row for row in answers_1}
        assert set(first_round) == answered_seats, first_round
        sent_at = {
            provider_id: intents_1[first_round[provider_id]["id"]]["submittedAt"]
            for provider_id in answered_seats
        }

        # Let the last fixture POST arrive, then check the conservative restart.
        time.sleep(0.5)
        phase_1_events = [event for event in events if event["phase"] == 1]
        assert len(phase_1_events) == 4, phase_1_events
        assert {event["site"] for event in phase_1_events} == answered_seats
        for provider_id in answered_seats:
            own = [event for event in phase_1_events if event["site"] == provider_id]
            assert sum("prompt" in event for event in own) == 1, own
            assert sum("answer" in event for event in own) == 1, own

        def check_restart(extra, name):
            path = out / f"{name}.json"
            with (out / f"{name}.log").open("w") as log:
                proc = subprocess.run(
                    [executable, "--smoke-test", "--smoke-check-restart", *extra],
                    env={**base_env, "ARENA_SMOKE_RESULT": str(path)},
                    stdout=log,
                    stderr=log,
                    timeout=80,
                )
            if proc.returncode != 0:
                raise AssertionError(
                    f"{name} exited {proc.returncode}; see {out / f'{name}.log'}"
                )
            with lock:
                assert len(events) == 4, (name, events)
            return json.loads(path.read_text())

        checked = check_restart([], "restart-conservative")
        assert checked["reason"] == "restart-conservative", checked
        assert checked["didContinue"] is False, checked
        assert checked["stage"] == "independent", checked["stage"]
        assert "核对原页" in checked["statuses"][provider], checked["statuses"]
        assert checked["seatStates"][provider]["kind"] == "needsAction", checked["seatStates"]
        for provider_id in answered_seats:
            assert checked["seatStates"][provider_id]["kind"] == "answered", checked["seatStates"]

        from_history = check_restart(["--smoke-check-history"], "restart-from-history")
        assert from_history["didContinue"] is False, from_history
        assert from_history["seatStates"][provider]["kind"] == "needsAction", from_history

        mismatch = check_restart(
            ["--continue-saved-discussion", "arena-other-session"],
            "restart-wrong-id",
        )
        assert mismatch["didContinue"] is False, mismatch

        original_state = session_file.read_text()

        def rewrite_state(mutate):
            state = json.loads(original_state)
            mutate(state)
            session_file.write_text(json.dumps(state, ensure_ascii=False, indent=2))

        try:
            def mark_paused(state):
                inner = json.loads(state["sessionJSON"])
                inner["paused"] = True
                state["sessionJSON"] = json.dumps(inner, ensure_ascii=False)

            rewrite_state(mark_paused)
            paused = check_restart(
                ["--continue-saved-discussion", session_id], "restart-paused"
            )
            assert paused["didContinue"] is False, paused
            paused_history = check_restart(["--smoke-check-history"], "restart-paused-history")
            assert paused_history["session"]["paused"] is True, paused_history

            rewrite_state(lambda state: state.update(manualProviders=[provider]))
            taken = check_restart(
                ["--continue-saved-discussion", session_id], "restart-taken-over"
            )
            assert taken["didContinue"] is False, taken
            taken_history = check_restart(["--smoke-check-history"], "restart-taken-over-history")
            assert taken_history["seatStates"][provider]["kind"] == "takenOver", taken_history
        finally:
            session_file.write_text(original_state)

        phase[0] = 2
        result_2 = out / "result-2.json"
        with (out / "app-2.log").open("w") as log:
            second = subprocess.run(
                [
                    executable,
                    "--smoke-test",
                    "--smoke-continue-recovery",
                    "--continue-saved-discussion",
                    session_id,
                ],
                env={**base_env, "ARENA_SMOKE_RESULT": str(result_2)},
                stdout=log,
                stderr=log,
                timeout=210,
            )
        if second.returncode != 0:
            raise AssertionError(
                f"continue process exited {second.returncode}; see {out / 'app-2.log'}"
            )

        final = json.loads(result_2.read_text())
        assert final["reason"] == "recovered", final
        assert final["sessionID"] == session_id, final
        session_2 = final["session"]
        assert session_2["stage"] == "done", session_2
        history = session_2["history"]
        assert len(history) == 24, history
        assert all(row["status"] == "answered" for row in history), history
        stages = {}
        for row in history:
            stages.setdefault(row["stage"], []).append(row)
        assert {key: len(value) for key, value in stages.items()} == {
            "independent": 3,
            "critique": 9,
            "proposal": 3,
            "vote": 9,
        }, {key: len(value) for key, value in stages.items()}

        saved_2 = json.loads(session_file.read_text())
        intents_2 = {item["taskId"]: item for item in saved_2["intents"]}
        for provider_id, when in sent_at.items():
            task_id = first_round[provider_id]["id"]
            assert intents_2[task_id]["phase"] == "submitted", intents_2[task_id]
            assert intents_2[task_id]["submittedAt"] == when, (
                provider_id,
                when,
                intents_2[task_id],
            )
        assert intents_2[prepared_task]["phase"] == "submitted", intents_2[prepared_task]
        assert intents_2[prepared_task]["submittedAt"] is not None, intents_2[prepared_task]

        time.sleep(0.5)
        phase_2_events = [event for event in events if event["phase"] == 2]
        assert len(phase_2_events) == 2 * (len(history) - 2), phase_2_events
        phase_2_prompts = [
            event for event in phase_2_events if "prompt" in event
        ]
        assert len(phase_2_prompts) == len(history) - 2, phase_2_prompts
        # All seats receive the same independent question, so identify a
        # re-send by the site that received it, not by prompt text alone.
        independent_prompt = normalize(next(iter(first_round.values()))["prompt"])
        for provider_id in answered_seats:
            repeats = [
                event
                for event in phase_2_prompts
                if event["site"] == provider_id
                and normalize(event["prompt"]) == independent_prompt
            ]
            assert not repeats, (provider_id, repeats)
        # Exactly one new first-round send: the seat that was prepared.
        missing = [
            event
            for event in phase_2_prompts
            if event["site"] == provider
            and normalize(event["prompt"]) == independent_prompt
        ]
        assert len(missing) == 1, missing
        assert phase_2_prompts[0] is missing[0], phase_2_prompts[0]

        # The conditional vote must survive into the report.
        assert session_2["stopReason"] == "conditional-agreement", session_2["stopReason"]
        export = (out / "export.md").read_text()
        assert "条件：需要补一组小样本证据" in export, export[-800:]
        assert session_2["report"] in export

        (out / "observed.json").write_text(
            json.dumps(events, ensure_ascii=False, indent=2)
        )
        (out / "summary.json").write_text(
            json.dumps(
                {
                    "sessionID": session_id,
                    "firstRoundAnswers": sorted(answered_seats),
                    "preparedProvider": provider,
                    "phase1Events": len(phase_1_events),
                    "phase2Events": len(phase_2_events),
                    "resendsForAnsweredSeats": 0,
                    "stage": session_2["stage"],
                    "stopReason": session_2["stopReason"],
                    "history": len(history),
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        print((out / "summary.json").read_text())
        print(
            "PASS: first round had two saved answers and one prepared intent; "
            "explicit continuation sent only the missing seat, then completed "
            "critique/proposal/vote and kept the conditional report"
        )
    finally:
        (out / "observed.json").write_text(
            json.dumps(events, ensure_ascii=False, indent=2)
        )
        qa.cleanup()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
