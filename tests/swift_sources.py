"""Stage a disposable copy of the desktop Swift sources for pure checks.

The pure checks that link ``ArenaModel`` need the whole desktop module. Copying
the current files into a temp directory keeps a concurrent editor from changing
an input midway. The production entry point is removed from the copied
``ArenaApp.swift`` only, so the check can supply its own ``@main``; every other
byte is copied unchanged. The marker is exact and must occur once.
"""

from __future__ import annotations

from pathlib import Path

APP_SOURCE = "ArenaApp.swift"
PRODUCTION_MAIN = b"@main\nstruct ArenaDesktopApp: App {"
WITHOUT_PRODUCTION_MAIN = b"struct ArenaDesktopApp: App {"


def stage_desktop_sources(root: Path, destination: Path) -> list[Path]:
    """Copy ``desktop/*.swift`` into ``destination`` and return the copies."""
    destination.mkdir(parents=True, exist_ok=True)
    sources = []
    app_found = False
    for source in sorted((root / "desktop").glob("*.swift")):
        data = source.read_bytes()
        if source.name == APP_SOURCE:
            app_found = True
            count = data.count(PRODUCTION_MAIN)
            if count != 1:
                raise RuntimeError(
                    f"{source} must contain exactly one production @main marker, found {count}"
                )
            data = data.replace(PRODUCTION_MAIN, WITHOUT_PRODUCTION_MAIN, 1)
        target = destination / source.name
        target.write_bytes(data)
        sources.append(target)
    if not app_found:
        raise RuntimeError(f"no {APP_SOURCE} found under {root / 'desktop'}")
    return sources
