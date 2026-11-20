// Behavior checks for the surfaces outside automation drives: the menu bar
// rows the launch smoke and `transcripted-qa ui-smoke` press, the app's ⌘
// commands, the onboarding footer, and the plain-words failure copy.
//
// These replaced source-text pins in UIAutomationSurfaceContractTests.swift.
// They build the real AppKit rows and call the compiled policies instead of
// reading Swift files. The launch smoke (build.sh) and the QA smokes
// (Tools/TranscriptedQA) are read as data: whatever identifiers they press,
// the app must produce.

import AppKit
import Foundation

@MainActor
func testAutomationSurfaceBehavior() async {
    _ = NSApplication.shared

    // MARK: Menu bar rows

    let row = MenuBarActionRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    row.update(symbolName: "power", title: "Quit", detail: "")
    row.setAutomationIdentifier("transcripted.menubar.utility.quit")
    var presses = 0
    row.onPress = { presses += 1 }
    let pressAnswered = row.accessibilityPerformPress()
    // The row answers AXPress first and acts on the next main-queue turn.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    let pressesAfterEnabledPress = presses
    row.isEnabled = false
    let disabledPressAnswered = row.accessibilityPerformPress()
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    let pressesAfterDisabledPress = presses

    runSuite("Menu bar rows expose the identifier, role, label, and press AppKit automation uses") {
        assertEqual(row.accessibilityIdentifier(), "transcripted.menubar.utility.quit", "AX automation finds the row by this identifier")
        assertEqual(row.identifier?.rawValue, "transcripted.menubar.utility.quit", "the view identifier should match the AX identifier")
        assertEqual(row.smokeSnapshot.automationIdentifier, "transcripted.menubar.utility.quit", "the launch smoke snapshot should carry the same identifier")
        assertEqual(row.accessibilityRole(), .button, "a row should read as a button to VoiceOver and the UI smoke")
        assertEqual(row.accessibilityLabel(), "Quit", "the AX label should be the words on screen")
        assertTrue(row.isAccessibilityElement(), "the row itself is the accessible control")
        assertTrue(pressAnswered, "an enabled row should accept AXPress")
        assertEqual(pressesAfterEnabledPress, 1, "AXPress on an enabled row should run its action once")
        assertFalse(disabledPressAnswered, "a disabled row should refuse AXPress")
        assertEqual(pressesAfterDisabledPress, 1, "AXPress on a disabled row should not run its action")
    }

    runSuite("Menu bar rows keep a 40pt hit target in every size") {
        assertTrue(MenuTokens.minimumHitTargetSize >= 40, "the menu bar hit-target floor should stay at least 40pt")
        assertTrue(LibraryTokens.minimumHitTarget >= 40, "the window's hit-target floor should stay at least 40pt")
        let sizes: [MenuBarActionRowView.Size] = [.primary, .utility, .button]
        for size in sizes {
            for detail in ["", "Sets up the first time you use it"] {
                let sized = MenuBarActionRowView(frame: .zero)
                sized.update(symbolName: "mic.fill", title: "Start Dictation", detail: detail, size: size)
                assertTrue(
                    sized.intrinsicContentSize.height >= MenuTokens.minimumHitTargetSize,
                    "a \(size) row\(detail.isEmpty ? "" : " with a detail line") should be at least the 40pt hit target"
                )
            }
        }
    }

    runSuite("The launch smoke's menu bar expectations match the real rows") {
        let primary = MenuBarPrimaryActionsView(frame: .zero)
        primary.update(
            dictationTrailing: "",
            meetingTrailing: "",
            dictationState: FirstRunExperience.dictationAction(for: .ready),
            meetingState: FirstRunExperience.meetingAction(dictationReady: true, meetingsStatus: "Ready"),
            isMeetingRecording: false
        )
        let utility = MenuBarUtilityActionsView(frame: .zero)
        // Ready with nothing to update: the update row is hidden.
        utility.update(
            updateSymbolName: "arrow.triangle.2.circlepath.circle",
            updateTitle: UpdateStatusWords.checkForUpdates,
            updateDetail: "",
            updateVersion: nil,
            updateTone: .standard,
            updateEnabled: true,
            showUpdateRow: false
        )
        let snapshots = primary.smokeSnapshot.merging(utility.smokeSnapshot) { first, _ in first }
        assertEqual(snapshots["checkUpdates"]?.isVisible, false, "the ready popover has no permanent update row")

        let buildScript = (try? String(contentsOf: repoFixtureURL("scripts/entrypoints/build.sh"), encoding: .utf8)) ?? ""
        let expectations = launchSmokeRowExpectations(in: buildScript)
        assertEqual(
            Set(expectations.map(\.key)),
            ["startDictation", "startMeeting", "openTranscripted", "quit"],
            "build.sh's launch smoke should check the four always-on menu bar rows"
        )
        for expectation in expectations {
            guard let snapshot = snapshots[expectation.key] else {
                assertTrue(false, "the menu bar has no row for the launch smoke key \(expectation.key)")
                continue
            }
            assertEqual(snapshot.title, expectation.title, "\(expectation.key) should report the title the launch smoke expects")
            assertEqual(snapshot.automationIdentifier, expectation.identifier, "\(expectation.key) should carry the identifier the launch smoke expects")
            assertTrue(snapshot.isVisible, "\(expectation.key) should be visible in the ready state")
            assertTrue(snapshot.isEnabled, "\(expectation.key) should be enabled in the ready state")
        }
        assertEqual(snapshots["startMeeting"]?.displayTitle, "Record", "the meeting button shows the short title the launch smoke expects")
        assertEqual(snapshots["startDictation"]?.displayTitle, "Dictate", "the dictation button shows the short title the launch smoke expects")
    }

    runSuite("The menu bar, sidebar and import identifiers the QA smokes press come from the real code") {
        let pressed = qaSmokePressedIdentifiers()
        assertTrue(pressed.count >= 20, "the QA smokes should still drive the menu bar, sidebar, onboarding and import controls")

        var produced = Set<String>()
        let primary = MenuBarPrimaryActionsView(frame: .zero)
        let utility = MenuBarUtilityActionsView(frame: .zero)
        for row in primary.keyboardFocusableRows + utility.keyboardFocusableRows {
            produced.insert(row.accessibilityIdentifier())
        }
        produced.formUnion(TranscriptedSettingsPage.allCases.map(\.automationIdentifier))
        produced.insert(HomeCaptureListCopy.ImportFileRow.automationIdentifier)

        // The rest (status item, onboarding, page roots) live in SwiftUI views
        // and the app delegate this runner can't build; the contract scan in
        // UIAutomationSurfaceContractTests.swift covers them.
        let compiledFamilies = ["transcripted.menubar.", "transcripted.settings.general.transcribe-audio-file"]
        let sidebarPages = Set(TranscriptedSettingsPage.allCases.map(\.automationIdentifier))
        for identifier in pressed.sorted() where compiledFamilies.contains(where: identifier.hasPrefix) {
            assertTrue(produced.contains(identifier), "\(identifier) is pressed by the QA smokes but the real views don't produce it")
        }
        for identifier in pressed.sorted() where identifier.hasPrefix("transcripted.settings.sidebar.") && identifier != "transcripted.settings.sidebar.settings-toggle" {
            assertTrue(sidebarPages.contains(identifier), "\(identifier) is pressed by the QA smokes but no settings page produces it")
        }
    }

    // MARK: App commands

    runSuite("App commands give capture, Settings and Go conventional ⌘ shortcuts") {
        let settings = TranscriptedMenuCommandCatalog.settings
        assertEqual(settings.key, ",", "Settings… should be ⌘,")
        assertFalse(settings.usesShift, "Settings… should be plain ⌘,")
        assertEqual(settings.action, .openSettings, "⌘, should open the real Settings window")

        assertEqual(
            TranscriptedMenuCommandCatalog.capture.map(\.action),
            [.startDictation, .toggleMeetingRecording, .importAudio],
            "the Capture menu should hold dictation, meeting start/stop, and file import, in that order"
        )
        assertEqual(
            TranscriptedMenuCommandCatalog.capture.map { String($0.key) },
            ["d", "r", "o"],
            "Capture should keep ⌘D, ⌘R and ⌘O"
        )
        assertTrue(
            TranscriptedMenuCommandCatalog.capture.allSatisfy { !$0.usesShift },
            "Capture shortcuts should be plain ⌘ keys"
        )

        let go = TranscriptedMenuCommandCatalog.go
        assertTrue(go.contains { $0.action == .findCaptures && $0.key == "f" && !$0.usesShift }, "Go should keep ⌘F for finding meetings")
        assertTrue(go.contains { $0.action == .findSpeaker && $0.key == "f" && $0.usesShift }, "Go should keep ⌘⇧F for finding a speaker")
    }

    runSuite("The Go menu's page shortcuts are the sidebar's ⌘1–⌘6") {
        let pageItems = TranscriptedMenuCommandCatalog.go.compactMap { item -> (TranscriptedSettingsPage, Character, String)? in
            guard case let .openPage(page) = item.action else { return nil }
            return (page, item.key, item.title)
        }
        // The retired file page has no ⌘ number: ⌘O in Capture opens file import.
        assertNil(TranscriptedSettingsPage.files.navigationShortcutKey, "file import should leave ⌘O to Capture's file import")
        let numberedSidebarOrder = FocusOrderContract.settingsSidebarOrder
        assertEqual(
            pageItems.map { $0.0.automationIdentifier },
            numberedSidebarOrder,
            "Go should list the numbered sidebar pages in sidebar order"
        )
        assertEqual(
            pageItems.map { $0.0 },
            [.today, .home, .dictations, .writing, .people, .connectAgent],
            "all six existing Go destinations keep their order"
        )
        assertEqual(
            pageItems.map { String($0.1) },
            ["1", "2", "3", "4", "5", "6"],
            "the existing Go destinations keep their numbered keys"
        )
        for (page, key, title) in pageItems {
            assertEqual(page.navigationShortcutKey, String(key), "\(page) should use the same ⌘ key in Go as in its sidebar tooltip")
            assertEqual(title, page.title, "\(page)'s Go item should use the sidebar title")
            assertEqual(page.navigationHelp, "\(page.title)  ⌘\(key)", "\(page)'s sidebar tooltip should name its Go shortcut")
        }
        assertNil(TranscriptedSettingsPage.general.navigationShortcutKey, "gear-gated Settings has no Go shortcut")
        assertEqual(TranscriptedSettingsPage.general.navigationHelp, "Settings", "a page without a shortcut shows just its title")
    }

    runSuite("App commands never shadow each other, system shortcuts, or global triggers") {
        let all = TranscriptedMenuCommandCatalog.all
        let chords = all.map { "\($0.usesShift ? "shift-" : "")\($0.key)" }
        assertEqual(Set(chords).count, chords.count, "no two app commands should share a shortcut")
        assertEqual(Set(all.map(\.title)).count, all.count, "each command title should be unique so menus stay unambiguous")
        // ⌘Q/⌘W/⌘H/⌘M/⌘C/⌘V/⌘X/⌘A/⌘Z belong to macOS and text editing.
        for reserved in ["q", "w", "h", "m", "c", "v", "x", "a", "z"] {
            assertFalse(
                all.contains { String($0.key) == reserved && !$0.usesShift },
                "⌘\(reserved.uppercased()) belongs to macOS and must not be taken by an app command"
            )
        }
        // The only modifiers are ⌘ and ⌘⇧: option and control chords are
        // how users record their own dictation and meeting triggers, so app
        // commands can't express one.
        assertTrue(
            all.allSatisfy { $0.key.isLetter || $0.key.isNumber || $0.key == "," },
            "app commands should use plain letter, digit, or comma keys"
        )
    }

    // MARK: Onboarding

    runSuite("Onboarding asks one thing per screen, then has the person dictate twice") {
        assertEqual(
            OnboardingNavigation.steps,
            [.welcome, .microphone, .accessibility, .tryIt, .tryHandsFree, .systemAudio, .promise, .done],
            "setup should ask for the mic, then paste access, then practice, then call audio, the promise and Done"
        )
        assertEqual(OnboardingNavigation.step(at: 99), .done, "a stale saved step index should land on the last step")
        assertEqual(OnboardingNavigation.step(at: 1), .microphone, "a resumed setup reopens on the microphone ask")

        let ready = OnboardingNavigation(step: .welcome, microphoneGranted: true, accessibilityGranted: true)
        var walk: [OnboardingStepKind] = [.welcome]
        var nav = ready
        while let next = nav.nextStep {
            walk.append(next)
            nav = OnboardingNavigation(
                step: next,
                microphoneGranted: true,
                accessibilityGranted: true,
                tryItDone: true,
                tryHandsFreeDone: true
            )
        }
        assertEqual(
            walk,
            [.welcome, .microphone, .accessibility, .tryIt, .tryHandsFree, .systemAudio, .promise, .done],
            "with everything granted and both takes done, setup visits every step once"
        )
    }

    runSuite("Onboarding asks for each permission with one ink button") {
        func nav(_ step: OnboardingStepKind, mic: Bool = false, blocked: Bool = false, ax: Bool = false) -> OnboardingNavigation {
            OnboardingNavigation(step: step, microphoneGranted: mic, microphoneBlocked: blocked, accessibilityGranted: ax)
        }
        assertEqual(nav(.welcome).primaryTitle, "Set up", "welcome starts setup")
        assertEqual(nav(.microphone).primaryTitle, "Allow microphone", "the mic screen's button asks macOS")
        assertEqual(nav(.microphone).primaryAction, .requestMicrophone, "the mic button starts the macOS prompt")
        assertEqual(nav(.microphone, blocked: true).primaryTitle, "Open System Settings", "after Don't Allow the button opens Settings")
        assertEqual(nav(.microphone, mic: true).primaryAction, .advance, "a granted mic moves on")
        assertEqual(nav(.accessibility).primaryTitle, "Allow paste access", "Accessibility is named by what it gives")
        assertEqual(nav(.accessibility).secondaryTitle, "Skip for now", "paste access can be skipped")
        assertEqual(nav(.accessibility, ax: true).primaryTitle, "Continue", "granted paste access moves on")
        assertNil(nav(.accessibility, ax: true).secondaryTitle, "nothing to skip once granted")

        var audio = OnboardingNavigation(step: .systemAudio)
        assertEqual(audio.primaryTitle, "Allow call audio", "call audio asks in plain words")
        assertEqual(audio.secondaryTitle, "Skip for now", "call audio is optional")
        assertEqual(audio.progressLabel, "Optional", "call audio says it's optional")
        audio.systemAudioActionTitle = "Check"
        assertEqual(audio.primaryTitle, "Check again", "an unverified check offers another check")
        audio.systemAudioChecking = true
        assertTrue(audio.primaryDisabled, "no second check while one runs")
        assertEqual(audio.secondaryAction, .skip, "Skip stays while a check runs, so a slow check never holds setup")
        audio.systemAudioVerified = true
        audio.systemAudioChecking = false
        assertEqual(audio.primaryTitle, "Continue", "verified call audio moves on")
    }

    runSuite("Onboarding practice needs a real take, with a way out") {
        let waiting = OnboardingNavigation(step: .tryIt, microphoneGranted: true, accessibilityGranted: true)
        assertTrue(waiting.primaryDisabled, "Continue waits for the first take to land")
        assertEqual(waiting.secondaryTitle, "Skip", "nobody is stuck on practice")
        assertEqual(waiting.secondaryAction, .skip, "Skip moves on")
        assertEqual(waiting.nextStep, .systemAudio, "skipping the first take skips the hands-free one too")

        let landed = OnboardingNavigation(step: .tryIt, microphoneGranted: true, accessibilityGranted: true, tryItDone: true)
        assertFalse(landed.primaryDisabled, "a landed take unlocks Continue")
        assertNil(landed.secondaryTitle, "no skip once it worked")
        assertEqual(landed.nextStep, .tryHandsFree, "Hold or tap gets a second, hands-free take")

        let holdOnly = OnboardingNavigation(
            step: .tryIt, microphoneGranted: true, accessibilityGranted: true, keyBehavior: .holdOnly, tryItDone: true
        )
        assertEqual(holdOnly.nextStep, .systemAudio, "Hold only has no hands-free take")

        let noPaste = OnboardingNavigation(step: .tryIt, microphoneGranted: true)
        assertEqual(noPaste.primaryAction, .requestAccessibility, "without paste access the key can't work, so practice asks for it")
        assertFalse(noPaste.primaryDisabled, "the paste access ask is always clickable")

        let keyOff = OnboardingNavigation(step: .accessibility, microphoneGranted: true, accessibilityGranted: true, dictationKeyEnabled: false)
        assertEqual(keyOff.nextStep, .systemAudio, "with the dictation key off there is nothing to practice")

        assertEqual(
            OnboardingNavigation(step: .microphone, microphoneGranted: true).progressLabel,
            "Step 1 of 4",
            "the asks and takes count up to four"
        )
        assertEqual(
            OnboardingNavigation(step: .tryIt, microphoneGranted: true, keyBehavior: .tapToToggle).progressLabel,
            "Step 3 of 3",
            "tap to toggle has one take"
        )
    }

    runSuite("Onboarding gates Done on the microphone and offers a skip once it's blocked") {
        func nav(_ step: OnboardingStepKind, granted: Bool = false, blocked: Bool = false, skipped: Bool = false) -> OnboardingNavigation {
            OnboardingNavigation(step: step, microphoneGranted: granted, microphoneBlocked: blocked, skippedMicrophone: skipped)
        }
        assertTrue(nav(.done).primaryDisabled, "done can't finish without the microphone or a skip")
        assertFalse(nav(.done, granted: true).primaryDisabled, "done finishes with the microphone")
        assertFalse(nav(.done, skipped: true).primaryDisabled, "done finishes after the person skipped a blocked microphone")
        assertEqual(nav(.done, granted: true).primaryTitle, "Done", "the last button says Done")
        assertEqual(nav(.done, granted: true).primaryAction, .finish, "Done finishes setup")
        assertNil(nav(.microphone, granted: false, blocked: false).secondaryTitle, "macOS can still ask, so no skip yet")
        assertEqual(nav(.microphone, granted: false, blocked: true).secondaryTitle, "Skip for now", "after Don't Allow, setup offers a skip instead of a dead end")
        assertEqual(nav(.microphone, granted: false, blocked: true).secondaryAction, .skipMicrophone, "that skip goes without the mic")
        assertNil(nav(.microphone, granted: true, blocked: true).secondaryTitle, "a granted microphone needs no skip")
        assertFalse(nav(.microphone, granted: true, blocked: true).canSkipMicrophone, "a granted microphone can't be skipped")
        assertEqual(nav(.done, skipped: true).previousStep, .promise, "after a mic skip, Back goes to the promise")
        assertFalse(nav(.promise, skipped: true).isShown(.tryIt), "no practice without the microphone")
        assertFalse(nav(.promise, skipped: true).isShown(.accessibility), "a mic skip leaves the other asks too")
    }

    // MARK: Failure copy

    runSuite("Agent and Settings failures speak plain words behind a Copy Details reveal") {
        assertEqual(AgentSetupFailureCopy.detailsTitle, "Copy Details", "the raw error goes behind Copy Details")
        assertEqual(SettingsActionFailureCopy.detailsTitle, "Copy Details", "the raw error goes behind Copy Details")
        let connect = AgentSetupFailureCopy.connect(agentName: "Claude Desktop")
        assertTrue(connect.hasPrefix("Transcripted couldn't connect Claude Desktop."), "connect failures name the agent")
        assertTrue(connect.contains("try Connect again"), "connect failures say what to try")
        let migration = SettingsActionFailureCopy.captureLibraryMigration(currentLibraryPath: "~/Transcripted")
        assertTrue(migration.contains("still in ~/Transcripted"), "a stopped library copy says where the captures still are")
        let messages = [
            connect,
            AgentSetupFailureCopy.codexInbox,
            SettingsActionFailureCopy.modelCacheRemoval,
            SettingsActionFailureCopy.launchAtLogin,
            SettingsActionFailureCopy.launchAtLoginUnavailable,
            migration,
        ]
        for message in messages {
            assertFalse(message.contains("!"), "failure copy stays calm: \(message)")
            assertFalse(message.contains("NSError") || message.contains("Error Domain"), "failure copy never shows a raw error: \(message)")
            assertTrue(message.hasSuffix("."), "failure copy is whole sentences: \(message)")
        }
    }

    runSuite("A failed Agent setup shows plain words and keeps the raw error for Copy Details only") {
        let raw = NSError(
            domain: "AgentMCPConnector",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "config.json: permission denied (raw-detail-7)"]
        )
        let connect = AgentSetupFailureCopy.connectFailure(agentName: "Claude Desktop", error: raw)
        assertEqual(connect.message, AgentSetupFailureCopy.connect(agentName: "Claude Desktop"), "the page should show the plain connect copy")
        assertFalse(connect.message.contains("raw-detail-7"), "the raw error must not reach the visible message")
        assertEqual(connect.details, raw.localizedDescription, "Copy Details should carry the raw error")

        let inbox = AgentSetupFailureCopy.codexInboxFailure(error: raw)
        assertEqual(inbox.message, AgentSetupFailureCopy.codexInbox, "the inbox row should show the plain inbox copy")
        assertFalse(inbox.message.contains("raw-detail-7"), "the raw error must not reach the visible message")
        assertEqual(inbox.details, raw.localizedDescription, "Copy Details should carry the raw error")
    }

    // MARK: Retained audio

    runSuite("Retained-audio playback follows a WAV that was recompressed to M4A") {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-surface-playback-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorded = folder.appendingPathComponent("system_audio.wav")
        let onDisk = folder.appendingPathComponent("system_audio.m4a")
        FileManager.default.createFile(atPath: onDisk.path, contents: Data([0x00]))
        assertEqual(
            MeetingAudioPlaybackLoadingPolicy.playableURL(for: recorded).lastPathComponent,
            onDisk.lastPathComponent,
            "playback should load the M4A the WAV became, not go Unavailable on the stale path"
        )
        let present = folder.appendingPathComponent("microphone.wav")
        FileManager.default.createFile(atPath: present.path, contents: Data([0x00]))
        assertEqual(MeetingAudioPlaybackLoadingPolicy.playableURL(for: present).lastPathComponent, "microphone.wav", "a file that's still there plays as is")
    }
}

private struct LaunchSmokeRowExpectation {
    let key: String
    let title: String
    let identifier: String
}

/// The `"key": ("Title", "transcripted....")` rows build.sh's launch smoke
/// checks in the app's menu bar report.
private func launchSmokeRowExpectations(in script: String) -> [LaunchSmokeRowExpectation] {
    guard let regex = try? NSRegularExpression(
        pattern: "\"([A-Za-z]+)\": \\(\"([^\"]+)\", \"(transcripted\\.[a-z0-9.-]+)\"\\)"
    ) else { return [] }
    let range = NSRange(script.startIndex..., in: script)
    return regex.matches(in: script, range: range).compactMap { match in
        guard let key = Range(match.range(at: 1), in: script),
              let title = Range(match.range(at: 2), in: script),
              let identifier = Range(match.range(at: 3), in: script) else { return nil }
        return LaunchSmokeRowExpectation(key: String(script[key]), title: String(script[title]), identifier: String(script[identifier]))
    }
}
