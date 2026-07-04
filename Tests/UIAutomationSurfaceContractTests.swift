// Repo-structure / contract suite, not behavioral coverage.
// It asserts that menubar sources keep their stable AX identifiers and that
// the smoke script still references them, so external UI automation stays in sync.
// It runs no UI and exercises no runtime behavior; it only greps source text.
//
// Adding a new contract guard is purely additive: call `contractSource("Sources/.../X.swift")`
// inline inside an assertion. Do NOT reintroduce a top-of-suite block of
// `let xSource = readUIAutomationContractFile(...)` declarations — that append-only
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
    let contents = readUIAutomationContractFile(relativePath)
    uiAutomationContractSourceCache[relativePath] = contents
    return contents
}

func testUIAutomationSurfaceContract() {
    runSuite("UI automation surface contract - menubar controls expose stable identifiers") {
        assertTrue(
            contractSource("Sources/TranscriptedApp.swift").contains("transcripted.status-item.button")
                && contractSource("Sources/TranscriptedApp.swift").contains("setAccessibilityIdentifier(\"transcripted.status-item.button\")"),
            "the real menu bar status item should expose a stable AX identifier for external UI automation"
        )

        assertTrue(
            contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("let automationIdentifier: String")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("setAutomationIdentifier(_ rawValue: String)")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("setAccessibilityIdentifier(rawValue)")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("setAccessibilityRole(.button)")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("setAccessibilityLabel(title)")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("override func accessibilityPerformPress()")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("guard isEnabled else { return false }")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("accessibilityIdentifier()"),
            "menubar smoke snapshots should carry the same accessibility identifier and AXPress path AppKit automation sees"
        )

        assertTrue(
            contractSource("Sources/UI/MenuBar/MenuTokens.swift").contains("static let minimumHitTargetSize: CGFloat = 40")
                && contractSource("Sources/UI/MenuBar/MenuTokens.swift").contains("static let panelHeight: CGFloat = 480")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("MenuTokens.minimumHitTargetSize")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("MenuTokens.utilityActionRowHeight")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("MenuTokens.compactActionRowHeight"),
            "menubar action rows should keep a real 40pt hit-target floor and a panel height that keeps default rows visible"
        )

        for identifier in [
            "transcripted.menubar.primary.home",
            "transcripted.menubar.primary.start-dictation",
            "transcripted.menubar.primary.start-meeting",
            "transcripted.menubar.primary.paste-last-dictation",
            "transcripted.menubar.primary.recent-meetings",
        ] {
            assertTrue(
                contractSource("Sources/UI/MenuBar/MenuBarPrimaryActionsView.swift").contains(identifier)
                    && contractSource("scripts/entrypoints/build.sh").contains(identifier),
                "\(identifier) should be attached in source and enforced by launch smoke"
            )
        }

        for identifier in [
            "transcripted.menubar.utility.connect-agent",
            "transcripted.menubar.utility.submit-feedback",
            "transcripted.menubar.utility.check-updates",
            "transcripted.menubar.utility.settings",
            "transcripted.menubar.utility.quit",
        ] {
            assertTrue(
                contractSource("Sources/UI/MenuBar/MenuBarUtilityActionsView.swift").contains(identifier)
                    && contractSource("scripts/entrypoints/build.sh").contains(identifier),
                "\(identifier) should be attached in source and enforced by launch smoke"
            )
        }

    }

    runSuite("UI automation surface contract - menubar controls keep polished hit targets") {
        assertTrue(
            contractSource("Sources/UI/MenuBar/MenuTokens.swift").contains("minimumHitTargetSize: CGFloat = 40")
                && contractSource("Sources/UI/MenuBar/MenuBarActionRowView.swift").contains("MenuTokens.minimumHitTargetSize"),
            "menubar rows should stay at or above the 40px minimum hit target"
        )
    }

    runSuite("UI automation surface contract - app commands expose capture shortcuts") {
        for requiredCommandHook in [
            "CommandMenu(\"Capture\")",
            "Button(\"Start Dictation\")",
            "appDelegate.menuStartDictation()",
            ".keyboardShortcut(\"d\", modifiers: .command)",
            "Button(\"Start / Stop Meeting Recording\")",
            "appDelegate.menuToggleMeetingRecording()",
            ".keyboardShortcut(\"r\", modifiers: .command)",
            "Button(\"Transcribe Audio File",
            "appDelegate.menuImportAudio()",
            ".keyboardShortcut(\"o\", modifiers: .command)",
        ] {
            assertTrue(contractSource("Sources/TranscriptedMenuCommands.swift").contains(requiredCommandHook), "\(requiredCommandHook) should stay pinned in the app command menu")
        }
    }

    runSuite("UI automation surface contract - app commands expose primary Go shortcuts") {
        for requiredCommandHook in [
            "CommandMenu(\"Go\")",
            "Button(\"Home\")",
            "appDelegate.menuOpenPage(.home)",
            ".keyboardShortcut(\"1\", modifiers: .command)",
            "Button(\"Dictations\")",
            "appDelegate.menuOpenPage(.dictations)",
            ".keyboardShortcut(\"2\", modifiers: .command)",
            "Button(\"Speakers\")",
            "appDelegate.menuOpenPage(.people)",
            ".keyboardShortcut(\"3\", modifiers: .command)",
            "Button(\"Agent\")",
            "appDelegate.menuOpenPage(.connectAgent)",
            ".keyboardShortcut(\"4\", modifiers: .command)",
            "Button(\"Find Speaker",
            "appDelegate.menuFindSpeaker()",
            ".keyboardShortcut(\"f\", modifiers: .command)",
        ] {
            assertTrue(contractSource("Sources/TranscriptedMenuCommands.swift").contains(requiredCommandHook), "\(requiredCommandHook) should stay pinned in the Go command menu")
        }

        for requiredPageHook in [
            "case .home: return \"1\"",
            "case .dictations: return \"2\"",
            "case .people: return \"3\"",
            "case .connectAgent: return \"4\"",
            "return \"\\(title)  ⌘\\(key)\"",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/TranscriptedSettingsPage.swift").contains(requiredPageHook), "\(requiredPageHook) should keep sidebar help aligned with Go shortcuts")
        }
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

    runSuite("UI automation surface contract - app commands do not remap global trigger preferences") {
        for forbiddenTriggerHook in [
            "PhysicalDictationTriggerPreferences",
            "HotkeyPreferences",
            "RegisterEventHotKey",
            "pushToTalk",
            "handsFree",
            ".keyboardShortcut(\"m\"",
            "modifiers: .option",
            "modifiers: [.option",
            "modifiers: .control",
            "modifiers: [.control",
        ] {
            assertFalse(
                contractSource("Sources/TranscriptedMenuCommands.swift").contains(forbiddenTriggerHook),
                "app-active commands must not remap or shadow global recordable trigger preferences (\(forbiddenTriggerHook))"
            )
        }
    }

    runSuite("UI automation surface contract - major settings and Home flows stay mapped") {
        for pageCase in [
            "case home",
            "case dictations",
            "case general",
            "case models",
            "case shortcuts",
            "case people",
            "case storage",
            "case connectAgent",
            "case beta",
            "case privacy",
            "case support",
            "case about",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/TranscriptedSettingsPage.swift").contains(pageCase), "\(pageCase) should stay in the settings navigation surface map")
        }

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsPage.swift").contains("var automationIdentifier: String")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsSidebar.swift").contains(".accessibilityIdentifier(page.automationIdentifier)"),
            "settings sidebar pages should expose stable automation identifiers"
        )

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
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("Label(\"Add correction\", systemImage: \"plus\")")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(".frame(minHeight: 40)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"),
            "custom dictionary add correction should keep a 40pt tactile action target"
        )

        for requiredSourceHook in [
            "title: \"Transcribe audio file\"",
            "actions.importAudioFile()",
            "title: \"AI meeting summaries\"",
            "title: \"Live meeting sidecar\"",
            "trackSettingsToggle(\"local_ai_meeting_summaries\"",
            "trackSettingsToggle(\"live_meeting_sidecar\"",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(requiredSourceHook), "\(requiredSourceHook) should stay source-addressable")
        }

        for requiredHomeActionHook in [
            "HomeRowMenuItem(title: \"Open Markdown\"",
            "HomeRowMenuItem(title: \"Report issue\"",
            "HomeRowMenuItem(title: \"Delete meeting\"",
            "HomeDeleteConfirmationPolicy.failedMeeting",
            "homeDeleteConfirmation = HomeDeleteConfirmation(",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(requiredHomeActionHook), "\(requiredHomeActionHook) should keep Home action coverage visible")
        }
        assertFalse(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("presentFailedMeetingDeleteConfirmation("),
            "failed-meeting delete confirmation should use SwiftUI alert state instead of a hand-built NSAlert"
        )

        for requiredHomeRendererHook in [
            "title: presentation.clearTitle",
            "SettingsInlineActionButton(",
            "tone: presentation.clearIsDestructive ? .destructive : .neutral",
            "HomeRowMoreMenuButton(items:",
            "retainedActionTarget = context.coordinator",
            "final class ClosureMenuItem: NSMenuItem",
            "ClosureMenuItem(menuItem: item)",
            "title: \"Copy for agent\"",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/HomeView.swift").contains(requiredHomeRendererHook), "\(requiredHomeRendererHook) should keep Home action rendering visible")
        }
        assertTrue(
            contractSource("Sources/UI/Settings/HomeView.swift").contains("private enum HomeHitTarget")
                && contractSource("Sources/UI/Settings/HomeView.swift").contains("static let minimum: CGFloat = 40")
                && contractSource("Sources/UI/Settings/HomeView.swift").contains("HomeHitTarget.minimum"),
            "Home icon buttons and compact row actions should keep a shared 40pt hit-target floor"
        )
        for requiredFailedMeetingPolicyHook in [
            "clearTitle: hasRetainedAudioFiles ? \"Delete\" : \"Dismiss\"",
            "clearSymbolName: hasRetainedAudioFiles ? \"trash\" : \"xmark\"",
            "clearIsDestructive: hasRetainedAudioFiles",
            "return \"This meeting does not have enough saved audio to retry.\"",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/FailedMeetingRecoveryPresentation.swift").contains(requiredFailedMeetingPolicyHook), "\(requiredFailedMeetingPolicyHook) should keep failed-meeting action policy visible")
        }
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".frame(minHeight: 40)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"),
            "shared inline settings actions should keep a 40pt hit floor for failed-meeting recovery controls"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/HomeView.swift").contains(".frame(minHeight: 40, alignment: .leading)")
                && contractSource("Sources/UI/Settings/HomeView.swift").contains(".accessibilityIdentifier(\"transcripted.home.audio.inline-toggle\")"),
            "Home retained-audio play controls should keep a 40pt hit floor"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsRows.swift").contains(".frame(minHeight: 40, alignment: .leading)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsRows.swift").contains("struct SettingsRecentMeetingAudioControl"),
            "Settings retained-audio play controls should keep a 40pt hit floor"
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
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".frame(width: 40, height: 40)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".accessibilityIdentifier(\"transcripted.settings.activity-card.dismiss\")")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".frame(minHeight: 40)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"),
            "activity cards should keep 40pt action and dismiss hit targets for Home progress/notice cards"
        )

        // Regression guards for fix/home-delete-confirmation-menu-loop. The Home
        // recent-meeting "Delete meeting" confirmation silently no-op'd because of
        // two stacked defects the fast suite cannot exercise at runtime:
        //   1. Row-menu handlers fired synchronously inside NSMenu.popUp's modal
        //      tracking loop, so the SwiftUI alert they set never presented.
        //      ClosureMenuItem must hop to the next main-runloop turn.
        //   2. Three legacy `.alert(item:)` modifiers were stacked on the settings
        //      root view; SwiftUI keeps only the last, shadowing the (first)
        //      delete confirmation. The three states must share one presenter.
        assertTrue(
            contractSource("Sources/UI/Settings/HomeView.swift").contains("DispatchQueue.main.async { [handler] in handler() }"),
            "ClosureMenuItem should defer its handler off the NSMenu.popUp tracking loop so menu-triggered SwiftUI alerts/sheets present"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(".alert(item: rootAlertBinding)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("enum RootAlert")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("case deleteConfirmation")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("case deleteFailure")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("case audioRetention"),
            "the Home delete, delete-failure, and audio-retention alerts should present through one rootAlertBinding so none is shadowed"
        )
        assertFalse(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(".alert(item: $homeDeleteConfirmation)")
                || contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(".alert(item: $homeDeleteFailure)")
                || contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(".alert(item: $pendingAudioRetentionWindow)"),
            "Home alerts must not be re-stacked as separate `.alert(item:)` modifiers — stacked legacy alerts shadow all but the last"
        )
        // The shared binding must dismiss only the active alert via
        // HomeRootAlertPolicy, never clear all three. A confirm action can raise
        // a follow-up failure alert before SwiftUI writes nil; clearing
        // everything would wipe it before it presents. (HomeRootAlertPolicyTests
        // covers the priority/dismissal behavior directly.)
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("HomeRootAlertPolicy.activeSlot")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("switch activeRootAlert"),
            "the shared alert binding should clear only the dismissed alert through HomeRootAlertPolicy, not reset all three states"
        )

        // Own-file resolution contract (hardening/home-meeting-own-file-resolver).
        // Every Home/meeting control that touches an app-owned file (transcript,
        // audio, summary) must route through OwnFileResolver so a path that drifted
        // after scanning (restyle/rename, WAV→M4A recompression, deletion) surfaces
        // an error instead of a silent dead click. Behavior is covered by
        // OwnFileResolverTests; these guard the wiring so a regression that re-adds a
        // raw stale-path call (the #1126/#1131/#1134 whack-a-mole) fails CI.
        assertTrue(
            contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("static func resolveForReveal(")
                && contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("static func resolveExistingFile(")
                && contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("static func resolveExistingFiles(")
                && contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("case reveal([URL])")
                && contractSource("Sources/UI/Shared/OwnFileResolver.swift").contains("case unavailable"),
            "OwnFileResolver must keep both reveal (with enclosing-folder fallback) and open/play (regular-file-only) resolution modes"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("private func revealOwnFile(")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("OwnFileResolver.resolveForReveal(candidateURLs:")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("private func openOwnFile(")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("OwnFileResolver.resolveExistingFile(candidateURLs:"),
            "Home reveal/open should route through OwnFileResolver helpers, surfacing presentHomeActionFailure on .unavailable instead of a dead click"
        )

        let settingsSource = contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let copyMeetingBlock = sourceBlock(
            named: "private func handleCopyMeeting(_ item: RecentMeetingItem)",
            endingBefore: "    private func handleCopyMeetingPreview(",
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

        let copyPreviewBlock = sourceBlock(
            named: "private func handleCopyMeetingPreview(_ preview: HomeMeetingPreview)",
            endingBefore: "    private func handleRetranscribeMeeting(",
            in: settingsSource
        )
        assertFalse(
            copyPreviewBlock.contains(
                "trackSettingsAction(\"copy_meeting_preview\", page: .home)\n        ActivationTelemetry.trackHabitLoopAction"
            ),
            "preview copy telemetry must not emit habit-loop success before bundle/markdown text exists"
        )
        assertEqual(
            countOccurrences(of: "ActivationTelemetry.trackHabitLoopAction(", in: copyPreviewBlock),
            2,
            "preview copy should track habit-loop exactly on no-text failure or success"
        )

        let previewBlock = sourceBlock(
            named: "private func presentHomeMeetingPreview(_ item: RecentMeetingItem)",
            endingBefore: "    private static func readMeetingMarkdown(",
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
                contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(staleRawCall),
                "Home own-file action must not call NSWorkspace on a raw scan-time URL (\(staleRawCall)) — route it through OwnFileResolver"
            )
        }

        // Copy/export and re-transcribe must surface a failure, not a silent beep,
        // when the source file cannot be resolved.
        assertFalse(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("NSWorkspace.shared.activateFileViewerSelecting(audioRevealURLs)"),
            "failed-meeting reveal audio must route through OwnFileResolver, not beep-or-reveal on raw URLs"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("Could not copy meeting")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("Could not re-transcribe meeting"),
            "copy-for-agent and re-transcribe should surface a failure alert when the own file is missing, instead of NSSound.beep()"
        )

        // Local AI meeting summary must resolve the transcript before reading it,
        // same as copy/open/re-transcribe (FIX_ROADMAP "Local AI summary path
        // skips OwnFileResolver") — a raw scan-time URL surfaces an ugly read
        // error instead of the friendly "Could not summarize meeting" alert when
        // the file drifted (restyle/preview rename) since the row was scanned.
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("private func generateLocalSummary(")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(
                    "guard let resolvedTranscriptURL = OwnFileResolver.resolveExistingFile(candidateURLs: [transcriptURL])"
                ),
            "generateLocalSummary should resolve the transcript through OwnFileResolver before summarizing, not read the raw scan-time URL"
        )
        assertFalse(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(
                "LocalMeetingSummarizer().summarize(\n                    transcriptURL: transcriptURL,"
            ),
            "the local summary provider dispatch must hand the OwnFileResolver-resolved URL to LocalMeetingSummarizer, not the raw unresolved transcriptURL"
        )
        assertFalse(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(
                "AppleFoundationMeetingSummarizer().summarize(\n                    transcriptURL: transcriptURL,"
            ),
            "the local summary provider dispatch must hand the OwnFileResolver-resolved URL to AppleFoundationMeetingSummarizer, not the raw unresolved transcriptURL"
        )

        // Retained-audio playback follows recompressed/moved files instead of going
        // silently Unavailable on a stale path.
        assertTrue(
            contractSource("Sources/UI/Shared/MeetingAudioPlayback.swift").contains("OwnFileResolver.resolveExistingFile(candidateURLs:"),
            "meeting audio playback should resolve each source URL through OwnFileResolver so WAV→M4A recompression still plays"
        )

        // Delete must surface a failure when it removed nothing yet the file is
        // still on disk (stale path), instead of letting the row reappear
        // unexplained. Deletion intentionally does not use the lenient resolver.
        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("result.removedTranscriptURLs.isEmpty")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("FileManager.default.fileExists(atPath: item.transcriptURL.path)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("presentHomeActionFailure("),
            "deleteMeeting should detect a no-op delete (stale path) and surface a failure rather than silently re-showing the row"
        )

        // Row-interaction affordances from fix/home-row-actions, which have no
        // behavioral coverage in the fast suite (it greps source, never runs the
        // UI). The overflow actions only reveal on hover, so the row needs a
        // full-width hit shape (its idle background is Color.clear) and the
        // canvas-header action button must not draw a focus ring.
        assertTrue(
            contractSource("Sources/UI/Settings/HomeView.swift").contains(".focusEffectDisabled()"),
            "the Home canvas-header action button should keep .focusEffectDisabled() so it draws no focus ring"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/HomeView.swift").contains("across the full row.\n        .contentShape(Rectangle())"),
            "recent-capture rows should keep their full-width .contentShape(Rectangle()) so hover reveals row actions everywhere, not only over the title text"
        )

        for requiredOnboardingHook in [
            "Enable system audio",
            "Allow calendar access",
            "Skip for now",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains(requiredOnboardingHook), "\(requiredOnboardingHook) should stay in onboarding automation scope")
        }

        // Auto-detect calls is default-on (AutoCallDetectionPreferences) but onboarding
        // used to teach only the manual menu-bar path and frame detection as
        // calendar-only. These guard the copy fix: the meetingStart step should prime
        // users that Transcripted notices a call starting in any app/browser using the
        // mic and asks once, and the calendar step should frame calendar access as an
        // addition to that always-on detection rather than the only way calls get noticed.
        assertTrue(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("Transcripted notices")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("when a call starts.")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("no calendar invite required")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("Works with any call, calendar invite or not"),
            "the meetingStart onboarding step should teach auto-detect calls instead of only the manual menu-bar path"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("already notices when a call starts")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("Calendar reminders"),
            "the calendar onboarding step should frame calendar access as an addition to always-on call detection, not the only way calls get noticed"
        )

        for identifier in [
            "transcripted.speaker-review.save-names",
            "transcripted.speaker-review.review-later",
            "transcripted.speaker-review.keep-local-mic-as-you",
            "transcripted.speaker-review.row.name",
            "transcripted.speaker-review.row.play-sample",
            "transcripted.speaker-review.row.confirm-match",
            "transcripted.speaker-review.row.discard-voice",
        ] {
            assertTrue(
                contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains(identifier),
                "\(identifier) should keep speaker review scriptable without using speaker names"
            )
        }
        assertTrue(
            contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains("static let minimum: CGFloat = 40")
                && contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains("let btnH = SpeakerNamingHitTargets.minimum")
                && contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains("let fieldH = SpeakerNamingHitTargets.minimum")
                && contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains("let hitTarget = SpeakerNamingHitTargets.minimum"),
            "speaker review save/cancel/name/play/confirm/discard controls should keep a 40pt hit floor"
        )
        assertTrue(
            contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains("static let sectionHeaderHeight: CGFloat = 40")
                && contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains("let headerHeight = SpeakerNamingHitTargets.sectionHeaderHeight")
                && contractSource("Sources/UI/Settings/SpeakerNamingSheet.swift").contains("keepAsYouButton.frame = NSRect("),
            "speaker review Keep Local Mic as You should keep a 40pt section-header hit floor"
        )

        for requiredAgentHook in [
            "transcripted.settings.agent.connect.\\(agent.rawValue)",
            "transcripted.settings.agent.copy-prompt",
            "transcripted.settings.agent.copy-folder-paths",
            "transcripted.settings.agent.codex-inbox",
            "transcripted.settings.agent.open-live-view",
            "Copy Paths",
            "Live meetings",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/AgentConnectionSettingsPage.swift").contains(requiredAgentHook), "\(requiredAgentHook) should stay in agent/connect automation scope")
        }

        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingLiveViewAffordancePolicy.swift").contains("transcripted.meeting-overlay.live-view")
                && contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("setAccessibilityIdentifier(MeetingLiveViewAffordancePolicy.automationIdentifier)"),
            "the recording pill body should keep a stable automation identifier for the transcript toggle"
        )
        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingLiveViewAffordancePolicy.swift").contains("transcripted.meeting-overlay.live-view.copy")
                && contractSource("Sources/UI/Overlay/MeetingLiveTranscriptDrawerView.swift").contains("MeetingLiveViewAffordancePolicy.copyAutomationIdentifier"),
            "the transcript drawer's copy action should keep a stable automation identifier"
        )
        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingLiveViewAffordancePolicy.swift").contains("transcripted.meeting-overlay.live-view.more")
                && contractSource("Sources/UI/Overlay/MeetingLiveTranscriptDrawerView.swift").contains("MeetingLiveViewAffordancePolicy.moreAutomationIdentifier"),
            "the transcript drawer's overflow menu should keep a stable automation identifier"
        )
        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("MeetingLiveViewAffordancePolicy.discardRecordingMenuTitle")
                && contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("MeetingLiveViewAffordancePolicy.keepControlsVisibleMenuTitle")
                && contractSource("Sources/UI/Overlay/MeetingLiveTranscriptDrawerView.swift").contains("MeetingLiveViewAffordancePolicy.openInBrowserMenuTitle"),
            "pill context-menu and drawer overflow actions should keep policy-pinned titles for automation"
        )
        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingLiveTranscriptDrawerView.swift").contains("transientStatusText ?? statusText")
                && contractSource("Sources/UI/Overlay/MeetingLiveTranscriptDrawerView.swift").contains("openInBrowserFailedStatus")
                && contractSource("Sources/UI/Overlay/MeetingLiveTranscriptDrawerView.swift").contains(".announcement: MeetingLiveViewAffordancePolicy.openInBrowserFailedStatus"),
            "browser-open failures should remain visible and announced even while transcript updates continue"
        )
        assertTrue(
            contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("showLiveViewBrowserOpenFailure")
                && contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("isTranscriptExpanded = true")
                && contractSource("Sources/UI/Overlay/MeetingOverlayController.swift").contains("rootView?.flashTranscriptBrowserOpenFailure()"),
            "browser-open failures from the collapsed pill menu should reveal the drawer before showing feedback"
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
                && contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains("transcripted.settings.general.dictation-window.options")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains("transcripted.settings.general.dictation-window.\\(mode.rawValue)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift").contains("transcripted.settings.general.info.\\(automationSlug(info.title))"),
            "general settings controls should keep scriptable row and choice IDs"
        )
    }

    runSuite("UI automation surface contract - deterministic click-flow identifiers stay mapped") {
        for identifier in [
            "transcripted.home.stats.view",
            "transcripted.home.stats.done",
            "transcripted.home.row.copy",
            "transcripted.home.row.more",
            "transcripted.home.dictation.open-markdown",
            "transcripted.home.dictation.expand",
            "transcripted.home.meeting.preview",
            "transcripted.home.meeting-preview.open-markdown",
            "transcripted.home.meeting-preview.copy-for-agent",
            "transcripted.home.meeting-preview.report-issue",
            "transcripted.home.meeting-preview.audio.skip-back",
            "transcripted.home.meeting-preview.audio.toggle",
            "transcripted.home.meeting-preview.audio.skip-forward",
            "transcripted.home.audio.inline-toggle",
            "transcripted.home.failed-meeting.show-audio",
            "transcripted.home.failed-meeting.retry",
            "transcripted.home.failed-meeting.more",
            "transcripted.home.failed-meetings.show-all",
            "transcripted.home.failed-meetings.retry",
            "transcripted.home.failed-meetings.show-audio",
            "transcripted.home.failed-meetings.delete",
            "transcripted.home.failed-meetings.dismiss",
            "transcripted.home.load-more",
            "transcripted.home.needs-attention.review.",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/HomeView.swift").contains(identifier), "\(identifier) should stay attached to Home click-flow controls")
        }

        for identifier in [
            "transcripted.settings.footer.check-updates",
            "transcripted.settings.general.launch-at-login",
            "transcripted.settings.general.show-in-dock",
            "transcripted.settings.general.dictation-sounds",
            "transcripted.settings.general.cleanup-pasted-text",
            "transcripted.settings.general.confirm-meeting-quits",
            "transcripted.settings.general.disclosure.transcription-model",
            "transcripted.settings.general.disclosure.keyboard-shortcuts",
            "transcripted.settings.general.disclosure.privacy",
            "transcripted.settings.general.disclosure.corrections",
            "transcripted.settings.general.transcribe-audio-file",
            "transcripted.settings.general.send-test-sentry-event",
            "transcripted.settings.general.corrections.clear-all",
            "transcripted.settings.beta.ai-meeting-summaries",
            "transcripted.settings.beta.live-meeting-sidecar",
            "transcripted.settings.beta.local-summary.check-setup",
            "transcripted.settings.beta.local-summary.install-uv",
            "transcripted.settings.beta.open-agent-setup",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains(identifier), "\(identifier) should stay attached to Settings click-flow controls")
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
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("static let minimumHitTarget: CGFloat = 40")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("static let playButtonVisibleDiameter: CGFloat = 36")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains("static let compactIconVisibleDiameter: CGFloat = 28")
                && contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains(".contentShape(Rectangle())"),
            "speaker settings should pin compact icon chrome separately from the 40pt hit shape"
        )

        let speakerCompactIconLabelApplications = contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift")
            .components(separatedBy: "SpeakerCompactIconLabel(")
            .count - 1
        assertTrue(
            speakerCompactIconLabelApplications >= 4,
            "speaker refresh, all-speakers play, and overflow icon controls should use the compact 40pt hit-target label"
        )

        for identifier in [
            "transcripted.speakers.voice-to-name.play",
            "transcripted.speakers.voice-to-name.menu",
            "transcripted.speakers.refresh",
            "transcripted.speakers.person.play",
            "transcripted.speakers.person.menu",
        ] {
            assertTrue(
                contractSource("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift").contains(identifier),
                "\(identifier) should keep the speakers surface's icon-only controls scriptable without using speaker names"
            )
        }

        assertTrue(
            contractSource("Sources/UI/Settings/HomeView.swift").contains("HomeAttentionPillsRow")
                && contractSource("Sources/UI/Settings/HomeView.swift").contains(".accessibilityHint(issue.detail)")
                && contractSource("Sources/UI/Settings/HomeView.swift").contains("transcripted.home.needs-attention.review."),
            "Home attention pills should stay labeled and scriptable"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("HomeRowMenuItem(title: \"Review speakers\"")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("if !audioRevealURLs.isEmpty")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsView.swift").contains("title: \"Re-transcribe with speaker ID\""),
            "meeting speaker review and re-transcribe actions should stay reachable from the row menu when retained audio has a Finder target"
        )

        for identifier in [
            "transcripted.onboarding.nav.back",
            "transcripted.onboarding.nav.skip",
            "transcripted.onboarding.nav.primary",
            "transcripted.onboarding.dictation-test.clear",
            "transcripted.onboarding.use-case.meetings",
            "transcripted.onboarding.use-case.dictation",
            "transcripted.onboarding.permissions.microphone",
            "transcripted.onboarding.permissions.system-audio",
            "transcripted.onboarding.permissions.accessibility",
            "transcripted.onboarding.permissions.leave-dictation-shortcuts-off",
            "transcripted.onboarding.system-audio.enable",
            "transcripted.onboarding.calendar.meeting-reminders",
            "transcripted.onboarding.calendar.allow",
            "transcripted.onboarding.diagnostics.share",
            "transcripted.onboarding.agent.connect-claude-desktop",
            "transcripted.onboarding.agent.copy-local-agent-prompt",
        ] {
            assertTrue(contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains(identifier), "\(identifier) should stay attached to onboarding click-flow controls")
        }

        assertTrue(
            contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("UseCaseChoiceCard(")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcripted.onboarding.use-case.meetings")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcripted.onboarding.use-case.dictation")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("selectedStateStrokeWidth")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains(".contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))"),
            "onboarding use-case cards should keep their scriptable card-button and selected-state hooks"
        )

        assertTrue(
            contractSource("Sources/UI/Shared/FirstRunExperience.swift").contains("static let minimumHitTarget: Double = 44")
                && contractSource("Sources/UI/Shared/FirstRunExperience.swift").contains("static let modelProgressLabelMinimumWidth: Double = 104")
                && contractSource("Sources/UI/Shared/FirstRunExperience.swift").contains("static let selectedStateStrokeWidth: Double = 2")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcripted.onboarding.nav.skip")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("transcripted.onboarding.nav.primary")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains("FirstRunOnboardingPolishContract.minimumHitTarget")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains(".contentShape(Rectangle())")
                && contractSource("Sources/UI/Settings/PermissionsOnboardingView.swift").contains(".contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))"),
            "onboarding nav and compact controls should keep pinned polish constants and hit-shape hooks"
        )

        assertTrue(
            contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".monospacedDigit()")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains("modelProgressLabelMinimumWidth")
                && contractSource("Sources/UI/Settings/TranscriptedSettingsComponents.swift").contains(".accessibilityLabel(Text(status))"),
            "onboarding/local-model progress labels should stay stable, tabular, and accessible"
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
            "performPress(identifier:",
            "performPressOrClick(identifier:",
            "CGEvent(mouseEventSource:",
            "AXChildrenInNavigationOrder",
            "transcripted.status-item.button",
            "transcripted.menubar.primary.home",
            "transcripted.settings.tab.general",
            "transcripted.settings.sidebar.settings-toggle",
            "transcripted.settings.sidebar.dictations",
            "transcripted.onboarding.use-case.dictation",
            "transcripted.onboarding.permissions.system-audio",
        ] {
            assertTrue(contractSource("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/UISmoke.swift").contains(requiredHarnessHook), "\(requiredHarnessHook) should stay pinned in the UI smoke harness")
        }

        assertTrue(
            contractSource("scripts/ops/transcripted-qa-bench.sh").contains("quick|deep|full|ui|imported-audio-native|sparkle-update|packaged|artifact")
                && contractSource("scripts/ops/transcripted-qa-bench.sh").contains("run_ui_tail")
                && contractSource("scripts/ops/transcripted-qa-bench.sh").contains("transcripted-qa ui-smoke")
                && contractSource("scripts/ops/transcripted-qa-bench.sh").contains("ui-automation-smoke.json"),
            "QA bench should keep a callable ui mode with local JSON evidence"
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

private func readUIAutomationContractFile(_ relativePath: String) -> String {
    (try? String(contentsOf: repoFixtureURL(relativePath), encoding: .utf8)) ?? ""
}
