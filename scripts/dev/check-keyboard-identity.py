#!/usr/bin/env python3
"""Keep the keyboard's Info.plist in step with its production profile.

The keyboard's identity lives in places that must agree: its Info.plist,
`TildeProductProfile.production`, the bundle script, and PackagedAppSmoke. If the
plist's connection name drifts, `main.swift` still registers
`profile.inputMethodConnectionName`, the keyboard installs, and it silently never
gets a session. This pins the plist to the profile.

It used to be a Swift test that read the plist out of Sources/
(Tests/TranscriptedWritingTests/Core/KeyboardIdentityTests.swift). Two files
agreeing is a consistency check, so it lives here. The profile's own values are
still checked in Swift by `productionProfileCarriesTranscriptedIdentity`.
Stdlib only, offline, writes nothing.

    python3 scripts/dev/check-keyboard-identity.py
    python3 scripts/dev/check-keyboard-identity.py --self-test
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

PLIST = "Sources/TranscriptedKeyboard/Info.plist"
PROFILE = "Sources/TranscriptedWriting/Core/Runtime/TildeProductProfile.swift"

CONTROLLER_CLASS = "GhostInputController"
EXECUTABLE = "TranscriptedKeyboard"


def production_value(profile_source: str, property_name: str) -> str | None:
    """The string literal `case .production:` returns inside
    `public var <property_name>: String { switch self { ... } }`."""
    body = re.search(
        rf"\bvar\s+{re.escape(property_name)}\s*:\s*String\s*\{{(.*?)\n    \}}",
        profile_source,
        re.S,
    )
    if body is None:
        return None
    value = re.search(r'case\s+\.production\s*:\s*"([^"\n]*)"', body.group(1))
    return value.group(1) if value else None


def check(root: Path) -> list[str]:
    problems: list[str] = []
    try:
        plist = plistlib.loads((root / PLIST).read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return [f"{PLIST}: cannot read it as a property list ({error.__class__.__name__})"]
    if not isinstance(plist, dict):
        return [f"{PLIST}: is not a dictionary"]
    try:
        profile = (root / PROFILE).read_text(encoding="utf-8")
    except OSError:
        return [f"{PROFILE}: cannot read it"]

    bundle_id = production_value(profile, "inputMethodBundleIdentifier")
    connection = production_value(profile, "inputMethodConnectionName")
    if bundle_id is None:
        problems.append(f"{PROFILE}: can't find the production inputMethodBundleIdentifier")
    if connection is None:
        problems.append(f"{PROFILE}: can't find the production inputMethodConnectionName")

    expected = [
        ("CFBundleIdentifier", bundle_id, "the profile's production inputMethodBundleIdentifier"),
        ("TISInputSourceID", bundle_id, "the profile's production inputMethodBundleIdentifier"),
        ("InputMethodConnectionName", connection, "the profile's production inputMethodConnectionName"),
        ("InputMethodServerControllerClass", CONTROLLER_CLASS, "the keyboard's controller class"),
        ("CFBundleExecutable", EXECUTABLE, "the keyboard executable"),
    ]
    for key, want, source in expected:
        if want is None:
            continue
        got = plist.get(key)
        if got != want:
            problems.append(f"{PLIST}: {key} is {got!r}, should be {want!r} ({source})")
    return problems


def run(root: Path) -> int:
    problems = check(root)
    if problems:
        print("Keyboard identity drifted:")
        for item in problems:
            print(f"  - {item}")
        return 1
    print("Keyboard identity OK: Info.plist matches the production profile.")
    return 0


GOOD_PROFILE = """public enum TildeProductProfile: String {
    case production
    case preview9B = "preview-9b"

    public var inputMethodBundleIdentifier: String {
        switch self {
        case .production: "com.example.inputmethod.App"
        case .preview9B: "com.example.inputmethod.Preview"
        }
    }

    public var inputMethodConnectionName: String {
        switch self {
        case .production: "Keyboard_1_Connection"
        case .preview9B: "Keyboard_Preview_Connection"
        }
    }
}
"""

GOOD_PLIST = {
    "CFBundleIdentifier": "com.example.inputmethod.App",
    "TISInputSourceID": "com.example.inputmethod.App",
    "InputMethodConnectionName": "Keyboard_1_Connection",
    "InputMethodServerControllerClass": CONTROLLER_CLASS,
    "CFBundleExecutable": EXECUTABLE,
}


def self_test() -> None:
    def build(plist: dict | None, profile: str | None) -> Path:
        tmp = Path(tempfile.mkdtemp())
        if plist is not None:
            (tmp / PLIST).parent.mkdir(parents=True, exist_ok=True)
            (tmp / PLIST).write_bytes(plistlib.dumps(plist))
        if profile is not None:
            (tmp / PROFILE).parent.mkdir(parents=True, exist_ok=True)
            (tmp / PROFILE).write_text(profile)
        return tmp

    assert check(build(GOOD_PLIST, GOOD_PROFILE)) == [], check(build(GOOD_PLIST, GOOD_PROFILE))

    for key, value in [
        ("CFBundleIdentifier", "com.example.inputmethod.Preview"),
        ("TISInputSourceID", "other"),
        ("InputMethodConnectionName", "Keyboard_Preview_Connection"),
        ("InputMethodServerControllerClass", "OtherController"),
        ("CFBundleExecutable", "Other"),
    ]:
        plist = dict(GOOD_PLIST)
        plist[key] = value
        assert any(key in p for p in check(build(plist, GOOD_PROFILE))), key
        missing = {k: v for k, v in GOOD_PLIST.items() if k != key}
        assert any(key in p for p in check(build(missing, GOOD_PROFILE))), key

    # The profile moving its production connection name is drift too.
    moved = GOOD_PROFILE.replace('case .production: "Keyboard_1_Connection"', 'case .production: "Keyboard_2_Connection"')
    assert any("InputMethodConnectionName" in p for p in check(build(GOOD_PLIST, moved)))
    # The preview value never stands in for production.
    assert production_value(GOOD_PROFILE, "inputMethodConnectionName") == "Keyboard_1_Connection"
    # A profile the parser can't read fails loudly instead of passing.
    renamed = GOOD_PROFILE.replace("inputMethodConnectionName", "connectionName")
    assert any("can't find" in p for p in check(build(GOOD_PLIST, renamed)))
    assert check(build(None, GOOD_PROFILE))
    assert check(build(GOOD_PLIST, None))
    print("check-keyboard-identity self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    return run(REPO_ROOT)


if __name__ == "__main__":
    sys.exit(main())
