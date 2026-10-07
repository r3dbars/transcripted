#!/usr/bin/env python3
"""Static capture-policy checks for Transcripted's windows and panels.

Moved here from Tests/OverlayScreenSharePrivacyTests.swift, where three suites
read Sources/ as text. They are about the shape of the code, not about what a
running window does (the running NotchIslandPanel and PasteLastDictationFeedbackPanel
are still tested in Swift), so a script is the honest layer:

1. Every NSWindow / NSPanel in Sources/UI is on a reviewed list. A new one fails
   this check until someone decides whether it is protected from screen capture
   (`sharingType = .none`, for live or transcript-bearing surfaces) or capturable
   (normal titled windows, so macOS screenshots work) and adds it below. There is
   no runtime signal for "a new window got added", which is why this is a scan.
2. The titled Onboarding and Settings windows set `sharingType = .readOnly` and
   never `.none`. Settings needs a live app-state object graph the fast runner
   never builds, so the window init is read here instead.
3. Detected meeting prompts go through the call prompt controller, keep the
   calendar vs ad-hoc timeout, use the remind / expire paths, and do not reuse
   the recording overlay's prompt surface. The app delegate has no seam to
   construct, so this is read here.

    python3 scripts/dev/check-window-capture-policy.py
    python3 scripts/dev/check-window-capture-policy.py --self-test
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UI_ROOT = "Sources/UI"

# Update this list when you add, rename, or remove an NSWindow/NSPanel, and say
# in the PR whether the new surface is protected or capturable.
EXPECTED_MARKERS = [
    "Sources/UI/MenuBar/PasteLastDictationFeedback.swift|final class PasteLastDictationFeedbackPanel: NSPanel {",
    "Sources/UI/Overlay/NotchIslandPanel.swift|final class NotchIslandPanel: NSPanel {",
    "Sources/UI/Settings/TranscriptedOnboardingWindowController.swift|let window = NSWindow(",
    "Sources/UI/Settings/TranscriptedSettingsWindowController.swift|let window = NSWindow(",
]

CAPTURABLE_WINDOW_FILES = {
    "TranscriptedOnboardingWindowController": "Sources/UI/Settings/TranscriptedOnboardingWindowController.swift",
    "TranscriptedSettingsWindowController": "Sources/UI/Settings/TranscriptedSettingsWindowController.swift",
}

APP_PATH = "Sources/App/TranscriptedApp.swift"


def window_panel_markers(files: dict[str, str]) -> list[str]:
    """`path|line` for every NSWindow/NSPanel definition or construction under Sources/UI."""
    markers: list[str] = []
    for path, text in files.items():
        if not path.startswith(UI_ROOT + "/") or not path.endswith(".swift"):
            continue
        for raw in text.splitlines():
            line = raw.strip()
            is_panel_class = (
                line.startswith(("class ", "final class ", "private final class "))
                and ": NSPanel" in line
            )
            if is_panel_class or "NSPanel(" in line or "NSWindow(" in line:
                markers.append(f"{path}|{line}")
    return sorted(markers)


def slice_between(text: str, start: str, end: str) -> str:
    i = text.find(start)
    if i < 0:
        return ""
    tail = text[i + len(start):]
    j = tail.find(end)
    return tail if j < 0 else tail[:j]


def problems(files: dict[str, str]) -> list[str]:
    out: list[str] = []

    markers = window_panel_markers(files)
    if markers != EXPECTED_MARKERS:
        added = [m for m in markers if m not in EXPECTED_MARKERS]
        removed = [m for m in EXPECTED_MARKERS if m not in markers]
        out.append(
            "any new Transcripted NSWindow/NSPanel must be reviewed here and classified as protected "
            f"or capturable (new: {added}; gone: {removed})"
        )

    for name, path in CAPTURABLE_WINDOW_FILES.items():
        body = slice_between(files.get(path, ""), "let window = NSWindow(", "super.init(window: window)")
        if "sharingType = .readOnly" not in body:
            out.append(f"{name} should support normal macOS screenshots (sharingType = .readOnly)")
        if "sharingType = .none" in body:
            out.append(f"{name} must not opt itself out of screenshots")

    app = files.get(APP_PATH, "")
    prompt = slice_between(app, "meetingPromptDetector.onPromptRequest =", "// Ad-hoc call detection:")
    if "capturePillController.present(" not in prompt:
        out.append("detected meeting prompts should use the call prompt controller")
    if "MeetingPromptHeuristics.promptTimeoutSeconds" not in prompt:
        out.append("detected meeting prompts should preserve calendar vs ad-hoc prompt timeouts")
    if "capturePillController.onRemind = remindPrompt" not in app:
        out.append("the call prompt should expose the short remind-soon path")
    if "capturePillController.onExpired = expirePrompt" not in app:
        out.append("the call prompt timeout should use the expiry path, not an explicit dismissal")
    if "meetingOverlayController.presentDetectedMeetingPrompt(candidate)" in prompt:
        out.append("detected meeting prompts should not reuse the recording overlay prompt surface")
    return out


def load_files() -> dict[str, str]:
    files: dict[str, str] = {}
    for path in sorted((REPO_ROOT / UI_ROOT).rglob("*.swift")):
        files[path.relative_to(REPO_ROOT).as_posix()] = path.read_text(encoding="utf-8")
    files[APP_PATH] = (REPO_ROOT / APP_PATH).read_text(encoding="utf-8")
    return files


def self_test() -> int:
    files = load_files()
    if problems(files):
        print("self-test: the committed sources should pass", file=sys.stderr)
        return 1

    def broken(path: str, old: str, new: str) -> dict[str, str]:
        assert old in files[path], (path, old)
        return {**files, path: files[path].replace(old, new, 1)}

    onboarding = CAPTURABLE_WINDOW_FILES["TranscriptedOnboardingWindowController"]
    cases = {
        "an opted-out onboarding window": broken(onboarding, "sharingType = .readOnly", "sharingType = .none"),
        "a dropped prompt controller": broken(APP_PATH, "capturePillController.present(", "capturePillController.show("),
        "a dropped expiry path": broken(APP_PATH, "capturePillController.onExpired = expirePrompt", "// removed"),
        "an unreviewed panel": {**files, "Sources/UI/Overlay/Extra.swift": "final class ExtraPanel: NSPanel {\n}\n"},
    }
    for label, changed in cases.items():
        if not problems(changed):
            print(f"self-test: {label} should be caught", file=sys.stderr)
            return 1
    print("window capture policy self-test OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    found = problems(load_files())
    if found:
        print("window capture policy check failed:", file=sys.stderr)
        for line in found:
            print(f"  - {line}", file=sys.stderr)
        return 1
    print("window capture policy OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
