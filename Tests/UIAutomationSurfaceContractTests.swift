// Repo-structure / contract suite, not behavioral coverage.
// What's left here reads Swift files as text, for one of three reasons:
//   - the code lives in TranscriptedApp.swift, the TranscriptedSettingsView
//     split, the SpeakerPeople split, or HomeView.swift, which need seams of
//     their own next;
//   - the code is the meeting overlay controller, whose island path still
//     needs a seam;
//   - it's a view-wiring guard (a SwiftUI view calls a policy, or must never
//     call a raw API) that no fast test can render.
// The identifiers the QA smokes press and the Settings/Speakers click-flow
// identifiers are checked by scripts/dev/check-ui-automation-contract.py.
// The menu bar rows, app commands, onboarding footer, launch-smoke and QA-smoke
// identifiers, and failure copy are behavior tests in
// AutomationSurfaceBehaviorTests.swift now. The QA CLI's ui-smoke command and
// report are tested in its own package (UISmokeReportTests); the QA tools are
// read here only as data (which identifiers and launch settings they use) and
// run through the app's compiled policies. Hit-target and empty-state values
// are checked by value (HomeHitTarget, SpeakerPeopleSettingsConstants).
//
// Adding a new contract guard is purely additive: call `contractSource("Sources/.../X.swift")`
// inline inside an assertion. Do NOT reintroduce a top-of-suite block of
// `let xSource = readSourceFixture(...)` declarations — that append-only
// hotspot is what made two concurrent UI PRs collide on a duplicate `let` declaration
// (the same pattern that bit AnalyticsEventPolicy.swift). `contractSource` reads and
// memoizes each file on demand, so repeated reads of the same path are free and two
// PRs can add guards for the same file without redeclaring anything.

import AppKit
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

