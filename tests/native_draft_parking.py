#!/usr/bin/env python3
"""Compile and run the unsent-draft parking checks.

Target: G1/G3/G4. Opening or continuing history replaces the composer question
and clears its attachments. The check verifies the pure parking rules that keep
an unsent draft safe across history viewing in one run:

* the body text and the same ordered attachment array are parked and returned
  together, ids included;
* an empty composer (or a whitespace-only body with no attachment) parks nothing,
  so no "return to draft" affordance appears on a normal visit;
* a restored history question is never captured as a new draft;
* switching between history records never overwrites the parked draft, and a
  second visit parks the edited body again;
* only a discussion that really started consumes the draft; a refused start
  keeps it;
* a quit with both a running discussion and a parked draft shows one dialog
  that states the resumable progress *and* the permanent draft loss, with 取消
  as the default button;
* returning to the draft is direct in read-only review but must be confirmed
  while a discussion is running, and exists only when a draft is parked.

This is a pure binary: no app launch, no window, no web view, no network and no
real account. It compiles a disposable copy of ``ArenaEngine.swift`` and
``ArenaEvaluation.swift`` -- the files that own the parking rules -- together
with ``tests/native_draft_parking.swift``. The whole desktop module is
deliberately not staged here: several agents edit this worktree at once, and a
check for this one rule must stay runnable while another editor's UI change is
mid-flight. ``tests/native_seat_state.py`` remains the whole-module compile
check.

Run from the repository root:

    python3 tests/native_draft_parking.py

Exit code 0 means every check passed.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ("ArenaEngine.swift", "ArenaEvaluation.swift")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-draft-parking-") as temp:
        root = Path(temp)
        sources = []
        for name in SOURCES:
            source = ROOT / "desktop" / name
            target = root / name
            target.write_bytes(source.read_bytes())
            sources.append(target)
        check = root / "native_draft_parking.swift"
        check.write_bytes((ROOT / "tests" / "native_draft_parking.swift").read_bytes())

        binary = root / "native-draft-parking-check"
        compile_cmd = [
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-swift-version",
            "5",
            "-framework",
            "AppKit",
            "-framework",
            "JavaScriptCore",
            *[str(path) for path in sources],
            str(check),
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("native draft parking check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
