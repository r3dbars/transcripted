#!/usr/bin/env python3
"""Compile the native fixture's actual filesystem policy without app/UI state."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    swiftc = shutil.which("swiftc")
    if not swiftc:
        if sys.platform == "darwin":
            raise SystemExit("FAIL: Swift is required for fixture admission regression")
        print("SKIP: fixture admission regression needs Swift (no toolchain on this host)")
        return
    repo = Path(__file__).resolve().parents[2]
    # The subprocess uses only synthetic files; no AppKit, defaults or app code.
    with tempfile.TemporaryDirectory(prefix="capture-list-admission-") as scratch:
        root = Path(scratch).resolve()
        root.chmod(0o700)
        binary = root / "fixture-path-tests"
        subprocess.run([swiftc, str(repo / "Tests/UI/CaptureListFixturePaths.swift"),
                        str(repo / "Tests/UI/CaptureListFixturePathsTests.swift"),
                        "-module-cache-path", str(root / "modules"), "-o", str(binary)], check=True, capture_output=True, text=True)
        env = dict(os.environ, TRANSCRIPTED_DISABLE_FILE_LOGGER="1")
        subprocess.run([str(binary), str(root)], env=env, check=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        # No compiler diagnostics with private absolute checkout/temp paths.
        raise SystemExit(f"FAIL: fixture admission compile/run exited {error.returncode}") from None
