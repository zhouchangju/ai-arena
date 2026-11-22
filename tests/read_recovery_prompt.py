#!/usr/bin/env python3
"""Compile and run the read-only rebuild prompt checks.

``desktop/ArenaEngine.swift`` (intent-phase gate) and ``desktop/SitePane.swift``
(shape check) are compiled with ``tests/read_recovery_prompt.swift``. The check
is pure: no app launch, no web view, no network, no account and no page click.

Run from the repository root:

    python3 tests/read_recovery_prompt.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-read-prompt-check-") as temp:
        binary = Path(temp) / "read-recovery-prompt-check"
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
            str(ROOT / "desktop" / "ArenaEngine.swift"),
            str(ROOT / "desktop" / "SitePane.swift"),
            str(ROOT / "tests" / "read_recovery_prompt.swift"),
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("read-recovery-prompt check did not compile", file=sys.stderr)
            return 1

        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
