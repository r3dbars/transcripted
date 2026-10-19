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
    handler, leaving it cancels the in-flight audio check, and the check's
    typed probe result reaches the view.
  * The Agent page and the Settings shell never put a raw error into
    user-facing text; the raw error goes behind Copy Details. Both keep that
    Copy Details reveal and route failures through their shared failure copy.
  * The retained-audio player sizes its hit shape from
    HomeHitTarget.hitSize(forVisibleSize:), so it keeps the 40pt floor.
  * The Settings shell builds the Home row menus from HomeRowMenuPolicy and
    feeds it the row's real state (audio to reveal, taken from
    HomeMeetingRowActionTargets, a retranscription input,
    pending speaker review); re-transcribe takes its title from
    RecentMeetingRetranscriptionMenuActionPolicy.
    (these five were Tests/UIAutomationSurfaceContractTests.swift)
  * Settings opens the real window through the declarative ⌘, command, never a
    blank SwiftUI Settings scene plus a one-shot AppKit menu mutation.
  * The Settings shell (TranscriptedSettingsView.swift and every
    TranscriptedSettingsView+*.swift) never hands a scan-time URL straight to
    NSWorkspace, never stacks legacy `.alert(item:)` modifiers or hand-builds
    the failed-meeting delete NSAlert, has no failed-row "dismiss" path, never
    puts a raw error into a status line, and never saves Apple voice
    processing for every meeting from the Home Boost row.
  * Home copy-for-agent and meeting-preview telemetry go through
    HomeMeetingActionTelemetry, which owns the event order: the view never
    calls the Activation/ProductUsage trackers directly there, and it must
    still call HomeMeetingActionTelemetry so the events can't be silently
    disconnected.
    Every outcome keeps its own routed call (copy: missing file, read
    failure, resolved; preview: loaded and not loaded), so dropping one
    outcome's events fails.
  * Clearing a failed row reports its abandonment with
    HomeFailedMeetingCleanupTelemetry.reasonKind, not a hand-picked reason.
  * The fallback Settings view still closes itself before it opens the real
    window, through TranscriptedSettingsFallback.open(dismiss:openSettings:).
  * Menu commands still reach the app: TranscriptedMenuCommands and the
    fallback Settings scene route through TranscriptedMenuCommandCatalog, and
    the TranscriptedAppDelegate menu hops still call the real Settings window,
    dictation start, meeting toggle and audio import.
    The routing tests use a recording fake host, so they can't see these.
    (the last seven were Tests/UIAutomationSurfaceContractTests.swift)

A rule can also pin `required_counts`: text that must appear exactly that
many times in its files (or slice), so an extra call (say, a second
telemetry emit fired early) fails as surely as a dropped one. A slice whose
start or end anchor is gone fails too, instead of scanning the wrong text.

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
    # (text, count) pairs: the text must appear exactly `count` times in the
    # rule's files (or slices), whitespace collapsed like `required`.
    required_counts: tuple[tuple[str, int], ...] = ()


# TranscriptedSettingsView.swift plus its TranscriptedSettingsView+*.swift
# extensions. The core file alone isn't enough: a "must never" guard on it
# passes no matter what the extensions do.
SETTINGS_SHELL_FOLDER = "Sources/UI/Settings"
SETTINGS_SHELL_PREFIX = "TranscriptedSettingsView"
SETTINGS_SHELL_MIN_FILES = 5

