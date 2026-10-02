// Repo-structure / contract suite, not behavioral coverage.
// What's left here reads Swift files as text, for one of three reasons:
//   - the code lives in TranscriptedApp.swift, the TranscriptedSettingsView
//     split, the SpeakerPeople split, or HomeView.swift, which need seams of
//     their own next;
//   - the code is the meeting overlay controller, whose island path still
//     needs a seam;
//   - it's a contract with a script or another package (the QA CLI and bench,
//     and the identifiers the QA smokes press).
// The menu bar rows, app commands, onboarding footer, launch-smoke and QA-smoke
// identifiers, and failure copy are behavior tests in
// AutomationSurfaceBehaviorTests.swift now.
//
// Adding a new contract guard is purely additive: call `contractSource("Sources/.../X.swift")`
// inline inside an assertion. Do NOT reintroduce a top-of-suite block of
// `let xSource = readSourceFixture(...)` declarations — that append-only
// hotspot is what made two concurrent UI PRs collide on a duplicate `let` declaration
// (the same pattern that bit AnalyticsEventPolicy.swift). `contractSource` reads and
// memoizes each file on demand, so repeated reads of the same path are free and two
// PRs can add guards for the same file without redeclaring anything.

import Foundation

// On-demand, memoized source reader. Each path is read at most once per run.
private var uiAutomationContractSourceCache: [String: String] = [:]

private func contractSource(_ relativePath: String) -> String {
    if let cached = uiAutomationContractSourceCache[relativePath] {
        return cached
    }
    let contents = readSourceFixture(relativePath)
    uiAutomationContractSourceCache[relativePath] = contents
    return contents
}

// Quiet-library redesign (2026-08): the dashboard/sheet-era HomeMeetingPreviewSheet.swift
// was deleted; Home's meeting row/expansion and the dictations list now live in
// QuietHomeLibrary.swift / QuietDictationLibrary.swift, and the meeting audio
// player split into HomeMeetingAudioPlayer.swift.
private func homeSurfaceContractContains(_ needle: String) -> Bool {
    contractSource("Sources/UI/Settings/HomeView.swift").contains(needle)
        || contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains(needle)
        || contractSource("Sources/UI/Settings/QuietDictationLibrary.swift").contains(needle)
        || contractSource("Sources/UI/Settings/HomeMeetingAudioPlayer.swift").contains(needle)
}

// Some Settings types are split across files: TranscriptedSettingsView.swift
// plus its TranscriptedSettingsView+*.swift extensions, and the Speakers
// section plus SpeakerPeopleRows.swift and its view-model files. A guard on
// one of them reads every Sources/UI/Settings file whose name starts with the
// prefix, so it follows code that moves between those files. That matters most
// for "must never contain" guards: one that reads only the core file passes no
// matter what the extensions do.
private var settingsSplitSourceCache: [String: String] = [:]

private func settingsSplitSource(prefix: String) -> String {
    if let cached = settingsSplitSourceCache[prefix] {
        return cached
    }
    let directory = "Sources/UI/Settings"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: repoFixtureURL(directory).path)) ?? [])
        .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".swift") }
        .sorted()
    let joined = names.map { contractSource("\(directory)/\($0)") }.joined(separator: "\n")
    settingsSplitSourceCache[prefix] = joined
    return joined
}

// TranscriptedSettingsView.swift and every TranscriptedSettingsView+*.swift.
private func settingsShellSource() -> String {
    settingsSplitSource(prefix: "TranscriptedSettingsView")
}

// SpeakerPeopleSettingsSection.swift, SpeakerPeopleRows.swift and the
// SpeakerPeopleSettingsViewModel files.
private func speakersSettingsSource() -> String {
    settingsSplitSource(prefix: "SpeakerPeople")
}

private func settingsSurfaceContractContains(_ needle: String) -> Bool {
    settingsShellSource().contains(needle) || [
        "Sources/UI/Settings/Pages/GeneralSettingsPage.swift",
        "Sources/UI/Settings/Pages/StorageSettingsPage.swift",
        "Sources/UI/Settings/Pages/AboutSettingsPage.swift",
        "Sources/UI/Settings/Pages/HomeSettingsPage.swift",
    ].contains { contractSource($0).contains(needle) }
}

