#!/usr/bin/env python3
"""The keyboard's identity must agree between its Info.plist and TildeProductProfile.production.

If the plist's InputMethodConnectionName drifts from the profile's
inputMethodConnectionName, the keyboard still installs but never gets a
session. This is a "files must agree" check, so it lives here rather than in a
Swift test that reads Sources/ as text.

    python3 scripts/dev/check-keyboard-identity.py
    python3 scripts/dev/check-keyboard-identity.py --self-test
"""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PLIST = REPO_ROOT / "Sources/TranscriptedKeyboard/Info.plist"
PROFILE = REPO_ROOT / "Sources/TranscriptedWriting/Core/Runtime/TildeProductProfile.swift"


def production_value(swift: str, prop: str) -> str | None:
    """The string a `var <prop>: String { switch ... case .production: "x" }` returns."""
    body = re.search(r"var\s+" + re.escape(prop) + r"\s*:\s*String\s*\{(.*?)\n    \}", swift, re.S)
    if not body:
        return None
    match = re.search(r'case\s+\.production\s*:\s*"([^"]*)"', body.group(1))
    return match.group(1) if match else None


def problems(plist: dict, swift: str) -> list[str]:
    bundle_id = production_value(swift, "inputMethodBundleIdentifier")
    connection = production_value(swift, "inputMethodConnectionName")
    if bundle_id is None or connection is None:
        return ["could not read the production profile's input-method values from TildeProductProfile.swift"]
    expected = {
        "CFBundleIdentifier": bundle_id,
        "TISInputSourceID": bundle_id,
        "InputMethodConnectionName": connection,
        "InputMethodServerControllerClass": "GhostInputController",
        "CFBundleExecutable": "TranscriptedKeyboard",
    }
    return [
        f"Info.plist {key} is {plist.get(key)!r}, expected {want!r}"
        for key, want in expected.items()
        if plist.get(key) != want
    ]


def main() -> int:
    plist = plistlib.loads(PLIST.read_bytes())
    found = problems(plist, PROFILE.read_text(encoding="utf-8"))
    for line in found:
        print(f"FAIL: {line}")
    if found:
        print("The keyboard Info.plist and TildeProductProfile.production must agree.")
        return 1
    print("keyboard identity: Info.plist matches TildeProductProfile.production")
    return 0


def self_test() -> int:
    swift = """
    public var inputMethodBundleIdentifier: String {
        switch self {
        case .production: "com.x.Transcripted"
        case .preview9B: "com.x.Preview"
        }
    }

    public var inputMethodConnectionName: String {
        switch self {
        case .production: "Conn_1"
        case .preview9B: "Conn_9B"
        }
    }
"""
    good = {
        "CFBundleIdentifier": "com.x.Transcripted",
        "TISInputSourceID": "com.x.Transcripted",
        "InputMethodConnectionName": "Conn_1",
        "InputMethodServerControllerClass": "GhostInputController",
        "CFBundleExecutable": "TranscriptedKeyboard",
    }
    assert problems(good, swift) == [], problems(good, swift)
    drifted = dict(good, InputMethodConnectionName="Conn_9B")
    assert len(problems(drifted, swift)) == 1
    assert problems(good, "nothing here")
    print("self-test ok")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else main())
