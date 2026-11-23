"""Run loopback acceptance under an app identity separate from the user's app."""
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

QA_BUNDLE_ID = "local.ai-arena.desktop.qa"


class QAApp:
    def __init__(self, directory, app, info):
        self._directory = directory
        self.app = app
        self.version = info["CFBundleShortVersionString"]
        self.executable = app / "Contents" / "MacOS" / info["CFBundleExecutable"]

    def cleanup(self):
        # Only the disposable copy belongs to this test. A different test may
        # be running in the QA WebKit profile at the same time.
        self._directory.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.cleanup()


def stage_qa_app(source: Path, staging_root: Path) -> QAApp:
    with (source / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "local.ai-arena.desktop":
        raise ValueError("Expected the built AI Arena application")
    staging_root.mkdir(parents=True, exist_ok=True)
    directory = tempfile.TemporaryDirectory(prefix="bundle-", dir=staging_root)
    try:
        app = Path(directory.name) / "AI Arena QA.app"
        shutil.copytree(source, app, symlinks=True)
        info.update(CFBundleName="AI Arena QA", CFBundleDisplayName="AI Arena QA",
                    CFBundleIdentifier=QA_BUNDLE_ID, LSUIElement=True)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict",
                        "-R", f'=identifier "{QA_BUNDLE_ID}"', str(app)], check=True)
        return QAApp(directory, app, info)
    except BaseException:
        directory.cleanup()
        raise
