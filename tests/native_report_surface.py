#!/usr/bin/env python3
"""Compile and run the full-report text surface checks.

Target: G2/G4, R05/R07. ``ArenaReportTypesetter`` must keep every block's text,
the table column correspondence, live source and web links, strikethrough, and
must not split emoji across UTF-16 code units. ``ArenaReportSurfacePolicy`` must
switch to the single surface for one big table or one big list. This is a pure
binary check: no app launch, window, web view, network or real account.

Run from the repository root:

    python3 tests/native_report_surface.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-report-surface-") as temp:
        root = Path(temp)
        sources = []
        for source in (ROOT / "desktop" / "ArenaMarkdownView.swift",
                       ROOT / "tests" / "native_report_surface.swift"):
            target = root / source.name
            target.write_bytes(source.read_bytes())
            sources.append(target)

        binary = root / "native-report-surface-check"
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
            "SwiftUI",
            *[str(path) for path in sources],
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("native report surface check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