func testUIAutomationSurfaceContract() {
    // Guards that read TranscriptedSettingsView.swift alone before the shell was
    // split into TranscriptedSettingsView+*.swift extensions. They now read the
    // whole split, so they hold wherever the code lives.
    runSuite("Settings shell guards cover every TranscriptedSettingsView file") {
        // The split readers must find the files, or every "must never" guard
        // below passes on empty text.
        assertTrue(
            settingsShellSource().contains("struct TranscriptedSettingsView: View")
                && settingsShellSource().contains("extension TranscriptedSettingsView"),
            "the Settings shell reader should load the core file and its extensions"
        )
        assertTrue(
            speakersSettingsSource().contains("struct SpeakerPeopleSettingsSection")
                && speakersSettingsSource().contains("SpeakerQuietPlayButton("),
            "the Speakers reader should load the section and its row views"
        )

        assertTrue(
            settingsShellSource().contains("func revealOwnFile(")
                && settingsShellSource().contains("OwnFileResolver.resolveForReveal(candidateURLs:")
                && settingsShellSource().contains("func openOwnFile(")
                && settingsShellSource().contains("OwnFileResolver.resolveExistingFile(candidateURLs:"),
            "Home reveal/open should route through OwnFileResolver helpers, surfacing a failure instead of a dead click"
        )

        assertFalse(
            settingsShellSource().contains("MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true)"),
            "The Home Boost row must not save Apple voice processing for every meeting"
        )

        assertTrue(
            settingsShellSource().contains("requestClearFailedMeeting")
                && settingsShellSource().contains("HomeDeleteConfirmationPolicy.failedMeeting")
                && settingsShellSource().contains("reasonKind: .deleted"),
            "Home should confirm and report every failed-row cleanup as deletion, not dismissal"
        )
        assertFalse(
            settingsShellSource().contains("dismissFailedMeeting"),
            "failed-row cleanup should have one canonical destructive seam"
        )

        // The one Microphone picker shows only while the Mac mic recorder is on.
        assertTrue(
            settingsShellSource().contains("if pinnedMicrophoneRecorderOn {\n            VStack(alignment: .leading, spacing: 0) {\n                generalMicrophoneChoiceEditor"),
            "the one picker shows while the recorder is on"
        )
        assertTrue(
            settingsShellSource().contains("if meetingMicProcessingMode.usesAppleVoiceProcessing {\n                    Divider()\n                    generalFasterBluetoothDictationToggle"),
            "voice-processing users keep the toggle that still protects their dictation"
        )
        assertTrue(
            settingsShellSource().contains("        } else {\n            generalFasterBluetoothDictationEditor\n        }"),
            "the old Bluetooth dictation rows stay while the recorder is off"
        )
        assertTrue(
            settingsShellSource().contains("if !pinnedMicrophoneRecorderOn {\n                        MeetingMicrophoneSettingRow("),
            "the meetings-only macOS-input toggle is folded into the one picker while the recorder is on"
        )
        assertTrue(
            settingsShellSource().contains("Text(\"Same as macOS Sound settings\").tag(MicrophoneChoice.macOSInput)"),
            "the picker keeps a way to record the AirPods mic on purpose"
        )
    }

    runSuite("Acknowledged unverified system audio stays visible in the recording pill") {
        assertTrue(contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("systemAudioUnverified: systemAudioDegradationWarning?.cause == .unverified"),
            "The recording pill must receive recording-scoped uncertainty")
        assertTrue(contractSource("Sources/Meeting/MeetingSessionController.swift").contains("let signalVerified = capture.hasObservedSystemAudioSignal"),
            "The warning must resolve from this capture's PCM evidence, not a cached permission")
        assertTrue(contractSource("Sources/Meeting/MeetingSessionController.swift").contains("let systemAudioFinalizationFailed = capture.systemAudioFinalizationFailed"),
            "Saved health must include failures discovered while draining the tail")
    }
    runSuite("Confirmed system-audio denial offers a grant action") {
        let controller = contractSource("Sources/UI/Overlay/MeetingOverlayController.swift")
        let session = contractSource("Sources/Meeting/MeetingSessionController.swift")
        assertTrue(session.contains("systemAudioPermissionRecoveryNeeded: MeetingRecordingStartGate.shouldOfferSystemAudioPermissionRecovery("),
            "the recovery action should come from typed permission evidence")
        assertTrue(controller.contains("meetingSession?.systemAudioPermissionRecoveryNeeded == true"),
            "the overlay should render the action only for a typed denial")
    }
    runSuite("UI automation surface contract - every identifier the QA smokes press exists in the app") {
        // A cross-package contract: the QA CLI and the launch smoke press
        // these identifiers, so the app must declare each one somewhere. It
        // checks existence, not which file, so splits and moves don't break
        // it. The ones compiled into this runner are behavior-tested in
        // AutomationSurfaceBehaviorTests.swift.
        let pressed = qaSmokePressedIdentifiers()
        assertTrue(pressed.count >= 20, "the QA smokes should still drive the menu bar, sidebar, onboarding and import controls")
        var declared = Set<String>()
        let root = repoFixtureURL("Sources/")
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                declared.formUnion(automationIdentifierLiterals(in: text))
            }
        }
        declared.formUnion(TranscriptedSettingsPage.allCases.map(\.automationIdentifier))
        for identifier in pressed.sorted() {
            assertTrue(declared.contains(identifier), "\(identifier) is pressed by the QA smokes but the app never declares it")
        }
    }

    runSuite("UI automation surface contract - menubar controls expose stable identifiers") {
        assertTrue(
            contractSource("Sources/TranscriptedApp.swift").contains("transcripted.status-item.button")
                && contractSource("Sources/TranscriptedApp.swift").contains("setAccessibilityIdentifier(\"transcripted.status-item.button\")"),
            "the real menu bar status item should expose a stable AX identifier for external UI automation"
        )
    }

    runSuite("UI automation surface contract - native Settings routes to the real window") {
        let appSource = contractSource("Sources/TranscriptedApp.swift")
        assertTrue(
            appSource.contains("func menuOpenSettings()")
                && appSource.contains("showSettingsWindow(page: .general, source: \"app_menu\")"),
            "the declarative app Settings command should open the owned General settings page"
        )
        assertTrue(
            appSource.contains("TranscriptedSettingsFallbackView")
                && appSource.contains("transcripted.settings.fallback.open")
                && appSource.contains("@Environment(\\.dismiss)")
                && appSource.contains("dismiss()"),
            "direct SwiftUI Settings-scene opens should provide a visible recovery action and close before opening the owned window"
        )
        assertFalse(
            appSource.contains("Settings { EmptyView() }")
                || appSource.contains("installSettingsMenuHandler()")
                || appSource.contains("openSettingsFromAppMenu"),
            "Settings must not depend on a blank scene plus a one-shot AppKit menu mutation"
        )
    }

    runSuite("UI automation surface contract - app commands route through existing delegate entry points") {
        for requiredAppHook in [
            "TranscriptedMenuCommands(appDelegate: appDelegate)",
            "func menuStartDictation()",
            "startDictationFromSettings()",
            "func menuToggleMeetingRecording()",
            "meetingOverlayController.toggleFromHotkey()",
            "func menuImportAudio()",
            "importAudioFileFromSettings()",
            "func menuOpenPage(_ page: TranscriptedSettingsPage)",
            "showSettingsWindow(page: page, source: \"menu_command\")",
            "func menuFindSpeaker()",
            "settingsWindowController.focusSpeakerSearch(source: \"menu_command\")",
        ] {
            assertTrue(contractSource("Sources/TranscriptedApp.swift").contains(requiredAppHook), "\(requiredAppHook) should keep app commands wired through existing app-delegate actions")
        }
    }

    runSuite("UI automation surface contract - major settings and Home flows stay mapped") {
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsSidebar.swift").contains(".accessibilityIdentifier(page.automationIdentifier)"),
            "settings sidebar rows should expose each page's automation identifier"
        )

        for requiredSourceHook in [
            "actions.importAudioFile()",
            "trackSettingsAction(\"empty_import_audio\", page: .home)",
        ] {
            assertTrue(settingsSurfaceContractContains(requiredSourceHook), "\(requiredSourceHook) should stay source-addressable")
        }

        for requiredHomeActionHook in [
            "HomeRowMenuItem(title: \"Open Markdown\"",
            "HomeRowMenuItem(title: \"Report issue\"",
            "HomeRowMenuItem(title: \"Delete meeting\"",
            "HomeDeleteConfirmationPolicy.failedMeeting",
            "homeDeleteConfirmation = HomeDeleteConfirmation(",
        ] {
            assertTrue(settingsShellSource().contains(requiredHomeActionHook), "\(requiredHomeActionHook) should keep Home action coverage visible")
        }
        assertFalse(
            settingsShellSource().contains("presentFailedMeetingDeleteConfirmation("),
            "failed-meeting delete confirmation should use SwiftUI alert state instead of a hand-built NSAlert"
        )

        for requiredHomeRendererHook in [
            "symbolName: \"trash\"",
            "SettingsInlineActionButton(",
            "HomeRowMoreMenuButton(items:",
            "retainedActionTarget = context.coordinator",
            "final class ClosureMenuItem: NSMenuItem",
            "ClosureMenuItem(menuItem: item)",
        ] {
            assertTrue(homeSurfaceContractContains(requiredHomeRendererHook), "\(requiredHomeRendererHook) should keep Home action rendering visible")
        }
        assertTrue(
            homeSurfaceContractContains("enum HomeHitTarget")
                && homeSurfaceContractContains("static let minimum: CGFloat = 40")
                && homeSurfaceContractContains("HomeHitTarget.minimum"),
            "Home icon buttons and compact row actions should keep a shared 40pt hit-target floor"
        )
        // Quiet-library redesign: the retained-audio player is
        // HomeMeetingPodcastPlayer (HomeMeetingAudioPlayer.swift), whose
        // transport buttons size their hit target off HomeHitTarget.minimum.
        assertTrue(
            contractSource("Sources/UI/Settings/HomeMeetingAudioPlayer.swift").contains("max(size, HomeHitTarget.minimum)")
                && contractSource("Sources/UI/Settings/HomeMeetingAudioPlayer.swift").contains("hitTargetSize"),
            "Home retained-audio play controls should keep a 40pt hit floor"
        )
        assertFalse(
            contractSource("Sources/UI/Settings/HomeView.swift").contains("representedObject = item.id"),
            "Home row menus should not depend on unstable SwiftUI-generated menu item IDs"
        )

        // Regression guards for fix/home-delete-confirmation-menu-loop. The Home
        // recent-meeting "Delete meeting" confirmation silently no-op'd because of
        // two stacked defects the fast suite cannot exercise at runtime:
        //   1. Row-menu handlers fired synchronously inside NSMenu.popUp's modal
        //      tracking loop, so the SwiftUI alert they set never presented.
        //      ClosureMenuItem must hop to the next main-runloop turn.
        //   2. Multiple legacy `.alert(item:)` modifiers were stacked on the
        //      settings root view; SwiftUI keeps only the last, shadowing the
        //      delete confirmation. Home's two states must share one presenter.
        assertTrue(
            contractSource("Sources/UI/Settings/HomeView.swift").contains("DispatchQueue.main.async { [handler] in handler() }"),
            "ClosureMenuItem should defer its handler off the NSMenu.popUp tracking loop so menu-triggered SwiftUI alerts/sheets present"
        )
        assertTrue(
            settingsShellSource().contains(".alert(item: rootAlertBinding)"),
            "the Home delete and delete-failure alerts should present through one rootAlertBinding so neither is shadowed"
        )
        assertFalse(
            settingsShellSource().contains(".alert(item: $homeDeleteConfirmation)")
                || settingsShellSource().contains(".alert(item: $homeDeleteFailure)"),
            "Home alerts must not be re-stacked as separate `.alert(item:)` modifiers — stacked legacy alerts shadow all but the last"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/Pages/StorageSettingsPage.swift").contains(".alert(item: $pendingAudioRetentionWindow)"),
            "audio-retention confirmation should stay on the Storage page that owns the picker"
        )
        // The shared binding must dismiss only the active alert via
        // HomeRootAlertPolicy, never clear both. HomeRootAlertPolicyTests
        // covers the priority/dismissal behavior directly.

        let settingsSource = contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift")
        // Quiet-library redesign: the meeting preview sheet's separate
        // handleCopyMeetingPreview() dissolved — QuietMeetingRow and
        // QuietMeetingExpansion both now call the single handleCopyMeeting(),
        // so handleRetranscribeMeeting() is the next function boundary.
        let copyMeetingBlock = sourceBlock(
            named: "func handleCopyMeeting(_ item: RecentMeetingItem)",
            endingBefore: "    private func handleRetranscribeMeeting(",
            in: settingsSource
        )
        assertFalse(
            copyMeetingBlock.contains(
                "trackSettingsAction(\"copy_meeting\", page: .home)\n        ActivationTelemetry.trackHabitLoopAction"
            ),
            "copy-for-agent telemetry must not emit habit-loop success before the transcript resolves"
        )
        assertEqual(
            countOccurrences(of: "ActivationTelemetry.trackHabitLoopAction(", in: copyMeetingBlock),
            3,
            "copy-for-agent should track habit-loop exactly on missing-file failure, read failure, or success"
        )

        // The old presentHomeMeetingPreview() sheet-load path is now
        // toggleHomeMeetingExpansion(), which opens the row's inline
        // expansion and loads its Markdown asynchronously.
        let previewBlock = sourceBlock(
            named: "func toggleHomeMeetingExpansion(_ item: RecentMeetingItem)",
            endingBefore: "    func collapseHomeMeetingExpansion(",
            in: settingsSource
        )
        assertFalse(
            previewBlock.contains(
                "trackSettingsAction(\"preview_recent_meeting\", page: .home)\n        ActivationTelemetry.trackArtifactAction"
            )
                || previewBlock.contains(
                    "trackSettingsAction(\"preview_recent_meeting\", page: .home)\n        ActivationTelemetry.trackHabitLoopAction"
                ),
            "meeting preview telemetry must wait for the async Markdown read to succeed or fail"
        )
        assertEqual(
            countOccurrences(of: "ActivationTelemetry.trackHabitLoopAction(", in: previewBlock),
            2,
            "meeting preview should track habit-loop once in the success branch and once in the failure branch"
        )

        // No control may pass a possibly-stale row/preview/notice URL straight to
        // NSWorkspace — those silently no-op when the file moved after scanning.
        for staleRawCall in [
            "activateFileViewerSelecting([entry.url])",
            "activateFileViewerSelecting(audioRevealURLs)",
            "activateFileViewerSelecting(\n                    HomeMeetingRowActionTargets.transcriptRevealURLs(for: item)",
            "NSWorkspace.shared.open(entry.url)",
            "NSWorkspace.shared.open(preview.transcriptURL)",
            "NSWorkspace.shared.open(item.transcriptURL)",
            "NSWorkspace.shared.open(notice.transcriptURL)",
            "NSWorkspace.shared.open(transcriptURL)",
        ] {
            assertFalse(
                settingsShellSource().contains(staleRawCall),
                "Home own-file action must not call NSWorkspace on a raw scan-time URL (\(staleRawCall)) — route it through OwnFileResolver"
            )
        }

        // Copy/export and re-transcribe must surface a failure, not a silent beep,
        // when the source file cannot be resolved.
        assertTrue(
            settingsShellSource().contains("Could not copy meeting")
                && settingsShellSource().contains("Could not re-transcribe meeting"),
            "copy-for-agent and re-transcribe should surface a failure alert when the own file is missing, instead of NSSound.beep()"
        )

        // Row-interaction affordances, which have no behavioral coverage in the
        // fast suite (it greps source, never runs the UI). The overflow actions
        // only reveal on hover, so every capture row needs a full-width hit
        // shape (its idle background is Color.clear).
        for rowFile in [
            "Sources/UI/Settings/QuietHomeLibrary.swift",
            "Sources/UI/Settings/QuietDictationLibrary.swift",
            "Sources/UI/Settings/HomeView.swift",
        ] {
            assertTrue(
                contractSource(rowFile).contains(".contentShape(Rectangle())"),
                "capture rows in \(rowFile) should keep a full-width .contentShape(Rectangle()) so hover reveals row actions everywhere, not only over the title text"
            )
        }

        assertTrue(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("NSApplication.didBecomeActiveNotification")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcriptedPermissionsDidChange"),
            "onboarding should refresh permission state from bounded lifecycle events"
        )
        assertFalse(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("while !Task.isCancelled")
                || contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("startPolling()"),
            "an idle onboarding window must never run an infinite ScreenCaptureKit permission-probe loop"
        )
        let onboardingSource = contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift")
        assertFalse(onboardingSource.contains("SystemAudioPermissionRevalidator.revalidateForStatusSurfaces"), "window activation must not compete with an explicit onboarding audio check")
        assertTrue(onboardingSource.contains("systemAudioRequestTask?.cancel()") && onboardingSource.contains("guard !Task.isCancelled else { return }"), "leaving onboarding must cancel the audio check and ignore its late result")
        assertTrue(onboardingSource.contains("decision.probeResult") && onboardingSource.contains("systemAudioPresentation.actionTitle"), "onboarding must render the typed audio check result instead of collapsing unknown into Grant")

        assertTrue(
            contractSource("Sources/UI/Settings/SpeakerNameAutocompleteField.swift").contains("selectedOptionID?.wrappedValue = selectedOption?.id")
                && contractSource("Sources/UI/Settings/SpeakerNameAutocompleteField.swift").contains("selectedOptionID?.wrappedValue = nil"),
            "meeting speaker autocomplete must preserve the selected saved-person UUID and clear it on typing"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsWindowController.swift").contains("transcriptDirectory: MeetingStoragePaths.transcriptsFolder"),
            "saved-person rename/merge must scan the active capture library, including relocated libraries"
        )
        // Batch speaker naming order (saved identities first, local links
        // remapped to surviving profiles) is covered by
        // HomeMeetingPreviewFormatterTests through HomeMeetingSpeakerNamingPolicy.

        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("Discard Recording…"),
            "the island's meeting right-click menu should keep a stable Discard title for automation"
        )

    }

    runSuite("UI automation surface contract - deterministic click-flow identifiers stay mapped") {
        for identifier in [
            "transcripted.settings.footer.check-updates",
            "transcripted.settings.general.launch-at-login",
            "transcripted.settings.general.show-in-dock",
            "transcripted.settings.general.dictation-sounds",
            "transcripted.settings.general.cleanup-pasted-text",
            "transcripted.settings.section.dictation",
            "transcripted.settings.section.bluetooth-microphone",
            "transcripted.settings.section.send-after-dictation",
            "transcripted.settings.section.meetings",
            "transcripted.settings.section.speakers",
            "transcripted.settings.section.transcription",
            "transcripted.settings.section.app",
            "transcripted.settings.section.permissions",
            "transcripted.settings.section.privacy",
            "transcripted.settings.general.keyboard-shortcuts",
            "transcripted.settings.general.bluetooth-dictation",
            "transcripted.settings.general.microphone",
            "transcripted.settings.general.auto-send",
            "transcripted.settings.general.model",
            "transcripted.settings.general.corrections",
            "transcripted.settings.general.people-in-room",
            "transcripted.settings.general.call-matching",
            "transcripted.settings.general.crash-reports",
            "transcripted.settings.general.usage-stats",
            "transcripted.settings.storage.capture-library",
            "transcripted.settings.storage.delete-audio",
            "transcripted.settings.storage.free-up-space",
            "transcripted.settings.storage.support-files",
            "transcripted.settings.about.automatic-updates",
            "transcripted.settings.about.support",
            "transcripted.settings.general.corrections.clear-all",
        ] {
            assertTrue(settingsSurfaceContractContains(identifier), "\(identifier) should stay attached to Settings click-flow controls")
        }

        assertTrue(
            contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("transcripted.speakers.inbox")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains(".id(ScrollTarget.reviewQueue)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("proxy.scrollTo(SpeakerPeopleSettingsSection.ScrollTarget.reviewQueue"),
            "The voices-to-name section should keep a stable automation anchor that review deep-links can scroll to"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("enum SpeakerPeopleSettingsPolishContract")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("struct SpeakerCompactIconLabel")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("struct SpeakerQuietPlayButton")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("static let minimumHitTarget: CGFloat = 40")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("static let quietPlayGlyphPointSize: CGFloat = 14")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("static let compactIconVisibleDiameter: CGFloat = 28")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains(".contentShape(Rectangle())"),
            "speaker settings should pin quiet play/icon chrome separately from the 40pt hit shape"
        )

        // The play control is a bare glyph (SpeakerQuietPlayButton) used by
        // the queue row, the person row and the person card's player; the
        // compact icon label backs the two overflow menus.
        assertTrue(
            speakersSettingsSource().components(separatedBy: "SpeakerQuietPlayButton(").count - 1 >= 3,
            "queue, person-row, and person-card play controls should all use the quiet 40pt hit-target play button"
        )
        assertTrue(
            speakersSettingsSource().components(separatedBy: "SpeakerCompactIconLabel(").count - 1 >= 2,
            "queue and person overflow menus should use the compact 40pt hit-target label"
        )

        assertFalse(
            speakersSettingsSource().contains("transcripted.speakers.refresh"),
            "the speakers surface should not regrow a manual refresh button — navigation and mutations refresh the model"
        )

        for identifier in [
            "transcripted.speakers.voice-to-name.play",
            "transcripted.speakers.voice-to-name.menu",
            "transcripted.speakers.search.field",
            "transcripted.speakers.person.play",
            "transcripted.speakers.person.menu",
        ] {
            assertTrue(
                speakersSettingsSource().contains(identifier),
                "\(identifier) should keep the speakers surface's icon-only controls scriptable without using speaker names"
            )
        }

        assertTrue(
            settingsShellSource().contains("HomeRowMenuItem(title: \"Review speakers\"")
                && settingsShellSource().contains("let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)")
                && settingsShellSource().contains("if !audioRevealURLs.isEmpty")
                && settingsShellSource().contains("title: RecentMeetingRetranscriptionMenuActionPolicy.title("),
            "meeting speaker review and re-transcribe actions should stay reachable from the row menu when retained audio has a Finder target"
        )

    }

    runSuite("UI automation surface contract - QA CLI exposes a real AX smoke") {
        assertTrue(
            contractSource("Tools/TranscriptedQA/Sources/TranscriptedQA/TranscriptedQA.swift").contains("UISmoke.self")
                && contractSource("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/UISmoke.swift").contains("commandName: \"ui-smoke\""),
            "TranscriptedQA should expose a ui-smoke command for repo-owned UI automation"
        )

        for requiredHarnessHook in [
            "AXIsProcessTrustedWithOptions",
            "UIAutomationSmokeStatus",
            "case incomplete = \"INCOMPLETE\"",
            "exitCode = 3",
            "observability-anonymous-analytics-enabled",
            "observability-crash-reporting-enabled",
            "TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT",
            "Existing Transcripted processes were explicitly allowed",
            "runOnboardingSmoke",
            "onboarding-isolated-home",
            "onboardingAppLogPath",
            "appInspector",
            "systemUIServerStatusItem",
            "selectRow(identifier:",
            "kAXSelectedAttribute",
            "performPress(identifier:",
            "performPressOrClick(identifier:",
            "CGEvent(mouseEventSource:",
            "AXChildrenInNavigationOrder",
            "transcripted.status-item.button",
            "transcripted.menubar.utility.open-transcripted",
            "transcripted.home.find.toggle",
            "transcripted.settings.page.storage",
            "transcripted.settings.sidebar.settings-toggle",
            "transcripted.settings.sidebar.dictations",
            "transcripted.onboarding.permissions.system-audio",
        ] {
            let sourcePath = [
                "kAXSelectedAttribute",
                "performPress(identifier:",
                "CGEvent(mouseEventSource:",
                "AXChildrenInNavigationOrder",
            ].contains(requiredHarnessHook)
                ? "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/AXInspector.swift"
                : "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/UISmoke.swift"
            assertTrue(contractSource(sourcePath).contains(requiredHarnessHook), "\(requiredHarnessHook) should stay pinned in the UI smoke harness")
        }

        assertTrue(
            contractSource("scripts/ops/transcripted-qa-bench.sh").contains("quick|deep|full|ui|imported-audio-native|sparkle-update|packaged|artifact")
                && contractSource("scripts/ops/transcripted-qa-bench.sh").contains("run_ui_tail")
                && contractSource("scripts/ops/transcripted-qa-bench.sh").contains("transcripted-qa ui-smoke")
                && contractSource("scripts/ops/transcripted-qa-bench.sh").contains("ui-automation-smoke.json"),
            "QA bench should keep a callable ui mode with local JSON evidence"
        )
    }

    // WS4 "Premium minimalism" polish guards: teaching empty states (not gray
    // filler) and error states routed through shared plain-words copy (no raw
    // `error.localizedDescription` on a user-facing surface). The copy itself
    // is checked by value in AutomationSurfaceBehaviorTests.swift.
    runSuite("UI automation surface contract - WS4 empty states teach") {
        let speakers = contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift")

        assertTrue(
            speakers.contains("enum SpeakerPeopleEmptyState")
                && speakers.contains("static let title = \"No speakers yet\"")
                && speakers.contains("static let actionTitle = \"Start a meeting\"")
                && speakers.contains("transcripted.speakers.empty.start-meeting")
                && speakers.contains("struct SpeakersEmptyStateView")
                && speakers.contains("Transcripted learns each voice as you record."),
            "the Speakers surface should teach an empty first-run state, not render bare gray placeholder text"
        )
        assertFalse(
            speakers.contains("No speakers yet. After your next meeting, the people in it will appear here."),
            "the old bare-caption Speakers empty message should be gone, replaced by the teaching empty state"
        )
    }

    runSuite("UI automation surface contract - WS4 error states act, not dump") {
        let agent = contractSource("Sources/UI/Settings/AgentConnectionSettingsPage.swift")

        // Agent page: routes through the shared copy + a Copy Details reveal, and
        // no longer dumps a raw NSError into a user-visible label.
        assertTrue(
            agent.contains("AgentSetupFailureCopy.connect(agentName:")
                && agent.contains("AgentSetupFailureCopy.codexInbox")
                && agent.contains("private func failureNotice(")
                && agent.contains("transcripted.settings.agent.connect-error-details."),
            "the Agent page should surface plain-words failures with a Copy Details reveal, not raw error text"
        )
        assertFalse(
            agent.contains(".failed(error.localizedDescription)")
                || agent.contains("Could not set up Codex Inbox: \\(error"),
            "the Agent page must not interpolate a raw error into a user-facing setup message"
        )

        // Quiet-library onboarding redesign: the first-run flow no longer offers
        // a Claude Desktop connect card (agent connection now lives only in
        // Settings > Agent), so there is no onboarding-side connect-failure
        // copy to pin here anymore.

        // Settings statuses: the plain-words copy itself is checked by
        // SettingsActionFailureCopyTests; here, the shell must use it, keep a
        // Copy Details reveal, and never put a raw error in the status line.
        assertTrue(
            settingsShellSource().contains("SettingsActionFailureCopy.modelCacheRemoval")
                && settingsShellSource().contains("SettingsActionFailureCopy.launchAtLogin")
                && settingsShellSource().contains("SettingsActionFailureCopy.captureLibraryMigration(")
                && settingsShellSource().contains("func settingsFailureDetailsButton("),
            "Settings action failures should route through SettingsActionFailureCopy with a Copy Details reveal"
        )
        assertFalse(
            settingsShellSource().contains("setup failed: \\(error.localizedDescription)")
                || settingsShellSource().contains("Could not remove stale models: \\(error")
                || settingsShellSource().contains("Could not update launch at login: \\(error")
                || settingsShellSource().contains("Copy stopped: \\(error"),
            "Settings status lines must not interpolate a raw error into user-facing text"
        )
    }

}

private func sourceBlock(named startMarker: String, endingBefore endMarker: String, in source: String) -> String {
    guard let start = source.range(of: startMarker)?.lowerBound,
          let end = source[start...].range(of: endMarker)?.lowerBound else {
        return ""
    }
    return String(source[start..<end])
}

private func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.components(separatedBy: needle).count - 1
}
