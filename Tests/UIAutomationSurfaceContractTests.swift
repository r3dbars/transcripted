// Contract suite for the surfaces external UI automation and users rely on.
// The menubar and app-command suites build the real compiled pieces (the
// command table, MenuBarAutomationID, the AppKit menubar rows) and check them
// directly. The rest is grandfathered source text that greps Settings and Home
// files for stable AX identifiers and copy.
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

// The Writing tab: its page plus the views under Sources/UI/Settings/Writing/.
private func writingSurfaceContractContains(_ needle: String) -> Bool {
    [
        "Sources/UI/Settings/Pages/WritingSettingsPage.swift",
        "Sources/UI/Settings/Writing/WritingIntroView.swift",
        "Sources/UI/Settings/Writing/WritingDemoView.swift",
        "Sources/UI/Settings/Writing/WritingSetupFlowView.swift",
        "Sources/UI/Settings/Writing/WritingEverydayView.swift",
        "Sources/UI/Settings/Writing/WritingSettingsSection.swift",
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
    runSuite("Meetings header exposes existing capture actions") {
        for identifier in ["transcripted.home.new.menu", "transcripted.home.new.record-meeting", "transcripted.home.new.transcribe-file"] {
            assertTrue(contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains(identifier), "New menu should expose \(identifier)")
        }
        assertTrue(
            contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains("Image(systemName: \"plus\")")
                && contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains(".accessibilityLabel(\"New recording or transcription\")")
                && contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains(".menuIndicator(.hidden)")
                && contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains(".fill(isNewHovered ? LibraryTokens.rowHover : Color.clear)")
                && contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains("Label(\"Record a meeting\", systemImage: \"mic\")")
                && contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains("Label(\"Transcribe a file…\", systemImage: \"doc.badge.plus\")"),
            "New menu should use the approved plain-language labels"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/Pages/HomeSettingsPage.swift").contains("onStartMeeting: onStartMeeting,\n                onImportAudioFile: onImportAudioFile"),
            "Header should reuse the injected capture actions"
        )
    }
    runSuite("UI automation surface contract - menubar controls expose stable identifiers") {
        // These raw values are the strings external automation looks up. The
        // QA AX smoke (Tools/TranscriptedQA UISmoke) and the build.sh launch
        // smoke keep their own copies, so the cross-package lists stay pinned
        // here against the compiled enum.
        let expected: [MenuBarAutomationID: String] = [
            .statusItemButton: "transcripted.status-item.button",
            .startMeeting: "transcripted.menubar.primary.start-meeting",
            .startDictation: "transcripted.menubar.primary.start-dictation",
            .openTranscripted: "transcripted.menubar.utility.open-transcripted",
            .checkUpdates: "transcripted.menubar.utility.check-updates",
            .quit: "transcripted.menubar.utility.quit",
        ]
        assertEqual(MenuBarAutomationID.allCases.count, expected.count, "every menubar automation id should be listed here")
        for id in MenuBarAutomationID.allCases {
            assertEqual(id.rawValue, expected[id], "\(id) should keep the identifier external automation expects")
            assertTrue(
                contractSource("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/UISmoke.swift").contains(id.rawValue),
                "\(id.rawValue) should stay in the QA AX smoke's expected list"
            )
        }
        for id in MenuBarAutomationID.allCases where id != .statusItemButton {
            assertTrue(
                contractSource("scripts/entrypoints/build.sh").contains(id.rawValue),
                "\(id.rawValue) should stay enforced by the build.sh launch smoke"
            )
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

    runSuite("UI automation surface contract - menubar controls keep polished hit targets") {
        assertEqual(MenuTokens.minimumHitTargetSize, 40, "the menubar hit-target floor is 40pt")
        assertEqual(MenuTokens.panelHeight, 480, "the popover height keeps the default rows visible")

        _ = NSApplication.shared
        for size in [MenuBarActionRowView.Size.primary, .utility, .button] {
            for detail in ["", "Detail line"] {
                let row = MenuBarActionRowView(frame: .zero)
                row.update(symbolName: "power", title: "Quit", detail: detail, size: size)
                assertTrue(
                    row.intrinsicContentSize.height >= MenuTokens.minimumHitTargetSize,
                    "a \(size) row (detail: \(!detail.isEmpty)) should be at least the 40pt hit target"
                )
            }
        }

        let utility = MenuBarUtilityActionsView(frame: NSRect(x: 0, y: 0, width: MenuTokens.panelWidth, height: 200))
        utility.update(
            updateSymbolName: "arrow.down.circle",
            updateTitle: "Check for Updates",
            updateDetail: "You're up to date",
            updateVersion: "1.1.68",
            updateTone: .standard,
            updateEnabled: true
        )
        utility.layout()
        for row in utility.keyboardFocusableRows {
            assertTrue(
                row.frame.height >= MenuTokens.minimumHitTargetSize,
                "\(row.accessibilityIdentifier()) should be laid out at least 40pt tall"
            )
        }
    }

    runSuite("UI automation surface contract - app command table") {
        func item(_ title: String) -> AppMenuCommandItem? {
            TranscriptedMenuCommandTable.items.first { $0.title == title }
        }
        func describe(_ items: [AppMenuCommandItem]) -> [String] {
            items.map { "\($0.title) \($0.modifiers.rawValue):\($0.key)" }
        }

        // Settings… and ⌘, open the app's own Settings window on General.
        assertEqual(
            TranscriptedMenuCommandTable.items(in: .appSettings).map(\.action),
            [.openSettings],
            "the app menu's Settings group should hold only Settings…"
        )
        assertEqual(item("Settings…")?.key, ",", "Settings… should keep ⌘,")
        assertEqual(item("Settings…")?.modifiers, .command, "Settings… should keep ⌘,")
        assertEqual(AppMenuSettingsRoute.settingsPage, .general, "Settings… should open the General page")
        assertEqual(AppMenuSettingsRoute.settingsSource, "app_menu", "Settings… should report the app_menu source")

        let command = AppMenuModifiers.command
        let commandShift: AppMenuModifiers = [.command, .shift]
        assertEqual(
            describe(TranscriptedMenuCommandTable.items(in: .capture)),
            describe([
                AppMenuCommandItem(group: .capture, title: "Start Dictation", key: "d", modifiers: command, action: .startDictation),
                AppMenuCommandItem(group: .capture, title: "Start / Stop Meeting Recording", key: "r", modifiers: command, action: .toggleMeetingRecording),
                AppMenuCommandItem(group: .capture, title: "Transcribe Audio File…", key: "o", modifiers: command, action: .importAudio),
            ]),
            "the Capture menu should keep its titles and ⌘D / ⌘R / ⌘O"
        )
        assertEqual(
            TranscriptedMenuCommandTable.items(in: .capture).map(\.action),
            [.startDictation, .toggleMeetingRecording, .importAudio],
            "the Capture menu should route to dictation, the meeting toggle, and file import"
        )

        let goItems = TranscriptedMenuCommandTable.items(in: .go)
        assertEqual(
            goItems.map { "\($0.title) \($0.modifiers.rawValue):\($0.key)" },
            [
                "Today \(command.rawValue):1",
                "Meetings \(command.rawValue):2",
                "Dictations \(command.rawValue):3",
                "Writing \(command.rawValue):4",
                "Speakers \(command.rawValue):5",
                "Agent \(command.rawValue):6",
                "Find Meetings… \(command.rawValue):f",
                "Find Speaker… \(commandShift.rawValue):f",
            ],
            "the Go menu should keep its titles and ⌘1–⌘6, ⌘F, ⇧⌘F"
        )
        assertEqual(
            goItems.map(\.action),
            [
                .openPage(.today), .openPage(.home), .openPage(.dictations),
                .openPage(.writing), .openPage(.people), .openPage(.connectAgent),
                .findCaptures, .findSpeaker,
            ],
            "the Go menu should open the matching sidebar pages and searches"
        )

        // The sidebar shows the same ⌘ key in its tooltips.
        for goItem in goItems {
            guard case .openPage(let page) = goItem.action else { continue }
            assertEqual(page.navigationShortcutKey, String(goItem.key), "\(page) sidebar shortcut should match the Go menu")
            assertEqual(page.navigationHelp, "\(page.title)  ⌘\(goItem.key)", "\(page) sidebar help should show its Go shortcut")
        }

        // App-active commands never shadow the global recordable triggers:
        // only ⌘ (plus ⇧) shortcuts, nothing on M, no duplicate key combos.
        for entry in TranscriptedMenuCommandTable.items {
            assertTrue(entry.modifiers.contains(.command), "\(entry.title) should be a ⌘ shortcut")
            assertTrue(
                entry.modifiers.isDisjoint(with: [.option, .control]),
                "\(entry.title) must not use option or control, which the recordable triggers own"
            )
            assertFalse(entry.key == "m", "\(entry.title) must not take ⌘M")
        }
        let combos = TranscriptedMenuCommandTable.items.map { "\($0.modifiers.rawValue):\($0.key)" }
        assertEqual(Set(combos).count, combos.count, "no two menu commands should share a shortcut")
    }

    runSuite("UI automation surface contract - app commands route through the delegate entry points") {
        let delegate = UIAutomationMenuActionRecorder()
        for entry in TranscriptedMenuCommandTable.items {
            delegate.perform(entry.action)
        }
        assertEqual(
            delegate.calls,
            [
                "menuOpenSettings",
                "menuStartDictation",
                "menuToggleMeetingRecording",
                "menuImportAudio",
                "menuOpenPage(today)",
                "menuOpenPage(home)",
                "menuOpenPage(dictations)",
                "menuOpenPage(writing)",
                "menuOpenPage(people)",
                "menuOpenPage(connectAgent)",
                "menuFindCaptures",
                "menuFindSpeaker",
            ],
            "each menu command should call its own delegate entry point exactly once"
        )
    }

    // Kept as source text: the SwiftUI Settings scene and its fallback view live
    // in the @main App, which the fast runner can't build. They guard the old
    // bug where Command-, left a blank Settings scene on screen.
    runSuite("UI automation surface contract - native Settings routes to the real window") {
        let appSource = contractSource("Sources/TranscriptedApp.swift")
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

    runSuite("UI automation surface contract - major settings and Home flows stay mapped") {
        for pageCase in [
            "case today",
            "case home",
            "case dictations",
            "case writing",
            "case general",
            "case people",
            "case connectAgent",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/TranscriptedSettingsPage.swift").contains(pageCase), "\(pageCase) should stay in the settings navigation surface map")
        }

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsPage.swift").contains("var automationIdentifier: String")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsSidebar.swift").contains(".accessibilityIdentifier(page.automationIdentifier)"),
            "settings sidebar pages should expose stable automation identifiers"
        )

        for (typeName, path) in [
            ("GeneralSettingsPage", "Sources/UI/Settings/Pages/GeneralSettingsPage.swift"),
            ("StorageSettingsPage", "Sources/UI/Settings/Pages/StorageSettingsPage.swift"),
            ("AboutSettingsPage", "Sources/UI/Settings/Pages/AboutSettingsPage.swift"),
            ("HomeSettingsPage", "Sources/UI/Settings/Pages/HomeSettingsPage.swift"),
            ("WritingSettingsPage", "Sources/UI/Settings/Pages/WritingSettingsPage.swift"),
        ] {
            assertTrue(
                contractSource(path).contains("struct \(typeName)"),
                "\(typeName) should stay extracted while the Settings shell owns its bindings"
            )
        }

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains(".frame(width: 40, height: 40)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains("accessibilityIdentifier(\"transcripted.settings.general.info.\\(automationSlug(info.title))\")"),
            "General settings info buttons should keep compact visuals with a 40pt hit target and stable AX identifiers"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsRows.swift").contains(".frame(width: 40, height: 40)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsRows.swift").contains(".accessibilityLabel(Text(\"Remove correction\"))"),
            "custom dictionary remove controls should keep a 40pt destructive hit target with a clear AX label"
        )

        for requiredSourceHook in [
            "title: \"Transcribe a file\"",
            "actions.importAudioFile()",
            "secondaryAutomationIdentifier: \"transcripted.home.meetings.empty.import-audio\"",
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
        for requiredFailedMeetingPolicyHook in [
            "return \"This meeting does not have enough saved audio to retry.\"",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/FailedMeetingRecoveryPresentation.swift").contains(requiredFailedMeetingPolicyHook), "\(requiredFailedMeetingPolicyHook) should keep failed-meeting action policy visible")
        }
        assertFalse(
            contractSource("Sources/UI/Settings/FailedMeetingRecoveryPresentation.swift").contains("hasRetainedAudioFiles"),
            "failed-meeting policy should not retain an unreachable dismiss state"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".frame(minHeight: 40)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"),
            "shared inline settings actions should keep a 40pt hit floor for failed-meeting recovery controls"
        )
        // Quiet-library redesign: the retained-audio player is
        // HomeMeetingPodcastPlayer (HomeMeetingAudioPlayer.swift), whose
        // transport buttons size their hit target off HomeHitTarget.minimum.
        assertTrue(
            contractSource("Sources/UI/Settings/HomeMeetingAudioPlayer.swift").contains("max(size, HomeHitTarget.minimum)")
                && contractSource("Sources/UI/Settings/HomeMeetingAudioPlayer.swift").contains("hitTargetSize"),
            "Home retained-audio play controls should keep a 40pt hit floor"
        )
        assertTrue(
            contractSource("Sources/UI/Shared/MeetingAudioPlayback.swift").contains(".frame(minHeight: 40)")
                && contractSource("Sources/UI/Shared/MeetingAudioPlayback.swift").contains("struct MeetingAudioSourceMenu"),
            "retained-audio source menus should keep a 40pt hit floor"
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

        // Own-file resolution contract (hardening/home-meeting-own-file-resolver).
        // Every Home/meeting control that touches an app-owned file (transcript or
        // audio) must route through OwnFileResolver so a path that drifted
        // after scanning (restyle/rename, WAV→M4A recompression, deletion) surfaces
        // an error instead of a silent dead click. Behavior is covered by
        // OwnFileResolverTests; these guard the wiring so a regression that re-adds a
        // raw stale-path call (the #1126/#1131/#1134 whack-a-mole) fails CI.
        assertTrue(
            contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("static func resolveForReveal(")
                && contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("static func resolveExistingFile(")
                && contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("case reveal([URL])")
                && contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("case unavailable"),
            "OwnFileResolver must keep both reveal (with enclosing-folder fallback) and open/play (regular-file-only) resolution modes"
        )

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

        // Retained-audio playback follows recompressed/moved files instead of going
        // silently Unavailable on a stale path.
        assertTrue(
            contractSource("Sources/UI/Shared/MeetingAudioPlayback.swift").contains("OwnFileResolver.resolveExistingFile(candidateURLs:"),
            "meeting audio playback should resolve each source URL through OwnFileResolver so WAV→M4A recompression still plays"
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

        // Quiet-library onboarding redesign: the 14-step use-case-branching flow
        // collapsed into three steps (welcome, permissions, done). Microphone is
        // the only blocking permission; System Audio and Calendar are optional
        // rows on the single permissions screen.
        assertTrue(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("private static let steps: [OnboardingStepKind] = [.welcome, .permissions, .done]")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("FirstRunExperience.hasRequiredMeetingSetup(microphoneGranted: micGranted)"),
            "onboarding should stay a single three-step flow gated only on microphone"
        )
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

        for identifier in [
            "transcripted.home.expansion.name-speakers",
            "transcripted.home.expansion.speaker.\\(identity.stableID)",
            "transcripted.home.speaker-picker",
            "transcripted.home.speaker-picker.name",
            "transcripted.home.speaker-picker.cancel",
            "transcripted.home.speaker-picker.save",
            "transcripted.home.speaker-sheet",
            "transcripted.home.speaker-sheet.row.\\(draft.id).name",
            "transcripted.home.speaker-sheet.cancel",
            "transcripted.home.speaker-sheet.save",
        ] {
            assertTrue(
                contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains(identifier),
                "\(identifier) should keep meeting speaker correction scriptable without matching visible names"
            )
        }
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

        for requiredAgentHook in [
            "transcripted.settings.agent.connect.\\(agent.rawValue)",
            "transcripted.settings.agent.copy-prompt",
            "transcripted.settings.agent.copy-folder-paths",
            "transcripted.settings.agent.codex-inbox",
            "Copy Paths",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/AgentConnectionSettingsPage.swift").contains(requiredAgentHook), "\(requiredAgentHook) should stay in agent/connect automation scope")
        }

        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("Discard Recording…"),
            "the island's meeting right-click menu should keep a stable Discard title for automation"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift").contains("Delete this meeting?")
                && contractSource("Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift").contains("Delete Meeting")
                && contractSource("Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift").contains("Delete this failed meeting?")
                && contractSource("Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift").contains("Delete Failed Meeting"),
            "delete confirmation copy should stay pinned for destructive-flow automation"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains("settingsAutomationIdentifier")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains("transcripted.settings.permissions.\\(kind.rawValue).action"),
            "settings shared controls should support stable automation IDs"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains("generalAutomationIdentifier")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains("transcripted.settings.general.island-screen-sharing")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains("transcripted.settings.general.info.\\(automationSlug(info.title))"),
            "general settings controls should keep scriptable row and choice IDs"
        )
    }

    runSuite("UI automation surface contract - deterministic click-flow identifiers stay mapped") {
        // Quiet-library redesign: the stats sheet, the dictation-file-per-row
        // list, the meeting preview sheet, and the failed-meetings card all
        // dissolved into QuietHomeHeader's attention link/find toggle,
        // per-entry dictation rows (QuietDictationLibrary), the meeting row's
        // inline expansion (QuietHomeLibrary/HomeMeetingAudioPlayer), and
        // inline failed-meeting rows (HomeView's failed-meeting actions).
        for identifier in [
            "transcripted.home.row.copy",
            "transcripted.home.row.more",
            "transcripted.home.attention.link",
            "transcripted.home.find.toggle",
            "transcripted.dictations.row",
            "transcripted.dictations.row.copy",
            "transcripted.dictations.expansion.copy",
            "transcripted.dictations.expansion.open",
            "transcripted.home.meeting.preview",
            "transcripted.home.meeting-preview.audio.skip-back",
            "transcripted.home.meeting-preview.audio.toggle",
            "transcripted.home.meeting-preview.audio.skip-forward",
            "transcripted.home.failed-meeting.play-audio",
            "transcripted.home.failed-meeting.show-audio",
            "transcripted.home.failed-meeting.retry",
            "transcripted.home.failed-meeting.more",
            "transcripted.home.load-more",
        ] {
            assertTrue(homeSurfaceContractContains(identifier), "\(identifier) should stay attached to Home click-flow controls")
        }
        assertFalse(
            homeSurfaceContractContains("transcripted.home.failed-meeting.dismiss"),
            "failed meetings should not expose an unreachable non-destructive click flow"
        )

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
            "transcripted.settings.general.transcribe-audio-file",
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

        // Quiet-library redesign: the attention pills row dissolved into
        // QuietHomeHeader's single attention-clause link in the header
        // sentence (see the click-flow identifier loop above for
        // transcripted.home.attention.link's own coverage).
        assertTrue(
            contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains("struct QuietHomeHeader: View")
                && contractSource("Sources/UI/Settings/QuietHomeLibrary.swift").contains("let attentionTitle: String?"),
            "the Home header's attention clause should stay labeled and scriptable"
        )

        assertTrue(
            settingsShellSource().contains("HomeRowMenuItem(title: \"Review speakers\"")
                && settingsShellSource().contains("let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)")
                && settingsShellSource().contains("if !audioRevealURLs.isEmpty")
                && settingsShellSource().contains("title: RecentMeetingRetranscriptionMenuActionPolicy.title("),
            "meeting speaker review and re-transcribe actions should stay reachable from the row menu when retained audio has a Finder target"
        )

        for identifier in [
            "transcripted.onboarding.nav.back",
            "transcripted.onboarding.nav.primary",
            "transcripted.onboarding.permissions.microphone",
            "transcripted.onboarding.permissions.system-audio",
            "transcripted.onboarding.permissions.accessibility",
            "transcripted.onboarding.permissions.calendar",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains(identifier), "\(identifier) should stay attached to onboarding click-flow controls")
        }

        // Quiet-library onboarding redesign: the use-case choice cards are gone
        // (single path, no branching). Keep the nav controls scriptable and the
        // microphone-required gate legible in source.
        assertTrue(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcripted.onboarding.nav.back")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcripted.onboarding.nav.primary")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("case .permissions:\n            return !hasRequiredPermissions")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("case .done:\n            return !canFinishSetup")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("hasRequiredPermissions || skippedMicrophone")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("LibraryTokens.minimumHitTarget"),
            "onboarding nav controls should stay scriptable and gate progress on the microphone-required check"
        )
        // After a Don't Allow, macOS won't ask for the mic again, so setup
        // offers a skip instead of a dead end; it never shows before that.
        assertTrue(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("guard currentStep == .permissions, micBlocked, !micGranted else { return nil }")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcripted.onboarding.nav.secondary"),
            "onboarding should offer Skip for now only once the microphone is blocked"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".monospacedDigit()")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains("modelProgressLabelMinimumWidth")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".accessibilityLabel(Text(status))"),
            "onboarding/local-model progress labels should stay stable, tabular, and accessible"
        )
    }

    runSuite("UI automation surface contract - Writing tab controls stay mapped") {
        for identifier in [
            "transcripted.settings.page.writing",
            "transcripted.settings.writing.intro.next",
            "transcripted.settings.writing.intro.back",
            "transcripted.settings.writing.intro.set-up",
            "transcripted.settings.writing.intro.demo",
            "transcripted.settings.writing.setup.save-my-writing",
            "transcripted.settings.writing.setup.autocomplete",
            "transcripted.settings.writing.setup.continue",
            "transcripted.settings.writing.setup.back",
            "transcripted.settings.writing.setup.cancel",
            "transcripted.settings.writing.setup.scope.all",
            "transcripted.settings.writing.setup.scope.picked",
            "transcripted.settings.writing.setup.more-apps",
            "transcripted.settings.writing.setup.turn-on",
            "transcripted.settings.writing.status",
            "transcripted.settings.writing.edit-setup",
            "transcripted.settings.writing.pause",
            "transcripted.settings.writing.resume",
            "transcripted.settings.writing.keyboard.turn-on",
            "transcripted.settings.writing.screen-recording.allow",
            "transcripted.settings.writing.entry",
            "transcripted.settings.writing.settings.save-my-writing",
            "transcripted.settings.writing.settings.autocomplete",
            "transcripted.settings.writing.settings.personalized",
            "transcripted.settings.writing.settings.model",
            "transcripted.settings.writing.settings.storage",
            "transcripted.settings.writing.delete-all",
            "transcripted.settings.writing.delete-all.confirm",
        ] {
            assertTrue(writingSurfaceContractContains(identifier), "\(identifier) should stay attached to a Writing tab control")
        }

        // The page routes intro -> setup -> everyday from the model's screen,
        // and the shell only hands it the controller and the recording check.
        let page = contractSource("Sources/UI/Settings/Pages/WritingSettingsPage.swift")
        assertTrue(
            page.contains("case let .intro(page):")
                && page.contains("case let .setup(step):")
                && page.contains("case .everyday:"),
            "the Writing page should route the intro pages, setup steps and everyday view"
        )

        // Screen Recording can make macOS ask Transcripted to quit and reopen,
        // so the ask never happens while anything records.
        let model = contractSource("Sources/Writing/WritingSettingsModel.swift")
        assertTrue(
            model.contains("if choices.autocomplete, !controller.screenRecordingGranted, !isCaptureBusy() {")
                && model.contains("guard !isCaptureBusy() else {"),
            "every Screen Recording request should wait while a meeting or dictation records"
        )
        assertTrue(
            writingSurfaceContractContains("WritingPrimaryButton(")
                && contractSource("Sources/UI/Settings/Writing/WritingComponents.swift").contains("LibraryTokens.minimumHitTarget"),
            "Writing tab actions should keep the 40pt hit target"
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

    // WS4 "Premium minimalism" polish guards. These pin the visual/UX polish so
    // it can't silently regress: teaching empty states (not gray filler),
    // plain-words error states routed through shared copy (no raw
    // `error.localizedDescription` on a user-facing surface), and design tokens.
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
        let agentCopy = contractSource("Sources/UI/Settings/AgentSetupFailureCopy.swift")
        let settingsCopy = contractSource("Sources/UI/Settings/SettingsActionFailureCopy.swift")

        // Shared plain-words primitives exist and are the single source of copy.
        assertTrue(
            agentCopy.contains("enum AgentSetupFailureCopy")
                && agentCopy.contains("static let detailsTitle = \"Copy Details\"")
                && agentCopy.contains("Transcripted couldn't connect \\(agentName)")
                && agentCopy.contains("static let codexInbox"),
            "AgentSetupFailureCopy should hold plain-words connect/setup failure copy behind a Copy Details reveal"
        )
        assertTrue(
            settingsCopy.contains("enum SettingsActionFailureCopy")
                && settingsCopy.contains("static let modelCacheRemoval")
                && settingsCopy.contains("static func captureLibraryMigration("),
            "SettingsActionFailureCopy should hold plain-words settings-action failure copy"
        )

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

    runSuite("UI automation surface contract - WS4 design tokens are the single source") {
        _ = NSApplication.shared
        @MainActor func label(in view: NSView, showing text: String) -> NSTextField? {
            view.layout()
            return view.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
        }

        let primaryRow = MenuBarActionRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 42))
        primaryRow.update(symbolName: "mic.fill", title: "Record Meeting", detail: "", size: .primary)
        assertTrue(
            label(in: primaryRow, showing: "Record Meeting")?.font == MenuTokens.Font.rowTitlePrimary,
            "a primary row title should use MenuTokens.Font.rowTitlePrimary"
        )
        let utilityRow = MenuBarActionRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        utilityRow.update(symbolName: "power", title: "Quit", detail: "", size: .utility)
        assertTrue(
            label(in: utilityRow, showing: "Quit")?.font == MenuTokens.Font.rowTitleUtility,
            "a utility row title should use MenuTokens.Font.rowTitleUtility"
        )
        // MenuBarHeaderView needs MeetingSessionController, which the fast
        // runner doesn't compile, so its font stays a source-text check.
        let header = contractSource("Sources/UI/MenuBar/MenuBarHeaderView.swift")
        assertTrue(
            header.contains("MenuTokens.Font.headerStatus"),
            "the header status line should read its font from MenuTokens.Font"
        )
        assertFalse(
            header.contains("NSFont.systemFont(ofSize: 11.5"),
            "the header should not re-inline a raw NSFont size now that MenuTokens.Font owns it"
        )

        let doc = contractSource("docs/DESIGN_TOKENS.md")
        assertTrue(
            doc.contains("Type scale")
                && doc.contains("Spacing grid")
                && doc.contains("Corner radii")
                && doc.contains("MenuTokens.Font"),
            "docs/DESIGN_TOKENS.md should exist as the single source documenting the type, spacing, and radius scales"
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

@MainActor
private final class UIAutomationMenuActionRecorder: AppMenuActionPerforming {
    var calls: [String] = []

    func menuOpenSettings() { calls.append("menuOpenSettings") }
    func menuStartDictation() { calls.append("menuStartDictation") }
    func menuToggleMeetingRecording() { calls.append("menuToggleMeetingRecording") }
    func menuImportAudio() { calls.append("menuImportAudio") }
    func menuOpenPage(_ page: TranscriptedSettingsPage) { calls.append("menuOpenPage(\(page.rawValue))") }
    func menuFindCaptures() { calls.append("menuFindCaptures") }
    func menuFindSpeaker() { calls.append("menuFindSpeaker") }
}

/// The row answers AXPress first and runs its action on the next main-queue
/// turn; anything queued after the press runs after the action.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}
