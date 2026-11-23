#!/usr/bin/env python3
"""Compile and run the pure candidate-version comparison checks.

Target: G2/G3/G4, R04/R05/R07. Verifies the reader's version history,
digest-bound same-version ballots, wrong-digest exclusion, paragraph-level
changes and the bounded long-text path. This is a pure binary check: no app
launch, window, web view, network or real account.

Run from the repository root:

    python3 tests/native_candidate_comparison.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-candidate-comparison-") as temp:
        root = Path(temp)
        sources = []
        for source in (ROOT / "desktop" / "ArenaCandidateComparison.swift",
                       ROOT / "tests" / "native_candidate_comparison.swift"):
            target = root / source.name
            target.write_bytes(source.read_bytes())
            sources.append(target)

        binary = root / "native-candidate-comparison-check"
        compile_cmd = [
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-swift-version",
            "5",
            *[str(path) for path in sources],
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("native candidate comparison check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
