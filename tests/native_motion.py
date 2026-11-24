#!/usr/bin/env python3
"""Compile and run the unified motion policy checks.

Target: G4, R06/R07. ``ArenaMotion.quick`` and ``ArenaMotion.change`` must both
degrade to an immediate state when the system asks to reduce motion, and both
must stay short. This is a pure binary check: no app launch, window, web view,
network or real account.

Run from the repository root:

    python3 tests/native_motion.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-motion-") as temp:
        root = Path(temp)
        sources = []
        for source in (ROOT / "desktop" / "ArenaMotion.swift",
                       ROOT / "tests" / "native_motion.swift"):
            target = root / source.name
            target.write_bytes(source.read_bytes())
            sources.append(target)

        binary = root / "native-motion-check"
        compile_cmd = [
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-swift-version",
            "5",
            "-framework",
            "SwiftUI",
            *[str(path) for path in sources],
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("native motion check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
