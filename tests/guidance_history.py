#!/usr/bin/env python3
"""Compile and run the guidance/history checks.

Target: G1/G2/G3/G4, R03/R06/R07. Verifies the pure rules behind the new
"补充条件" affordance and the searchable local history:

* a condition is accepted only in a live independent/critique phase, while
  paused, in the same pinned session/stage/round;
* saved conditions keep their immutable stage/round marker and the shared
  engine's delivery bookkeeping;
* history search filters local summaries by question, seat, outcome and state
  without mutating them;
* the version-scoped ballot projection keeps one candidate, its text, its
  digest metadata and that version's votes, and never prompts.

The check is a pure binary: no app launch, no window, no web view, no network
and no real account.

Run from the repository root:

    python3 tests/guidance_history.py

Exit code 0 means every check passed.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SOURCES = (
    "ArenaEngine.swift",
    "ArenaEvaluation.swift",
    "ArenaGuidance.swift",
    "ArenaHistorySearch.swift",
)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-guidance-history-") as temp:
        root = Path(temp)
        # Copy the sources once so a concurrent editor cannot change an input
        # file in the middle of the Swift build.
        sources = []
        for name in SOURCES:
            source = ROOT / "desktop" / name
            target = root / name
            target.write_bytes(source.read_bytes())
            sources.append(target)
        check = root / "guidance_history.swift"
        check.write_bytes((ROOT / "tests" / "guidance_history.swift").read_bytes())

        binary = root / "guidance-history-check"
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
            print("guidance/history check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
