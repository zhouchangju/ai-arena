#!/usr/bin/env python3
"""Compile and run the structured-report artifact checks.

Target: G2/G3/G4, R05/R07. Verifies the fixed candidate blocks, the old-format
fallback, the condition/dispute graph, the standalone escaped HTML, the
non-truncating video storyboard and a real local H.264 MP4. This is a pure
binary check: no app launch, window, web view, network or real account.

Run from the repository root:

    python3 tests/report_artifacts.py

Exit code 0 means every check passed.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-report-artifacts-") as temp:
        root = Path(temp)
        sources = []
        for source in (
            ROOT / "desktop" / "ArenaReportDigest.swift",
            ROOT / "desktop" / "ArenaReportVideo.swift",
            ROOT / "tests" / "report_artifacts.swift",
        ):
            target = root / source.name
            target.write_bytes(source.read_bytes())
            sources.append(target)

        binary = root / "report-artifacts-check"
        compile_cmd = [
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-swift-version",
            "5",
            "-framework",
            "AVFoundation",
            "-framework",
            "CoreMedia",
            "-framework",
            "CoreVideo",
            "-framework",
            "CoreText",
            *[str(path) for path in sources],
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("report artifact check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
