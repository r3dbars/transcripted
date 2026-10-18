#!/usr/bin/env python3
"""Keep calls the app must never make out of the files that must not make them.

Each rule names a set of Swift files and the calls none of them may contain.
These used to be Swift fast tests that read Sources/ as text (Tests/README.md,
"Test rules", rule 3). A banned-call scan is a lint over files, not a promise a
test can check through inputs and outputs, so it lives here with the other
consistency checks. Stdlib only, offline, writes nothing.

Rules:

  * Dictation never writes the Mac-wide default input. The only legitimate
    writes are PersistentDictationInputController's, through
    DefaultInputDeviceMonitor. (was Tests/BluetoothRouteContractTests.swift)
  * Diagnostic file writers avoid the legacy FileHandle APIs that raise
    uncatchable ObjC NSExceptions on I/O failure. `//` comments are ignored so
    the notes that name those APIs don't trip it.
    (was Tests/ObservabilityLogWriterTests.swift)
  * Submitting feedback opens email silently: no app sound cue and no system
    beep. (was Tests/DictationSoundsTests.swift)

    python3 scripts/dev/check-banned-calls.py
    python3 scripts/dev/check-banned-calls.py --self-test
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Slice:
    """Only the text from `start` up to (not including) `end` is scanned."""

    start: str
    end: str


@dataclass(frozen=True)
class Rule:
    name: str
    banned: tuple[str, ...]
    why: str
    # Explicit files, or a folder plus a filename prefix (all `.swift` files).
    files: tuple[str, ...] = ()
    folder: str = ""
    prefix: str = ""
    exclude: tuple[str, ...] = ()
    # A folder scan must find more than this many files, so a rename that
    # empties the scan fails instead of passing on nothing.
    min_files: int = 0
    strip_line_comments: bool = False
    slice: Slice | None = None


RULES: tuple[Rule, ...] = (
    Rule(
        name="dictation never writes the Mac-wide default input",
        folder="Sources/Speech",
        prefix="Parakeet",
        # Declares the CoreAudio setter that PersistentDictationInputController uses.
        exclude=("ParakeetAudioDeviceLookup.swift",),
        min_files=10,
        banned=("setDefaultInputDeviceID(", "setDefaultInputDevice("),
        why="the dictation engine must not write the Mac-wide default input",
    ),
    Rule(
        name="diagnostic file writers avoid the NSException-throwing legacy FileHandle APIs",
        files=(
            "Sources/Observability/LockedFileAppender.swift",
            "Sources/Observability/EventReporter.swift",
            "Sources/Observability/ReliabilityPacketRecorder.swift",
            "Sources/Observability/AppLogSink.swift",
            "Sources/TranscriptedCore/Logging/FileLogger.swift",
            "Sources/TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift",
        ),
        strip_line_comments=True,
        banned=(
            "seekToEndOfFile()",
            "readData(ofLength:",
            ".write(data)",
            "synchronizeFile()",
            "closeFile()",
        ),
        why="the legacy FileHandle call raises an uncatchable NSException on I/O failure",
    ),
    Rule(
        name="support email actions stay silent",
        files=("Sources/App/TranscriptedSupportActions.swift",),
        banned=("AppSoundPlayer.shared.play(", "NSSound.beep()"),
        why="support email actions should not play a UI sound cue or a system beep",
    ),
    Rule(
        name="Home contextual feedback submit stays silent",
        files=("Sources/UI/Settings/TranscriptedSettingsView.swift",),
        slice=Slice(start="private func submitHomeFeedback", end="private func flashCopied"),
        banned=("AppSoundPlayer.shared.play", "NSSound.beep()"),
        why="Home contextual feedback should open email without an app sound or a system beep",
    ),
)


def strip_line_comments(text: str) -> str:
    """Drops everything from `//` to the end of each line. Coarse on purpose (it
    does not model strings), same as the Swift helper this replaced."""
    return "\n".join(line.split("//", 1)[0] for line in text.split("\n"))


def rule_files(root: Path, rule: Rule) -> list[str]:
    if rule.folder:
        folder = root / rule.folder
        if not folder.is_dir():
            return []
        return sorted(
            f"{rule.folder}/{p.name}"
            for p in folder.iterdir()
            if p.is_file()
            and p.name.startswith(rule.prefix)
            and p.name.endswith(".swift")
            and p.name not in rule.exclude
        )
    return list(rule.files)


def check(root: Path, rules: tuple[Rule, ...] = RULES) -> list[str]:
    problems: list[str] = []
    for rule in rules:
        files = rule_files(root, rule)
        if rule.folder and len(files) <= rule.min_files:
            problems.append(
                f"{rule.name}: found {len(files)} {rule.prefix}*.swift files under {rule.folder}, "
                f"expected more than {rule.min_files} (did they move?)"
            )
        for rel in files:
            path = root / rel
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                problems.append(f"{rel}: cannot read it ({rule.name})")
                continue
            if not text:
                problems.append(f"{rel}: is empty ({rule.name})")
                continue
            if rule.strip_line_comments:
                text = strip_line_comments(text)
            if rule.slice is not None:
                start = text.find(rule.slice.start)
                if start == -1:
                    problems.append(f"{rel}: lost `{rule.slice.start}`, so `{rule.name}` can't be checked")
                    continue
                end = text.find(rule.slice.end, start)
                text = text[start:] if end == -1 else text[start:end]
            for needle in rule.banned:
                if needle in text:
                    problems.append(f"{rel}: calls `{needle}`: {rule.why}")
    return problems


def run(root: Path) -> int:
    problems = check(root)
    if problems:
        print("Banned calls found:")
        for item in problems:
            print(f"  - {item}")
        return 1
    print(f"Banned calls OK: {len(RULES)} rules hold.")
    return 0


def self_test() -> None:
    def build(files: dict[str, str]) -> Path:
        tmp = Path(tempfile.mkdtemp())
        for rel, text in files.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text(text)
        return tmp

    good: dict[str, str] = {}
    for index in range(11):
        good[f"Sources/Speech/ParakeetPart{index}.swift"] = "let ok = 1\n"
    good["Sources/Speech/ParakeetAudioDeviceLookup.swift"] = "func setDefaultInputDeviceID(_ id: UInt32) {}\n"
    good["Sources/Speech/OtherThing.swift"] = "setDefaultInputDevice(1)\n"
    for rel in RULES[1].files:
        good[rel] = "// seekToEndOfFile() is banned; use seekToEnd()\ntry handle.seekToEnd()\n"
    good["Sources/App/TranscriptedSupportActions.swift"] = "func sendFeedback() { open(url) }\n"
    good["Sources/UI/Settings/TranscriptedSettingsView.swift"] = (
        "private func submitHomeFeedback() { open(url) }\n"
        "private func flashCopied() { AppSoundPlayer.shared.play(.copy) }\n"
    )
    assert check(build(good)) == [], check(build(good))

    breaks = [
        ("Sources/Speech/ParakeetPart3.swift", "let ok = 1\n", "device.setDefaultInputDeviceID(id)\n"),
        ("Sources/Speech/ParakeetPart4.swift", "let ok = 1\n", "setDefaultInputDevice(id)\n"),
        (RULES[1].files[0], "try handle.seekToEnd()", "handle.seekToEndOfFile()"),
        (RULES[1].files[5], "try handle.seekToEnd()", "handle.closeFile()"),
        (RULES[1].files[2], "try handle.seekToEnd()", "handle.write(data) // fine?"),
        ("Sources/App/TranscriptedSupportActions.swift", "open(url)", "NSSound.beep()"),
        ("Sources/App/TranscriptedSupportActions.swift", "open(url)", "AppSoundPlayer.shared.play(.done)"),
        ("Sources/UI/Settings/TranscriptedSettingsView.swift", "{ open(url) }", "{ AppSoundPlayer.shared.play(.x) }"),
        ("Sources/UI/Settings/TranscriptedSettingsView.swift", "{ open(url) }", "{ NSSound.beep() }"),
        # the slice anchor vanishing is a failure, not a silent pass
        ("Sources/UI/Settings/TranscriptedSettingsView.swift", "submitHomeFeedback", "sendHomeFeedback"),
    ]
    for rel, old, new in breaks:
        broken = dict(good)
        assert old in broken[rel], (rel, old)
        broken[rel] = broken[rel].replace(old, new)
        assert check(build(broken)), (rel, new)

    # A scan that finds too few engine files fails.
    sparse = {k: v for k, v in good.items() if "ParakeetPart" not in k}
    assert any("expected more than" in p for p in check(build(sparse)))
    # Missing listed files fail.
    assert check(build({}))
    print("check-banned-calls self-test passed")


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