# Direct tracker calls HomeMeetingActionTelemetry owns for the Home copy and
# preview flows. Calling one inline would double-count or reorder the events.
HOME_MEETING_DIRECT_TRACKERS = (
    "ActivationTelemetry.trackHabitLoopAction(",
    "ActivationTelemetry.trackArtifactAction(",
    "ActivationTelemetry.trackAgentPromptAction(",
    "ProductUsageTelemetry.trackResult(",
)
HOME_MEETING_TELEMETRY_WHY = (
    "Home copy/preview telemetry goes through HomeMeetingActionTelemetry, which owns the event order"
)


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
            "systemAudioProbeResult = result.probeResult",
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
            "let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)",
            "hasAudioRevealTarget: !audioRevealURLs.isEmpty",
            "hasRetranscriptionInput: item.audio?.retranscriptionInput != nil",
            "hasPendingSpeakerReview: hasSpeakerReviewWork(for: item)",
            "title: RecentMeetingRetranscriptionMenuActionPolicy.title(",
        ),
    ),
    Rule(
        name="Settings opens through the declarative command, not a blank scene",
        files=("Sources/App/TranscriptedApp.swift", "Sources/App/TranscriptedMenuCommands.swift"),
        banned=("Settings { EmptyView() }", "installSettingsMenuHandler(", "openSettingsFromAppMenu"),
        why="Settings must not depend on a blank scene plus a one-shot AppKit menu mutation",
    ),
    Rule(
        name="Home own-file actions never open a scan-time URL directly",
        folder=SETTINGS_SHELL_FOLDER,
        prefix=SETTINGS_SHELL_PREFIX,
        min_files=SETTINGS_SHELL_MIN_FILES,
        banned=(
            "activateFileViewerSelecting([entry.url])",
            "activateFileViewerSelecting(audioRevealURLs)",
            "activateFileViewerSelecting(\n" + " " * 20 + "HomeMeetingRowActionTargets.transcriptRevealURLs(for: item)",
            "NSWorkspace.shared.open(entry.url)",
            "NSWorkspace.shared.open(preview.transcriptURL)",
            "NSWorkspace.shared.open(item.transcriptURL)",
            "NSWorkspace.shared.open(notice.transcriptURL)",
            "NSWorkspace.shared.open(transcriptURL)",
        ),
        why="a file can move after scanning, so NSWorkspace on the raw URL is a silent no-op; route it through OwnFileResolver",
    ),
    Rule(
        name="Home alerts share one presenter",
        folder=SETTINGS_SHELL_FOLDER,
        prefix=SETTINGS_SHELL_PREFIX,
        min_files=SETTINGS_SHELL_MIN_FILES,
        banned=(
            ".alert(item: $homeDeleteConfirmation)",
            ".alert(item: $homeDeleteFailure)",
            "presentFailedMeetingDeleteConfirmation(",
        ),
        why="stacked legacy `.alert(item:)` modifiers shadow all but the last, and a hand-built NSAlert bypasses the shared rootAlertBinding",
    ),
    Rule(
        name="failed-row cleanup has one destructive path",
        folder=SETTINGS_SHELL_FOLDER,
        prefix=SETTINGS_SHELL_PREFIX,
        min_files=SETTINGS_SHELL_MIN_FILES,
        banned=("dismissFailedMeeting",),
        why="clearing a failed row deletes its audio, so it goes through requestClearFailedMeeting's confirmation, not a dismiss",
    ),
    Rule(
        name="Settings status lines never show a raw error",
        folder=SETTINGS_SHELL_FOLDER,
        prefix=SETTINGS_SHELL_PREFIX,
        min_files=SETTINGS_SHELL_MIN_FILES,
        banned=(
            "setup failed: \\(error.localizedDescription)",
            "Could not remove stale models: \\(error",
            "Could not update launch at login: \\(error",
            "Copy stopped: \\(error",
        ),
        why="status lines use SettingsActionFailureCopy; the raw error goes behind Copy Details",
    ),
    Rule(
        name="the Home Boost row never saves voice processing for every meeting",
        folder=SETTINGS_SHELL_FOLDER,
        prefix=SETTINGS_SHELL_PREFIX,
        min_files=SETTINGS_SHELL_MIN_FILES,
        banned=("MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true)",),
        why="the Home Boost row must not save Apple voice processing for every meeting",
    ),
    Rule(
        name="Home copy-for-agent telemetry routes through HomeMeetingActionTelemetry",
        files=("Sources/UI/Settings/TranscriptedSettingsView.swift",),
        slice=Slice(start="func handleCopyMeeting(", end="private func handleRetranscribeMeeting("),
        banned=HOME_MEETING_DIRECT_TRACKERS,
        # Exactly one emit per outcome, so dropping any outcome's events fails,
        # and so does an extra emit (say, a premature success before the await).
        required_counts=(
            ("HomeMeetingActionTelemetry.emit(", 3),
            ("HomeMeetingActionTelemetry.copyEvents(for: .missingFile)", 1),
            ("HomeMeetingActionTelemetry.copyEvents(for: .readFailure)", 1),
            ("HomeMeetingActionTelemetry.copyEvents(for: .resolved(", 1),
        ),
        why=HOME_MEETING_TELEMETRY_WHY,
    ),
    Rule(
        name="Home meeting-preview telemetry routes through HomeMeetingActionTelemetry",
        files=("Sources/UI/Settings/TranscriptedSettingsView.swift",),
        slice=Slice(start="func toggleHomeMeetingExpansion(", end="func collapseHomeMeetingExpansion("),
        banned=HOME_MEETING_DIRECT_TRACKERS,
        # Exactly one emit per outcome, so dropping either outcome's events
        # fails, and so does an extra emit before the read finishes.
        required_counts=(
            ("HomeMeetingActionTelemetry.emit(", 2),
            ("HomeMeetingActionTelemetry.previewEvents(loaded: true)", 1),
            ("HomeMeetingActionTelemetry.previewEvents(loaded: false)", 1),
        ),
        why=HOME_MEETING_TELEMETRY_WHY,
    ),
    Rule(
        name="failed-row cleanup reports the shared abandonment reason",
        files=("Sources/UI/Settings/TranscriptedSettingsView+HomeMeetingActions.swift",),
        banned=(),
        required=("reasonKind: HomeFailedMeetingCleanupTelemetry.reasonKind",),
        why="failed-row cleanup must report HomeFailedMeetingCleanupTelemetry.reasonKind, not a hand-picked reason like .dismissed",
    ),
    Rule(
        name="the fallback Settings view closes itself before opening the real window",
        files=("Sources/UI/Settings/TranscriptedSettingsFallbackView.swift",),
        banned=(),
        required=("TranscriptedSettingsFallback.open(dismiss:",),
        why="the fallback button must go through TranscriptedSettingsFallback.open(dismiss:openSettings:) so the blank scene closes first",
    ),
    Rule(
        name="menu commands route through TranscriptedMenuCommandCatalog",
        files=("Sources/App/TranscriptedMenuCommands.swift",),
        banned=(),
        required=("TranscriptedMenuCommandCatalog.perform(action, on: appDelegate)",),
        why="every menu item reaches the app delegate through TranscriptedMenuCommandCatalog.perform",
    ),
    Rule(
        name="the fallback Settings scene opens the real window through the catalog",
        files=("Sources/App/TranscriptedApp.swift",),
        banned=(),
        required=("TranscriptedMenuCommandCatalog.perform(.openSettings, on: appDelegate)",),
        why="the fallback Settings scene must open the real window through TranscriptedMenuCommandCatalog",
    ),
    Rule(
        name="app-delegate menu hops still reach the Settings window",
        files=("Sources/App/TranscriptedApp.swift",),
        slice=Slice(start="// MARK: - Menu Bar Commands", end="// MARK: - NSPopoverDelegate"),
        banned=(),
        required=(
            "showSettingsWindow(page: page, source: source)",
            "settingsWindowController.focusSpeakerSearch(source: source)",
            "settingsWindowController.focusHomeFind(source: source)",
            "startDictationFromSettings()",
            "meetingOverlayController.toggleFromHotkey()",
            "importAudioFileFromSettings()",
        ),
        why="the TranscriptedAppDelegate menu hops must call the real Settings window, dictation, meeting toggle and import (the routing tests only see a fake host)",
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
                if end == -1:
                    problems.append(f"{rel}: lost `{rule.slice.end}` after `{rule.slice.start}`, so `{rule.name}` can't be checked")
                    continue
                text = text[start:end]
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
        if rule.required_counts:
            combined = collapse_whitespace("\n".join(scanned))
            where = rule.folder or ", ".join(files)
            for needle, expected in rule.required_counts:
                found = combined.count(collapse_whitespace(needle))
                if found != expected:
                    problems.append(f"{where}: has {found} `{needle}`, expected exactly {expected} ({rule.name})")
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
        "func handleCopyMeeting(_ item: Item) {\n"
        "    HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.copyEvents(for: .missingFile), artifactDate: d)\n"
        "    HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.copyEvents(for: .readFailure), artifactDate: d)\n"
        "    HomeMeetingActionTelemetry.emit(\n"
        "        HomeMeetingActionTelemetry.copyEvents(for: .resolved(usedBundle: b, copied: c)), artifactDate: d)\n"
        "}\n"
        "private func handleRetranscribeMeeting(_ item: Item) {\n"
        "    ActivationTelemetry.trackArtifactAction(.retranscribe)\n"
        "}\n"
        "func toggleHomeMeetingExpansion(_ item: Item) {\n"
        "    HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.previewEvents(loaded: true), artifactDate: d)\n"
        "    HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.previewEvents(loaded: false), artifactDate: d)\n"
        "}\n"
        "func collapseHomeMeetingExpansion() {}\n"
        "func openRow() { ProductUsageTelemetry.trackResult(kind: .dictation) }\n"
    )
    good["Sources/UI/Settings/TranscriptedSettingsView+HomeMeetingActions.swift"] = (
        "ActivationTelemetry.trackWorkflowAbandoned(\n"
        "    reasonKind: HomeFailedMeetingCleanupTelemetry.reasonKind,\n"
        ")\n"
    )
    good["Sources/App/TranscriptedApp.swift"] = (
        "Settings { TranscriptedSettingsFallbackView { open() } }\n"
        "func open() { TranscriptedMenuCommandCatalog.perform(.openSettings, on: appDelegate) }\n"
        "// MARK: - Menu Bar Commands\n"
        "func openSettingsWindow(page: Page, source: String) {\n"
        "    showSettingsWindow(page: page, source: source)\n"
        "}\n"
        "func focusHomeFindFromMenu(source: String) {\n"
        "    settingsWindowController.focusHomeFind(source: source)\n"
        "}\n"
        "func focusSpeakerSearchFromMenu(source: String) {\n"
        "    settingsWindowController.focusSpeakerSearch(source: source)\n"
        "}\n"
        "func startDictationFromMenu() {\n"
        "    startDictationFromSettings()\n"
        "}\n"
        "func toggleMeetingRecordingFromMenu() {\n"
        "    meetingOverlayController.toggleFromHotkey()\n"
        "}\n"
        "func importAudioFromMenu() {\n"
        "    importAudioFileFromSettings()\n"
        "}\n"
        "// MARK: - NSPopoverDelegate\n"
        "func popoverDidClose() { settingsWindowController.focusHomeFind(source: source) }\n"
    )
    good["Sources/App/TranscriptedMenuCommands.swift"] = (
        "CommandGroup(replacing: .appSettings) { item }\n"
        "private func perform(_ action: Action) { TranscriptedMenuCommandCatalog.perform(action, on: appDelegate) }\n"
    )
    good["Sources/UI/Settings/TranscriptedSettingsFallbackView.swift"] = (
        "Button(title) { TranscriptedSettingsFallback.open(dismiss: { dismiss() }, openSettings: openSettings) }\n"
    )
    shell_part = "Sources/UI/Settings/TranscriptedSettingsView+Part{}.swift"
    for index in range(SETTINGS_SHELL_MIN_FILES):
        good[shell_part.format(index)] = (
            "status = Copy.failed\n"
            "revealOwnFile(candidateURLs: urls)\n"
            ".alert(item: rootAlertBinding)\n"
            "status = SettingsActionFailureCopy.launchAtLogin\n"
        )
    # Not part of the shell split: its raw NSWorkspace call is out of scope.
    good["Sources/UI/Settings/OtherSettingsPage.swift"] = "NSWorkspace.shared.open(item.transcriptURL)\n"
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
        "systemAudioProbeResult = result.probeResult\n"
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
        "let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)\n"
        "let entries = HomeRowMenuPolicy.meetingEntries(\n"
        "    hasPendingSpeakerReview: hasSpeakerReviewWork(for: item),\n"
        "    hasAudioRevealTarget: !audioRevealURLs.isEmpty,\n"
        "    hasRetranscriptionInput: item.audio?.retranscriptionInput != nil\n)\n"
        "HomeRowMenuItem(\n    title: RecentMeetingRetranscriptionMenuActionPolicy.title(\n        reason: reason\n    )\n)\n"
    )
    assert check(build(good)) == [], check(build(good))

    settings_view = "Sources/UI/Settings/TranscriptedSettingsView.swift"
    failed_actions = "Sources/UI/Settings/TranscriptedSettingsView+HomeMeetingActions.swift"
    copy_emit = "HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.copyEvents(for: .missingFile), artifactDate: d)"
    preview_emit = "HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.previewEvents(loaded: true), artifactDate: d)"
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
        # the typed probe result stops reaching the view
        (
            "Sources/UI/Settings/PermissionsOnboardingView.swift",
            "systemAudioProbeResult = result.probeResult",
            "systemAudioProbeResult = nil",
        ),
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
        # the reveal targets stop coming from the row's real audio
        (
            "Sources/UI/Settings/TranscriptedSettingsView+Part3.swift",
            "let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)",
            "let audioRevealURLs: [URL] = []",
        ),
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
        ("Sources/App/TranscriptedApp.swift", "TranscriptedSettingsFallbackView { open() }", "EmptyView()"),
        ("Sources/App/TranscriptedMenuCommands.swift", "{ item }", "{ installSettingsMenuHandler() }"),
        ("Sources/App/TranscriptedApp.swift", "{ open() }", "{ openSettingsFromAppMenu() }"),
        (shell_part.format(0), "revealOwnFile(candidateURLs: urls)", "NSWorkspace.shared.open(item.transcriptURL)"),
        (shell_part.format(1), "revealOwnFile(candidateURLs: urls)", "NSWorkspace.shared.activateFileViewerSelecting([entry.url])"),
        (
            shell_part.format(2),
            "revealOwnFile(candidateURLs: urls)",
            "activateFileViewerSelecting(\n" + " " * 20 + "HomeMeetingRowActionTargets.transcriptRevealURLs(for: item)",
        ),
        ("Sources/UI/Settings/TranscriptedSettingsView.swift", "{ open(url) }", "{ NSWorkspace.shared.open(transcriptURL) }"),
        (shell_part.format(3), ".alert(item: rootAlertBinding)", ".alert(item: $homeDeleteFailure)"),
        (shell_part.format(4), ".alert(item: rootAlertBinding)", ".alert(item: $homeDeleteConfirmation)"),
        (shell_part.format(0), ".alert(item: rootAlertBinding)", "presentFailedMeetingDeleteConfirmation(item)"),
        (shell_part.format(1), "revealOwnFile(candidateURLs: urls)", "dismissFailedMeeting(item)"),
        (shell_part.format(2), "SettingsActionFailureCopy.launchAtLogin", '"Could not update launch at login: \\(error)"'),
        (shell_part.format(3), "SettingsActionFailureCopy.launchAtLogin", '"Copy stopped: \\(error.localizedDescription)"'),
        (shell_part.format(4), "revealOwnFile(candidateURLs: urls)", "MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true)"),
        # Home copy/preview telemetry: direct tracker calls inside either slice
        # (added next to the routing call, so only the ban can catch them)
        (settings_view, copy_emit, copy_emit + "\n    ActivationTelemetry.trackHabitLoopAction(.copiedForAgent)"),
        (settings_view, copy_emit, copy_emit + "\n    ActivationTelemetry.trackArtifactAction(.copy)"),
        (settings_view, copy_emit, copy_emit + "\n    ActivationTelemetry.trackAgentPromptAction(.copy)"),
        (settings_view, copy_emit, copy_emit + "\n    ProductUsageTelemetry.trackResult(kind: .meeting)"),
        (settings_view, preview_emit, preview_emit + "\n    ActivationTelemetry.trackHabitLoopAction(.preview)"),
        (settings_view, preview_emit, preview_emit + "\n    ActivationTelemetry.trackArtifactAction(.preview)"),
        (settings_view, preview_emit, preview_emit + "\n    ActivationTelemetry.trackAgentPromptAction(.preview)"),
        (settings_view, preview_emit, preview_emit + "\n    ProductUsageTelemetry.trackResult(kind: .meeting)"),
        # ... and the routing call removed from either slice
        (settings_view, "HomeMeetingActionTelemetry.copyEvents(", "copyEvents("),
        (settings_view, "HomeMeetingActionTelemetry.previewEvents(", "previewEvents("),
        (settings_view, copy_emit, "trackCopy()"),
        (settings_view, preview_emit, "trackPreview()"),
        # ... and either slice anchor vanishing
        (settings_view, "func handleCopyMeeting(", "func copyMeeting("),
        (settings_view, "func toggleHomeMeetingExpansion(", "func toggleExpansion("),
        # ... and any one outcome's routed events dropped
        (settings_view, copy_emit + "\n", ""),
        (settings_view, "HomeMeetingActionTelemetry.copyEvents(for: .readFailure), artifactDate: d)\n", "noop()\n"),
        (
            settings_view,
            "HomeMeetingActionTelemetry.copyEvents(for: .resolved(usedBundle: b, copied: c)), artifactDate: d)",
            "noop())",
        ),
        (settings_view, preview_emit + "\n", ""),
        (settings_view, "HomeMeetingActionTelemetry.previewEvents(loaded: false), artifactDate: d)", "noop())"),
        # the fallback view opening Settings without closing itself first
        (
            "Sources/UI/Settings/TranscriptedSettingsFallbackView.swift",
            "TranscriptedSettingsFallback.open(dismiss: { dismiss() }, openSettings: openSettings)",
            "openSettings()",
        ),
        # menu commands or the fallback scene no longer routing through the catalog
        ("Sources/App/TranscriptedMenuCommands.swift", "TranscriptedMenuCommandCatalog.perform(action, on: appDelegate)", ""),
        ("Sources/App/TranscriptedApp.swift", "TranscriptedMenuCommandCatalog.perform(.openSettings, on: appDelegate)", ""),
        # app-delegate menu hops emptied (a copy after the slice doesn't count)
        ("Sources/App/TranscriptedApp.swift", "showSettingsWindow(page: page, source: source)", "_ = (page, source)"),
        ("Sources/App/TranscriptedApp.swift", "    settingsWindowController.focusHomeFind(source: source)\n", "    _ = source\n"),
        ("Sources/App/TranscriptedApp.swift", "settingsWindowController.focusSpeakerSearch(source: source)", "_ = source"),
        ("Sources/App/TranscriptedApp.swift", "    startDictationFromSettings()\n", "    NSSound.beep()\n"),
        ("Sources/App/TranscriptedApp.swift", "    meetingOverlayController.toggleFromHotkey()\n", "    NSSound.beep()\n"),
        ("Sources/App/TranscriptedApp.swift", "    importAudioFileFromSettings()\n", "    NSSound.beep()\n"),
        # ... and the Menu Bar Commands section anchor vanishing
        ("Sources/App/TranscriptedApp.swift", "// MARK: - Menu Bar Commands", "// MARK: - Commands"),
        # failed-row cleanup reporting a hand-picked reason
        (
            failed_actions,
            "reasonKind: HomeFailedMeetingCleanupTelemetry.reasonKind",
            "reasonKind: .dismissed",
        ),
        # an extra emit in either slice (say, a premature success before the
        # await) fails the exact counts even though every outcome is still there
        (settings_view, copy_emit, copy_emit + "\n    " + copy_emit),
        (
            settings_view,
            copy_emit,
            "HomeMeetingActionTelemetry.emit(\n"
            "        HomeMeetingActionTelemetry.copyEvents(for: .resolved(usedBundle: b, copied: true)), artifactDate: d)\n    "
            + copy_emit,
        ),
        (settings_view, preview_emit, preview_emit + "\n    " + preview_emit),
        (
            settings_view,
            "HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.previewEvents(loaded: false), artifactDate: d)",
            "HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.previewEvents(loaded: false), artifactDate: d)\n"
            "    HomeMeetingActionTelemetry.emit(HomeMeetingActionTelemetry.previewEvents(loaded: false), artifactDate: d)",
        ),
        # a slice end anchor vanishing fails instead of scanning to end of file
        (settings_view, "private func handleRetranscribeMeeting(", "private func retranscribeMeeting("),
        (settings_view, "func collapseHomeMeetingExpansion(", "func collapseExpansion("),
        ("Sources/App/TranscriptedApp.swift", "// MARK: - NSPopoverDelegate", "// MARK: - Popover"),
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
    # So does a Settings shell scan that loses its extensions.
    shell_only = {k: v for k, v in good.items() if "TranscriptedSettingsView+" not in k}
    assert any("TranscriptedSettingsView*.swift" in p for p in check(build(shell_only)))
    # A missing end anchor is reported as such.
    no_end = dict(good)
    no_end[settings_view] = no_end[settings_view].replace("func collapseHomeMeetingExpansion(", "func collapse(")
    assert any("lost `func collapseHomeMeetingExpansion(`" in p for p in check(build(no_end))), check(build(no_end))
    # A duplicated emit is reported as a count mismatch.
    doubled = dict(good)
    doubled[settings_view] = doubled[settings_view].replace(preview_emit, preview_emit + "\n    " + preview_emit)
    assert any("expected exactly 2" in p for p in check(build(doubled))), check(build(doubled))
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
