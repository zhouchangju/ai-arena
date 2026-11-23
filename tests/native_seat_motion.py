#!/usr/bin/env python3
"""Compile and run the pure seat-motion policy checks.

Target: G1/G2/G4, R02/R03/R06/R07. The paper plane may only follow a
page-verified user turn from an active send, and the saved-answer check may only
follow a durable answer write. Pause, takeover, history and restoration are
excluded. This is a pure binary check: no app launch, window, web view, network
or real account.

Run from the repository root:

    python3 tests/native_seat_motion.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-seat-motion-") as temp:
        root = Path(temp)
        sources = []
        for source in (ROOT / "desktop" / "ArenaSeatMotion.swift",
                       ROOT / "tests" / "native_seat_motion.swift"):
            target = root / source.name
            target.write_bytes(source.read_bytes())
            sources.append(target)

        binary = root / "native-seat-motion-check"
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
            print("native seat motion check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