@MainActor
func testUIAutomationSurfaceContract() async {
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

        // Microphone picker visibility and its "Same as macOS Sound settings"
        // entry are behavior tests now: MicrophoneSettingsPolicyTests.
    }

    runSuite("Acknowledged unverified system audio stays visible in the recording pill") {
        assertTrue(contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("systemAudioUnverified: systemAudioDegradationWarning?.cause == .unverified"),
            "The recording pill must receive recording-scoped uncertainty")
        // The PCM-evidence and tail-failure halves are behavior tests now:
        // "Capture health evidence comes from this capture, not a cached
        // permission" in MeetingSessionUIPolicyTests.
    }
    runSuite("Confirmed system-audio denial offers a grant action") {
        let controller = contractSource("Sources/UI/Overlay/MeetingOverlayController.swift")
        // Typed permission evidence behind the action: MeetingSessionUIPolicyTests,
        // "Capture health evidence comes from this capture, not a cached permission".
        assertTrue(controller.contains("meetingSession?.systemAudioPermissionRecoveryNeeded == true"),
            "the overlay should render the action only for a typed denial")
    }
    runSuite("UI automation surface contract - menubar controls expose stable identifiers") {
        // These raw values are the strings external automation looks up. The
        // QA AX smoke (Tools/TranscriptedQA UISmoke) keeps its own copies, so
        // its identifier list is read as data and checked against the compiled
        // enum. The build.sh launch smoke's rows are checked against the real
        // views in AutomationSurfaceBehaviorTests ("The launch smoke's menu bar
        // expectations match the real rows").
        let expected: [MenuBarAutomationID: String] = [
            .statusItemButton: "transcripted.status-item.button",
            .startMeeting: "transcripted.menubar.primary.start-meeting",
            .startDictation: "transcripted.menubar.primary.start-dictation",
            .openTranscripted: "transcripted.menubar.utility.open-transcripted",
            .checkUpdates: "transcripted.menubar.utility.check-updates",
            .quit: "transcripted.menubar.utility.quit",
        ]
        assertEqual(MenuBarAutomationID.allCases.count, expected.count, "every menubar automation id should be listed here")
        let qaUISmokeIDs = qaUISmokeIdentifiers()
        for id in MenuBarAutomationID.allCases {
            assertEqual(id.rawValue, expected[id], "\(id) should keep the identifier external automation expects")
            assertTrue(qaUISmokeIDs.contains(id.rawValue), "\(id.rawValue) should stay in the QA AX smoke's expected list")
        }

        _ = NSApplication.shared
        let primary = MenuBarPrimaryActionsView(frame: .zero)
        let utility = MenuBarUtilityActionsView(frame: .zero)
        utility.update(
            updateSymbolName: "arrow.down.circle",
            updateTitle: "Check for Updates",
            updateDetail: "",
            updateVersion: nil,
            updateTone: .standard,
            updateEnabled: true
        )
        assertEqual(
            Set((primary.keyboardFocusableRows + utility.keyboardFocusableRows).map { $0.accessibilityIdentifier() }),
            Set(MenuBarAutomationID.allCases.filter { $0 != .statusItemButton }.map(\.rawValue)),
            "the real popover rows should carry every row identifier as their AX identifier"
        )
        assertEqual(
            utility.smokeSnapshot.mapValues(\.automationIdentifier),
            [
                "checkUpdates": MenuBarAutomationID.checkUpdates.rawValue,
                "openTranscripted": MenuBarAutomationID.openTranscripted.rawValue,
                "quit": MenuBarAutomationID.quit.rawValue,
            ],
            "the utility smoke snapshot should report the identifiers AppKit automation sees"
        )
    }

    await runSuite("UI automation surface contract - menubar action rows are AX buttons with a real press path") {
        _ = NSApplication.shared
        let row = MenuBarActionRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        row.setAutomationIdentifier(.openTranscripted)
        row.update(symbolName: "mic.fill", title: "Record Meeting", displayTitle: "Record", detail: "Mic and system audio", size: .button)
        var presses = 0
        row.onPress = { presses += 1 }

        assertEqual(row.accessibilityIdentifier(), MenuBarAutomationID.openTranscripted.rawValue, "the row should expose its automation id to AX")
        assertEqual(row.identifier?.rawValue, MenuBarAutomationID.openTranscripted.rawValue, "the row's NSView identifier should match its AX identifier")
        assertEqual(row.smokeSnapshot.automationIdentifier, MenuBarAutomationID.openTranscripted.rawValue, "the smoke snapshot should report the AX identifier")
        assertEqual(row.accessibilityRole(), .button, "a menubar row should be an AX button")
        assertTrue(row.isAccessibilityElement(), "a menubar row should be an AX element")
        assertEqual(row.accessibilityLabel(), "Record", "the AX label should be the title on screen, so Voice Control can match it")

        assertTrue(row.accessibilityPerformPress(), "AXPress on an enabled row should succeed")
        await drainMainQueue()
        assertEqual(presses, 1, "AXPress on an enabled row should run its action")

        row.update(symbolName: "mic.fill", title: "Record Meeting", detail: "", size: .button, isEnabled: false)
        assertFalse(row.accessibilityPerformPress(), "AXPress on a disabled row should fail")
        await drainMainQueue()
        assertEqual(presses, 1, "AXPress on a disabled row should not run its action")
    }

    runSuite("UI automation surface contract - native Settings routes to the real window") {
        let appSource = contractSource("Sources/App/TranscriptedApp.swift")
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
            assertTrue(contractSource("Sources/App/TranscriptedApp.swift").contains(requiredAppHook), "\(requiredAppHook) should keep app commands wired through existing app-delegate actions")
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
        assertEqual(HomeHitTarget.minimum, 40, "Home icon buttons and compact row actions should keep a shared 40pt hit-target floor")
        assertTrue(
            HomeHitTarget.compactVisibleSize < HomeHitTarget.minimum,
            "a compact Home icon may look smaller than its hit target, never the other way round"
        )
        assertTrue(
            homeSurfaceContractContains("HomeHitTarget.minimum"),
            "Home icon buttons and compact row actions should size their hit shape from HomeHitTarget.minimum"
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

        // The speaker autocomplete keeping the picked saved-person UUID and
        // clearing it on typing is a behavior test now:
        // SpeakerNameAutocompleteFieldTests ("Explicit non-first suggestion
        // selection commits its plain name and exact UUID").
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
        assertTrue(
            contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("transcripted.speakers.inbox")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains(".id(ScrollTarget.reviewQueue)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("proxy.scrollTo(SpeakerPeopleSettingsSection.ScrollTarget.reviewQueue"),
            "The voices-to-name section should keep a stable automation anchor that review deep-links can scroll to"
        )

        assertEqual(SpeakerPeopleSettingsPolishContract.minimumHitTarget, 40, "speaker play and icon controls should keep a 40pt hit target")
        assertEqual(SpeakerPeopleSettingsPolishContract.quietPlayGlyphPointSize, 14, "the quiet play control should stay a small glyph, not a filled circle")
        assertEqual(SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter, 28, "the compact icon should look smaller than its hit target")
        assertTrue(
            SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter < SpeakerPeopleSettingsPolishContract.minimumHitTarget,
            "speaker settings should keep quiet icon chrome separate from the 40pt hit shape"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("struct SpeakerCompactIconLabel")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("struct SpeakerQuietPlayButton")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains(".contentShape(Rectangle())"),
            "speaker settings should draw quiet play/icon chrome inside a full hit shape"
        )

        // The person card's player is a bare glyph (SpeakerQuietPlayButton);
        // queue rows and person rows play from their voice print instead (its
        // automation id is pinned by check-ui-automation-contract.py). The
        // compact icon label backs the two overflow menus.
        assertTrue(
            speakersSettingsSource().components(separatedBy: "SpeakerQuietPlayButton(").count - 1 >= 1,
            "the person card's play control should use the quiet 40pt hit-target play button"
        )
        assertTrue(
            speakersSettingsSource().components(separatedBy: "SpeakerCompactIconLabel(").count - 1 >= 2,
            "queue and person overflow menus should use the compact 40pt hit-target label"
        )

        assertTrue(
            settingsShellSource().contains("HomeRowMenuItem(title: \"Review speakers\"")
                && settingsShellSource().contains("let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)")
                && settingsShellSource().contains("if !audioRevealURLs.isEmpty")
                && settingsShellSource().contains("title: RecentMeetingRetranscriptionMenuActionPolicy.title("),
            "meeting speaker review and re-transcribe actions should stay reachable from the row menu when retained audio has a Finder target"
        )

    }

    // The QA CLI's own behavior (ui-smoke registered, INCOMPLETE exits 3, the
    // report carries the onboarding evidence) is tested in its package:
    // Tools/TranscriptedQA/Tests/TranscriptedQATests/UISmokeReportTests.swift.
    // The bench running ui-smoke with a JSON report is checked by
    // scripts/dev/check-qa-harness-contract.py. Here, the harness's choices are
    // read as data and run through the app's compiled policies.
    runSuite("UI automation surface contract - the QA AX smoke drives the app's real surfaces") {
        let qaUISmokeIDs = qaUISmokeIdentifiers()
        for identifier in [
            "transcripted.status-item.button",
            "transcripted.menubar.utility.open-transcripted",
            "transcripted.home.find.toggle",
            "transcripted.settings.page.storage",
            "transcripted.settings.sidebar.settings-toggle",
            "transcripted.settings.sidebar.dictations",
            "transcripted.onboarding.permissions.system-audio",
        ] {
            assertTrue(qaUISmokeIDs.contains(identifier), "the QA AX smoke should still check \(identifier)")
        }
    }

    runSuite("UI automation surface contract - the QA AX smoke launches the app as an automated run with telemetry off") {
        let smoke = qaUISmokeText()
        let preferenceKeys = capturedStrings(in: smoke, pattern: #""(observability-[a-z-]+)":\s*false"#)
        assertTrue(preferenceKeys.count >= 2, "the isolated home should switch off both telemetry preferences")

        let suiteName = "transcripted-tests-qa-ui-smoke-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "a scratch defaults suite should open")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        assertTrue(AnalyticsPreferences.isEnabled(userDefaults: defaults), "analytics should default on, so the test below proves the smoke's keys turn it off")
        assertTrue(CrashReportingPreferences.isEnabled(userDefaults: defaults), "crash reports should default on, so the test below proves the smoke's keys turn them off")
        for key in preferenceKeys {
            defaults.set(false, forKey: key)
        }
        assertFalse(AnalyticsPreferences.isEnabled(userDefaults: defaults), "the QA smoke's preferences should turn the app's analytics off")
        assertFalse(CrashReportingPreferences.isEnabled(userDefaults: defaults), "the QA smoke's preferences should turn the app's crash reports off")

        let environmentKeys = capturedStrings(in: smoke, pattern: #"environment\["(TRANSCRIPTED_[A-Z_]+)"\]\s*="#)
        assertFalse(environmentKeys.isEmpty, "the QA smoke should mark its launch through the environment")
        for key in environmentKeys {
            assertTrue(
                AutomatedLaunchEnvironment.isActive(environment: [key: "/tmp/transcripted-ui-smoke/launch-report.json"]),
                "\(key) set by the QA smoke should make the app treat the launch as automated"
            )
        }
    }

    runSuite("UI automation surface contract - the QA bench offers a ui mode") {
        let help = runQABenchHelp()
        assertEqual(help.status, 0, "the QA bench help should print without running anything")
        assertTrue(
            help.output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ui ") },
            "the QA bench should list a ui mode for the AX smoke"
        )
    }

    // WS4 "Premium minimalism" polish guards: teaching empty states (not gray
    // filler) and error states routed through shared plain-words copy (no raw
    // `error.localizedDescription` on a user-facing surface). The copy itself
    // is checked by value in AutomationSurfaceBehaviorTests.swift.
    runSuite("UI automation surface contract - WS4 empty states teach") {
        let speakers = contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift")

        assertEqual(SpeakerPeopleEmptyState.title, "No speakers yet", "the Speakers empty state should say plainly that there are no speakers yet")
        assertTrue(
            SpeakerPeopleEmptyState.message.hasPrefix("Transcripted learns each voice as you record."),
            "the Speakers empty state should teach how the list fills, not show bare gray placeholder text"
        )
        assertEqual(SpeakerPeopleEmptyState.actionTitle, "Record a meeting", "the Speakers empty state should offer the one action that fills it")
        assertEqual(
            SpeakerPeopleEmptyState.actionAutomationIdentifier,
            "transcripted.speakers.empty.start-meeting",
            "the empty state's action should keep a stable automation identifier"
        )
        assertTrue(
            speakers.contains("struct SpeakersEmptyStateView"),
            "the Speakers surface should render the teaching empty state view"
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

/// The QA AX smoke (Tools/TranscriptedQA UISmoke and its UISmoke*.swift
/// extensions), read as data: the identifiers it checks and the launch
/// settings it uses are its inputs, not app code.
private func qaUISmokeText() -> String {
    let directory = "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: repoFixtureURL(directory).path)) ?? [])
        .filter { $0.hasPrefix("UISmoke") && $0.hasSuffix(".swift") }
        .sorted()
    return names
        .map { (try? String(contentsOf: repoFixtureURL("\(directory)/\($0)"), encoding: .utf8)) ?? "" }
        .joined(separator: "\n")
}

private func qaUISmokeIdentifiers() -> Set<String> {
    automationIdentifierLiterals(in: qaUISmokeText())
}

private func capturedStrings(in text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
}

/// Runs the QA bench's `--help`, which prints its usage and exits before any
/// step runs.
private func runQABenchHelp() -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repoFixtureURL("scripts/ops/transcripted-qa-bench.sh").path, "--help"]
    process.currentDirectoryURL = repoFixtureURL(".")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-127, String(describing: error))
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The row answers AXPress first and runs its action on the next main-queue
/// turn; anything queued after the press runs after the action.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}
