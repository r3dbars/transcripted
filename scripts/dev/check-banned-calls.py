#!/usr/bin/env python3
"""Keep calls the app must never make out of the files that must not make them.

Each rule names a set of Swift files and the calls none of them may contain.
A rule can also name `required` wiring: text that must still appear somewhere
in its files (whitespace-insensitive), for view-wiring promises no fast test
can render, such as "this view routes its failures through the shared copy".
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
  * An idle onboarding window never polls permissions or re-probes system
    audio on activation; the live audio check belongs to its button.
    It still routes app activation and permission changes to its lifecycle
    handler, and leaving it cancels the in-flight audio check.
  * The Agent page and the Settings shell never put a raw error into
    user-facing text; the raw error goes behind Copy Details. Both keep that
    Copy Details reveal and route failures through their shared failure copy.
  * The retained-audio player sizes its hit shape from
    HomeHitTarget.hitSize(forVisibleSize:), so it keeps the 40pt floor.
  * The Settings shell builds the Home row menus from HomeRowMenuPolicy and
    feeds it the row's real state (audio to reveal, a retranscription input,
    pending speaker review); re-transcribe takes its title from
    RecentMeetingRetranscriptionMenuActionPolicy.
    (these five were Tests/UIAutomationSurfaceContractTests.swift)

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
    # Wiring that must still appear somewhere in the rule's files. Matched
    # with runs of whitespace collapsed to one space.
    required: tuple[str, ...] = ()


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
    Rule(
        name="onboarding never polls permissions and keeps its lifecycle wiring",
        files=("Sources/UI/Settings/PermissionsOnboardingView.swift",),
        banned=(
            "while !Task.isCancelled",
            "startPolling()",
            "SystemAudioPermissionRevalidator.revalidateForStatusSurfaces",
        ),
        why="an idle onboarding window must not loop on permission probes or compete with the explicit audio check",
        required=(
            "publisher(for: NSApplication.didBecomeActiveNotification)) { _ in handleLifecycle(.appBecameActive) }",
            "publisher(for: .transcriptedPermissionsDidChange)) { _ in handleLifecycle(.permissionsChanged) }",
            ".onDisappear { handleLifecycle(.windowDisappeared) }",
            "if effects.contains(.cancelSystemAudioCheck) { stopPermissionRevalidation() }",
            "func stopPermissionRevalidation() { systemAudioRequestTask?.cancel()",
            "checkWasCancelled: Task.isCancelled",
            "actionTitle: systemAudioPresentation.actionTitle",
        ),
    ),
    Rule(
        name="Agent page failures use the shared copy, never a raw error",
        files=("Sources/UI/Settings/AgentConnectionSettingsPage.swift",),
        banned=(".failed(error.localizedDescription)", "\\(error"),
        why="setup failures show AgentSetupFailureCopy; the raw error goes behind Copy Details",
        required=(
            "AgentSetupFailureCopy.connectFailure(agentName:",
            "AgentSetupFailureCopy.codexInboxFailure(",
            "private func failureNotice(",
            "transcripted.settings.agent.connect-error-details.",
        ),
    ),
    Rule(
        name="Settings shell statuses use SettingsActionFailureCopy, never a raw error",
        folder="Sources/UI/Settings",
        prefix="TranscriptedSettingsView",
        min_files=5,
        banned=(
            "\\(error",
            "Status = error.localizedDescription",
            "statusDescription = error.localizedDescription",
        ),
        why="Settings statuses use SettingsActionFailureCopy; the raw error goes behind Copy Details",
        required=(
            "func settingsFailureDetailsButton(",
            "settingsFailureDetailsButton(details)",
            "modelCacheCleanupStatus = SettingsActionFailureCopy.modelCacheRemoval",
            "launchAtLogin.statusDescription = SettingsActionFailureCopy.launchAtLogin",
            "captureLibraryMigrationStatus = SettingsActionFailureCopy.captureLibraryMigration(",
        ),
    ),
    Rule(
        name="retained-audio player keeps the shared 40pt hit floor",
        files=("Sources/UI/Settings/HomeMeetingAudioPlayer.swift",),
        banned=(),
        why="the player's hit shape must come from HomeHitTarget.hitSize so it never drops under 40pt",
        required=(
            "HomeHitTarget.hitSize(forVisibleSize: size)",
            ".frame(width: hitTargetSize, height: hitTargetSize)",
        ),
    ),
    Rule(
        name="Settings shell builds Home row menus from HomeRowMenuPolicy",
        folder="Sources/UI/Settings",
        prefix="TranscriptedSettingsView",
        min_files=5,
        banned=(),
        why="the row menus must come from HomeRowMenuPolicy, fed the row's real state",
        required=(
            "HomeRowMenuPolicy.dictationEntries",
            "HomeRowMenuPolicy.meetingEntries(",
            "hasAudioRevealTarget: !audioRevealURLs.isEmpty",
            "hasRetranscriptionInput: item.audio?.retranscriptionInput != nil",
            "hasPendingSpeakerReview: hasSpeakerReviewWork(for: item)",
            "title: RecentMeetingRetranscriptionMenuActionPolicy.title(",
        ),
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


def collapse_whitespace(text: str) -> str:
    return " ".join(text.split())


def check(root: Path, rules: tuple[Rule, ...] = RULES) -> list[str]:
    problems: list[str] = []
    for rule in rules:
        scanned: list[str] = []
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
            scanned.append(text)
            for needle in rule.banned:
                if needle in text:
                    problems.append(f"{rel}: calls `{needle}`: {rule.why}")
        if rule.required:
            combined = collapse_whitespace("\n".join(scanned))
            where = rule.folder or ", ".join(files)
            for needle in rule.required:
                if collapse_whitespace(needle) not in combined:
                    problems.append(f"{where}: lost `{needle}` ({rule.name})")
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
    for index in range(5):
        good[f"Sources/UI/Settings/TranscriptedSettingsView+Part{index}.swift"] = "status = Copy.failed\n"
    good["Sources/UI/Settings/TranscriptedSettingsView+Part0.swift"] += (
        "func settingsFailureDetailsButton(_ details: String?) -> some View { EmptyView() }\n"
    )
    good["Sources/UI/Settings/TranscriptedSettingsView+Part1.swift"] += (
        "if let details { settingsFailureDetailsButton(details) }\n"
        "modelCacheCleanupStatus =\n    SettingsActionFailureCopy.modelCacheRemoval\n"
        "modelCacheCleanupStatusDetails = error.localizedDescription\n"
        "launchAtLogin.statusDescription = SettingsActionFailureCopy.launchAtLogin\n"
        "captureLibraryMigrationStatus = SettingsActionFailureCopy.captureLibraryMigration(code)\n"
    )
    good["Sources/UI/Settings/PermissionsOnboardingView.swift"] = (
        ".onReceive(activePublisher) { _ in refresh() }\n"
        ".onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in\n"
        "    handleLifecycle(.appBecameActive)\n}\n"
        ".onReceive(NotificationCenter.default.publisher(for: .transcriptedPermissionsDidChange)) { _ in\n"
        "    handleLifecycle(.permissionsChanged)\n}\n"
        ".onDisappear {\n    handleLifecycle(.windowDisappeared)\n}\n"
        "if effects.contains(.cancelSystemAudioCheck) {\n    stopPermissionRevalidation()\n}\n"
        "private func stopPermissionRevalidation() {\n    systemAudioRequestTask?.cancel()\n}\n"
        "Policy.result(decision, checkWasCancelled: Task.isCancelled)\n"
        "Stage(actionTitle: systemAudioPresentation.actionTitle)\n"
    )
    good["Sources/UI/Settings/AgentConnectionSettingsPage.swift"] = (
        "phase = .failed(failure.message)\ndetails = error.localizedDescription\n"
        "let failure = AgentSetupFailureCopy.connectFailure(agentName: name, error: error)\n"
        "let inbox = AgentSetupFailureCopy.codexInboxFailure(error: error)\n"
        "failureNotice(id: \"transcripted.settings.agent.connect-error-details.\\(agent.rawValue)\")\n"
        "private func failureNotice(id: String) -> some View { EmptyView() }\n"
    )
    good["Sources/UI/Settings/HomeMeetingAudioPlayer.swift"] = (
        "private var hitTargetSize: CGFloat {\n    HomeHitTarget.hitSize(forVisibleSize: size)\n}\n"
        "Image(systemName: glyph)\n    .frame(width: hitTargetSize, height: hitTargetSize)\n"
    )
    good["Sources/UI/Settings/TranscriptedSettingsView+Part3.swift"] += (
        "HomeRowMenuPolicy.dictationEntries.compactMap { entry in item(entry) }\n"
        "let entries = HomeRowMenuPolicy.meetingEntries(\n"
        "    hasPendingSpeakerReview: hasSpeakerReviewWork(for: item),\n"
        "    hasAudioRevealTarget: !audioRevealURLs.isEmpty,\n"
        "    hasRetranscriptionInput: item.audio?.retranscriptionInput != nil\n)\n"
        "HomeRowMenuItem(\n    title: RecentMeetingRetranscriptionMenuActionPolicy.title(\n        reason: reason\n    )\n)\n"
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
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "refresh() }", "startPolling() }"),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "refresh() }", "while !Task.isCancelled { refresh() } }"),
        (
            "Sources/UI/Settings/PermissionsOnboardingView.swift",
            "refresh() }",
            "SystemAudioPermissionRevalidator.revalidateForStatusSurfaces() }",
        ),
        ("Sources/UI/Settings/AgentConnectionSettingsPage.swift", ".failed(failure.message)", ".failed(error.localizedDescription)"),
        ("Sources/UI/Settings/AgentConnectionSettingsPage.swift", ".failed(failure.message)", '.failed("Could not connect: \\(error)")'),
        ("Sources/UI/Settings/TranscriptedSettingsView+Part2.swift", "Copy.failed", '"Copy stopped: \\(error.localizedDescription)"'),
        # a raw error assigned straight to a status line, no interpolation
        (
            "Sources/UI/Settings/TranscriptedSettingsView+Part1.swift",
            "modelCacheCleanupStatus =\n    SettingsActionFailureCopy.modelCacheRemoval",
            "modelCacheCleanupStatus = error.localizedDescription",
        ),
        (
            "Sources/UI/Settings/TranscriptedSettingsView+Part1.swift",
            "launchAtLogin.statusDescription = SettingsActionFailureCopy.launchAtLogin",
            "launchAtLogin.statusDescription = error.localizedDescription",
        ),
        # required wiring removed
        ("Sources/UI/Settings/TranscriptedSettingsView+Part0.swift", "func settingsFailureDetailsButton(", "func detailsButton("),
        ("Sources/UI/Settings/TranscriptedSettingsView+Part1.swift", "{ settingsFailureDetailsButton(details) }", "{ EmptyView() }"),
        (
            "Sources/UI/Settings/TranscriptedSettingsView+Part1.swift",
            "SettingsActionFailureCopy.captureLibraryMigration(code)",
            "message",
        ),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "handleLifecycle(.appBecameActive)", "refresh()"),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "handleLifecycle(.permissionsChanged)", ""),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "handleLifecycle(.windowDisappeared)", ""),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "    stopPermissionRevalidation()\n", ""),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "    systemAudioRequestTask?.cancel()\n", ""),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "checkWasCancelled: Task.isCancelled", "checkWasCancelled: false"),
        ("Sources/UI/Settings/PermissionsOnboardingView.swift", "systemAudioPresentation.actionTitle", '"Grant"'),
        ("Sources/UI/Settings/AgentConnectionSettingsPage.swift", "private func failureNotice(", "private func notice("),
        ("Sources/UI/Settings/AgentConnectionSettingsPage.swift", "connect-error-details.", "details."),
        ("Sources/UI/Settings/AgentConnectionSettingsPage.swift", "AgentSetupFailureCopy.connectFailure(", "Copy.other("),
        ("Sources/UI/Settings/AgentConnectionSettingsPage.swift", "AgentSetupFailureCopy.codexInboxFailure(", "Copy.other("),
        # the retained-audio player drops its hit floor
        ("Sources/UI/Settings/HomeMeetingAudioPlayer.swift", "HomeHitTarget.hitSize(forVisibleSize: size)", "size"),
        ("Sources/UI/Settings/HomeMeetingAudioPlayer.swift", "width: hitTargetSize, height: hitTargetSize", "width: size, height: size"),
        # Home row menus stop coming from the policy, or stop feeding it real state
        ("Sources/UI/Settings/TranscriptedSettingsView+Part3.swift", "HomeRowMenuPolicy.dictationEntries", "[.openMarkdown]"),
        ("Sources/UI/Settings/TranscriptedSettingsView+Part3.swift", "HomeRowMenuPolicy.meetingEntries(", "fixedEntries("),
        ("Sources/UI/Settings/TranscriptedSettingsView+Part3.swift", "!audioRevealURLs.isEmpty", "true"),
        (
            "Sources/UI/Settings/TranscriptedSettingsView+Part3.swift",
            "item.audio?.retranscriptionInput != nil",
            "item.audio != nil",
        ),
        ("Sources/UI/Settings/TranscriptedSettingsView+Part3.swift", "hasSpeakerReviewWork(for: item)", "false"),
        (
            "Sources/UI/Settings/TranscriptedSettingsView+Part3.swift",
            "title: RecentMeetingRetranscriptionMenuActionPolicy.title(",
            'title: "Re-transcribe", reasonLabel: (',
        ),
    ]
    for rel, old, new in breaks:
        broken = dict(good)
        assert old in broken[rel], (rel, old)
        broken[rel] = broken[rel].replace(old, new)
        assert check(build(broken)), (rel, new)

    # A scan that finds too few engine files fails.
    sparse = {k: v for k, v in good.items() if "ParakeetPart" not in k}
    assert any("expected more than" in p for p in check(build(sparse)))
    # So does a Settings shell scan that loses its files.
    sparse = {k: v for k, v in good.items() if "TranscriptedSettingsView+" not in k}
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
