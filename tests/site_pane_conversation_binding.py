#!/usr/bin/env python3
"""Run the SitePane ChatGPT temporary-route binding check.

``desktop/SitePane.swift`` is compiled together with
``tests/site_pane_conversation_binding.swift`` by the system Swift compiler.
The check is pure: no app launch, no web view, no network, no account.

It covers the G1/G3 bug where a ChatGPT first answer lands on
``https://chatgpt.com/c/local-chatgpt:<uuid>`` (sometimes percent-encoded)
before the site swaps in a stable ``/c/<id>``. The temporary route must never
be fixed as this seat's conversation and must never be used as a recovery
destination; the stable route and the other providers keep their old rules.

Run from the repository root:

    python3 tests/site_pane_conversation_binding.py

Exit code 0 means all checks passed.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SITE_PANE = ROOT / "desktop" / "SitePane.swift"
CHECK = ROOT / "tests" / "site_pane_conversation_binding.swift"


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="arena-site-pane-check-") as temp:
        binary = Path(temp) / "site-pane-binding-check"
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
            str(SITE_PANE),
            str(CHECK),
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True)
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stdout)
            sys.stderr.write(compiled.stderr)
            print("site-pane binding check did not compile", file=sys.stderr)
            return 1

        ran = subprocess.run([str(binary)], text=True, capture_output=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        return ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
