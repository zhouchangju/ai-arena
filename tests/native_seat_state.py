#!/usr/bin/env python3
"""Compile and run the native structured-seat-state checks.

Target: G2/G3. The seat badge is derived from a structured ``kind`` plus a
``detail`` sentence; status text is never keyword-matched. The same structured
outcome is used by export and read-only history, so a saved session keeps its
final same-version stance or skip instead of a transient UI label.

The check is a pure binary: no app launch, no window, no web view, no network
and no real account. It compiles a disposable copy of the current desktop Swift
sources, with only the production ``@main`` removed from ``ArenaApp.swift``,
together with ``tests/native_seat_state.swift``.

Run from the repository root:

    python3 tests/native_seat_state.py

Exit code 0 means every check passed.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from swift_sources import stage_desktop_sources

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-seat-state-") as temp:
        root = Path(temp)
        # Copy the sources once so a concurrent editor cannot change an input
        # file in the middle of the Swift build. The copied ArenaApp.swift
        # drops only its production @main; this check supplies the entry point.
        sources = stage_desktop_sources(ROOT, root)
        check = root / "native_seat_state.swift"
        check.write_bytes((ROOT / "tests" / "native_seat_state.swift").read_bytes())

        binary = root / "native-seat-state-check"
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
            "WebKit",
            "-framework",
            "SwiftUI",
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
            print("native seat state check did not compile", file=sys.stderr)
            return 1
        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
