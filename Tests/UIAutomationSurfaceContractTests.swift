// Repo-structure / contract suite, not behavioral coverage.
// It asserts that menubar sources keep their stable AX identifiers and that
// the smoke script still references them, so external UI automation stays in sync.
// It runs no UI and exercises no runtime behavior; it only greps source text.

import Foundation

func testUIAutomationSurfaceContract() {
    runSuite("UI automation surface contract - menubar controls expose stable identifiers") {
        let appSource = readUIAutomationContractFile("Sources/TranscriptedApp.swift")
        let actionRowSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarActionRowView.swift")
        let primarySource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarPrimaryActionsView.swift")
        let utilitySource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarUtilityActionsView.swift")
        let smokeScript = readUIAutomationContractFile("scripts/entrypoints/build.sh")

        assertTrue(
            appSource.contains("transcripted.status-item.button")
                && appSource.contains("setAccessibilityIdentifier(\"transcripted.status-item.button\")"),
            "the real menu bar status item should expose a stable AX identifier for external UI automation"
        )

        assertTrue(
            actionRowSource.contains("let automationIdentifier: String")
                && actionRowSource.contains("setAutomationIdentifier(_ rawValue: String)")
                && actionRowSource.contains("setAccessibilityIdentifier(rawValue)")
                && actionRowSource.contains("setAccessibilityRole(.button)")
                && actionRowSource.contains("setAccessibilityLabel(title)")
                && actionRowSource.contains("override func accessibilityPerformPress()")
                && actionRowSource.contains("guard isEnabled else { return false }")
                && actionRowSource.contains("accessibilityIdentifier()"),
            "menubar smoke snapshots should carry the same accessibility identifier and AXPress path AppKit automation sees"
        )

        for identifier in [
            "transcripted.menubar.primary.home",
            "transcripted.menubar.primary.start-dictation",
            "transcripted.menubar.primary.start-meeting",
            "transcripted.menubar.primary.paste-last-dictation",
            "transcripted.menubar.primary.recent-meetings",
        ] {
            assertTrue(
                primarySource.contains(identifier) && smokeScript.contains(identifier),
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
                utilitySource.contains(identifier) && smokeScript.contains(identifier),
                "\(identifier) should be attached in source and enforced by launch smoke"
            )
        }

    }

    runSuite("UI automation surface contract - menubar controls keep polished hit targets") {
        let tokenSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuTokens.swift")
        let actionRowSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarActionRowView.swift")
        let iconButtonSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuIconButton.swift")
        let outlineButtonSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuOutlineButton.swift")
        let modelStatusSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarModelStatusView.swift")

        assertTrue(
            tokenSource.contains("minimumHitTargetSize: CGFloat = 40")
                && actionRowSource.contains("MenuTokens.minimumHitTargetSize"),
            "menubar rows should stay at or above the 40px minimum hit target"
        )

        for source in [iconButtonSource, outlineButtonSource] {
            assertTrue(
                source.contains("override func hitTest(_ point: NSPoint)")
                    && source.contains("let localPoint = convert(point, from: superview)")
                    && source.contains("minimumHitBounds.contains(localPoint)")
                    && source.contains("trackPressInMinimumHitBounds()")
                    && source.contains("NSApp.sendAction(action, to: target, from: self)")
                    && source.contains("CATransform3DMakeScale(0.96, 0.96, 1)"),
                "small menubar buttons should keep expanded hit testing and subtle 0.96 press feedback"
            )
        }

        assertTrue(
            modelStatusSource.contains("NSFont.monospacedDigitSystemFont")
                && modelStatusSource.contains("setAccessibilityRole(.button)")
                && modelStatusSource.contains("setAccessibilityValue(label.stringValue)")
                && modelStatusSource.contains("override func resetCursorRects()")
                && modelStatusSource.contains("override func accessibilityPerformPress()"),
            "menubar model status should keep tabular progress digits and a real AX button contract"
        )
    }

    runSuite("UI automation surface contract - app commands expose capture shortcuts") {
        let commandsSource = readUIAutomationContractFile("Sources/TranscriptedMenuCommands.swift")

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
            assertTrue(commandsSource.contains(requiredCommandHook), "\(requiredCommandHook) should stay pinned in the app command menu")
        }
    }

    runSuite("UI automation surface contract - app commands expose primary Go shortcuts") {
        let commandsSource = readUIAutomationContractFile("Sources/TranscriptedMenuCommands.swift")
        let pagesSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsPage.swift")

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
            assertTrue(commandsSource.contains(requiredCommandHook), "\(requiredCommandHook) should stay pinned in the Go command menu")
        }

        for requiredPageHook in [
            "case .home: return \"1\"",
            "case .dictations: return \"2\"",
            "case .people: return \"3\"",
            "case .connectAgent: return \"4\"",
            "return \"\\(title)  ⌘\\(key)\"",
        ] {
            assertTrue(pagesSource.contains(requiredPageHook), "\(requiredPageHook) should keep sidebar help aligned with Go shortcuts")
        }
    }

    runSuite("UI automation surface contract - app commands route through existing delegate entry points") {
        let appSource = readUIAutomationContractFile("Sources/TranscriptedApp.swift")

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
            assertTrue(appSource.contains(requiredAppHook), "\(requiredAppHook) should keep app commands wired through existing app-delegate actions")
        }
    }

    runSuite("UI automation surface contract - app commands do not remap global trigger preferences") {
        let commandsSource = readUIAutomationContractFile("Sources/TranscriptedMenuCommands.swift")

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
                commandsSource.contains(forbiddenTriggerHook),
                "app-active commands must not remap or shadow global recordable trigger preferences (\(forbiddenTriggerHook))"
            )
        }
    }

    runSuite("UI automation surface contract - major settings and Home flows stay mapped") {
        let pagesSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsPage.swift")
        let settingsSidebarSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsSidebar.swift")
        let settingsComponentsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsComponents.swift")
        let generalControlsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift")
        let settingsRowsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsRows.swift")
        let settingsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let homeSource = readUIAutomationContractFile("Sources/UI/Settings/HomeView.swift")
        let settingsRowsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsRows.swift")
        let meetingAudioPlaybackSource = readUIAutomationContractFile("Sources/UI/Shared/MeetingAudioPlayback.swift")
        let onboardingSource = readUIAutomationContractFile("Sources/UI/Settings/PermissionsOnboardingView.swift")
        let speakerReviewSource = readUIAutomationContractFile("Sources/UI/Settings/SpeakerNamingSheet.swift")
        let agentSettingsSource = readUIAutomationContractFile("Sources/UI/Settings/AgentConnectionSettingsPage.swift")
        let deletePolicySource = readUIAutomationContractFile("Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift")
        let failedMeetingRecoverySource = readUIAutomationContractFile("Sources/UI/Settings/FailedMeetingRecoveryPresentation.swift")

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
            assertTrue(pagesSource.contains(pageCase), "\(pageCase) should stay in the settings navigation surface map")
        }

        assertTrue(
            pagesSource.contains("var automationIdentifier: String")
                && settingsSidebarSource.contains(".accessibilityIdentifier(page.automationIdentifier)"),
            "settings sidebar pages should expose stable automation identifiers"
        )

        assertTrue(
            generalControlsSource.contains(".frame(width: 40, height: 40)")
                && generalControlsSource.contains("accessibilityIdentifier(\"transcripted.settings.general.info.\\(automationSlug(info.title))\")"),
            "General settings info buttons should keep compact visuals with a 40pt hit target and stable AX identifiers"
        )
        assertTrue(
            settingsRowsSource.contains(".frame(width: 40, height: 40)")
                && settingsRowsSource.contains(".accessibilityLabel(Text(\"Remove correction\"))"),
            "custom dictionary remove controls should keep a 40pt destructive hit target with a clear AX label"
        )
        assertTrue(
            settingsSource.contains("Label(\"Add correction\", systemImage: \"plus\")")
                && settingsSource.contains(".frame(minHeight: 40)")
                && settingsSource.contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"),
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
            assertTrue(settingsSource.contains(requiredSourceHook), "\(requiredSourceHook) should stay source-addressable")
        }

        for requiredHomeActionHook in [
            "HomeRowMenuItem(title: \"Open Markdown\"",
            "HomeRowMenuItem(title: \"Report issue\"",
            "HomeRowMenuItem(title: \"Delete meeting\"",
            "HomeDeleteConfirmationPolicy.failedMeeting",
            "homeDeleteConfirmation = HomeDeleteConfirmation(",
        ] {
            assertTrue(settingsSource.contains(requiredHomeActionHook), "\(requiredHomeActionHook) should keep Home action coverage visible")
        }
        assertFalse(
            settingsSource.contains("presentFailedMeetingDeleteConfirmation("),
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
            assertTrue(homeSource.contains(requiredHomeRendererHook), "\(requiredHomeRendererHook) should keep Home action rendering visible")
        }
        assertTrue(
            homeSource.contains("private enum HomeHitTarget")
                && homeSource.contains("static let minimum: CGFloat = 40")
                && homeSource.contains("HomeHitTarget.minimum"),
            "Home icon buttons and compact row actions should keep a shared 40pt hit-target floor"
        )
        for requiredFailedMeetingPolicyHook in [
            "clearTitle: hasRetainedAudioFiles ? \"Delete\" : \"Dismiss\"",
            "clearSymbolName: hasRetainedAudioFiles ? \"trash\" : \"xmark\"",
            "clearIsDestructive: hasRetainedAudioFiles",
            "return \"This meeting does not have enough saved audio to retry.\"",
        ] {
            assertTrue(failedMeetingRecoverySource.contains(requiredFailedMeetingPolicyHook), "\(requiredFailedMeetingPolicyHook) should keep failed-meeting action policy visible")
        }
        assertTrue(
            settingsComponentsSource.contains(".frame(minHeight: 40)")
                && settingsComponentsSource.contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"),
            "shared inline settings actions should keep a 40pt hit floor for failed-meeting recovery controls"
        )
        assertTrue(
            homeSource.contains(".frame(minHeight: 40, alignment: .leading)")
                && homeSource.contains(".accessibilityIdentifier(\"transcripted.home.audio.inline-toggle\")"),
            "Home retained-audio play controls should keep a 40pt hit floor"
        )
        assertTrue(
            settingsRowsSource.contains(".frame(minHeight: 40, alignment: .leading)")
                && settingsRowsSource.contains("struct SettingsRecentMeetingAudioControl"),
            "Settings retained-audio play controls should keep a 40pt hit floor"
        )
        assertTrue(
            meetingAudioPlaybackSource.contains(".frame(minHeight: 40)")
                && meetingAudioPlaybackSource.contains("struct MeetingAudioSourceMenu"),
            "retained-audio source menus should keep a 40pt hit floor"
        )
        assertFalse(
            homeSource.contains("representedObject = item.id"),
            "Home row menus should not depend on unstable SwiftUI-generated menu item IDs"
        )
        assertTrue(
            settingsComponentsSource.contains(".frame(width: 40, height: 40)")
                && settingsComponentsSource.contains(".accessibilityIdentifier(\"transcripted.settings.activity-card.dismiss\")")
                && settingsComponentsSource.contains(".frame(minHeight: 40)")
                && settingsComponentsSource.contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"),
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
            homeSource.contains("DispatchQueue.main.async { [handler] in handler() }"),
            "ClosureMenuItem should defer its handler off the NSMenu.popUp tracking loop so menu-triggered SwiftUI alerts/sheets present"
        )
        assertTrue(
            settingsSource.contains(".alert(item: rootAlertBinding)")
                && settingsSource.contains("enum RootAlert")
                && settingsSource.contains("case deleteConfirmation")
                && settingsSource.contains("case deleteFailure")
                && settingsSource.contains("case audioRetention"),
            "the Home delete, delete-failure, and audio-retention alerts should present through one rootAlertBinding so none is shadowed"
        )
        assertFalse(
            settingsSource.contains(".alert(item: $homeDeleteConfirmation)")
                || settingsSource.contains(".alert(item: $homeDeleteFailure)")
                || settingsSource.contains(".alert(item: $pendingAudioRetentionWindow)"),
            "Home alerts must not be re-stacked as separate `.alert(item:)` modifiers — stacked legacy alerts shadow all but the last"
        )
        // The shared binding must dismiss only the active alert via
        // HomeRootAlertPolicy, never clear all three. A confirm action can raise
        // a follow-up failure alert before SwiftUI writes nil; clearing
        // everything would wipe it before it presents. (HomeRootAlertPolicyTests
        // covers the priority/dismissal behavior directly.)
        assertTrue(
            settingsSource.contains("HomeRootAlertPolicy.activeSlot")
                && settingsSource.contains("switch activeRootAlert"),
            "the shared alert binding should clear only the dismissed alert through HomeRootAlertPolicy, not reset all three states"
        )

        // Own-file resolution contract (hardening/home-meeting-own-file-resolver).
        // Every Home/meeting control that touches an app-owned file (transcript,
        // audio, summary) must route through OwnFileResolver so a path that drifted
        // after scanning (restyle/rename, WAV→M4A recompression, deletion) surfaces
        // an error instead of a silent dead click. Behavior is covered by
        // OwnFileResolverTests; these guard the wiring so a regression that re-adds a
        // raw stale-path call (the #1126/#1131/#1134 whack-a-mole) fails CI.
        let ownFileResolverSource = readUIAutomationContractFile("Sources/UI/Shared/OwnFileResolver.swift")
        let playbackSource = readUIAutomationContractFile("Sources/UI/Shared/MeetingAudioPlayback.swift")

        assertTrue(
            ownFileResolverSource.contains("static func resolveForReveal(")
                && ownFileResolverSource.contains("static func resolveExistingFile(")
                && ownFileResolverSource.contains("static func resolveExistingFiles(")
                && ownFileResolverSource.contains("case reveal([URL])")
                && ownFileResolverSource.contains("case unavailable"),
            "OwnFileResolver must keep both reveal (with enclosing-folder fallback) and open/play (regular-file-only) resolution modes"
        )

        assertTrue(
            settingsSource.contains("private func revealOwnFile(")
                && settingsSource.contains("OwnFileResolver.resolveForReveal(candidateURLs:")
                && settingsSource.contains("private func openOwnFile(")
                && settingsSource.contains("OwnFileResolver.resolveExistingFile(candidateURLs:"),
            "Home reveal/open should route through OwnFileResolver helpers, surfacing presentHomeActionFailure on .unavailable instead of a dead click"
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
                settingsSource.contains(staleRawCall),
                "Home own-file action must not call NSWorkspace on a raw scan-time URL (\(staleRawCall)) — route it through OwnFileResolver"
            )
        }

        // Copy/export and re-transcribe must surface a failure, not a silent beep,
        // when the source file cannot be resolved.
        assertFalse(
            settingsSource.contains("NSWorkspace.shared.activateFileViewerSelecting(audioRevealURLs)"),
            "failed-meeting reveal audio must route through OwnFileResolver, not beep-or-reveal on raw URLs"
        )
        assertTrue(
            settingsSource.contains("Could not copy meeting")
                && settingsSource.contains("Could not re-transcribe meeting"),
            "copy-for-agent and re-transcribe should surface a failure alert when the own file is missing, instead of NSSound.beep()"
        )

        // Retained-audio playback follows recompressed/moved files instead of going
        // silently Unavailable on a stale path.
        assertTrue(
            playbackSource.contains("OwnFileResolver.resolveExistingFile(candidateURLs:"),
            "meeting audio playback should resolve each source URL through OwnFileResolver so WAV→M4A recompression still plays"
        )

        // Delete must surface a failure when it removed nothing yet the file is
        // still on disk (stale path), instead of letting the row reappear
        // unexplained. Deletion intentionally does not use the lenient resolver.
        assertTrue(
            settingsSource.contains("result.removedTranscriptURLs.isEmpty")
                && settingsSource.contains("FileManager.default.fileExists(atPath: item.transcriptURL.path)")
                && settingsSource.contains("presentHomeActionFailure("),
            "deleteMeeting should detect a no-op delete (stale path) and surface a failure rather than silently re-showing the row"
        )

        // Row-interaction affordances from fix/home-row-actions, which have no
        // behavioral coverage in the fast suite (it greps source, never runs the
        // UI). The overflow actions only reveal on hover, so the row needs a
        // full-width hit shape (its idle background is Color.clear) and the
        // canvas-header action button must not draw a focus ring.
        assertTrue(
            homeSource.contains(".focusEffectDisabled()"),
            "the Home canvas-header action button should keep .focusEffectDisabled() so it draws no focus ring"
        )
        assertTrue(
            homeSource.contains("across the full row.\n        .contentShape(Rectangle())"),
            "recent-capture rows should keep their full-width .contentShape(Rectangle()) so hover reveals row actions everywhere, not only over the title text"
        )

        for requiredOnboardingHook in [
            "Enable system audio",
            "Allow calendar access",
            "Skip for now",
        ] {
            assertTrue(onboardingSource.contains(requiredOnboardingHook), "\(requiredOnboardingHook) should stay in onboarding automation scope")
        }

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
                speakerReviewSource.contains(identifier),
                "\(identifier) should keep speaker review scriptable without using speaker names"
            )
        }
        assertTrue(
            speakerReviewSource.contains("static let minimum: CGFloat = 40")
                && speakerReviewSource.contains("let btnH = SpeakerNamingHitTargets.minimum")
                && speakerReviewSource.contains("let fieldH = SpeakerNamingHitTargets.minimum")
                && speakerReviewSource.contains("let hitTarget = SpeakerNamingHitTargets.minimum"),
            "speaker review save/cancel/name/play/confirm/discard controls should keep a 40pt hit floor"
        )
        assertTrue(
            speakerReviewSource.contains("static let sectionHeaderHeight: CGFloat = 40")
                && speakerReviewSource.contains("let headerHeight = SpeakerNamingHitTargets.sectionHeaderHeight")
                && speakerReviewSource.contains("keepAsYouButton.frame = NSRect("),
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
            assertTrue(agentSettingsSource.contains(requiredAgentHook), "\(requiredAgentHook) should stay in agent/connect automation scope")
        }

        let meetingOverlaySource = readUIAutomationContractFile("Sources/UI/Overlay/MeetingOverlayController.swift")
        let liveViewPolicySource = readUIAutomationContractFile("Sources/UI/Overlay/MeetingLiveViewAffordancePolicy.swift")
        assertTrue(
            liveViewPolicySource.contains("transcripted.meeting-overlay.live-view")
                && meetingOverlaySource.contains("setAccessibilityIdentifier(MeetingLiveViewAffordancePolicy.automationIdentifier)"),
            "the recording pill body should keep a stable automation identifier for the transcript toggle"
        )
        let transcriptDrawerSource = readUIAutomationContractFile("Sources/UI/Overlay/MeetingLiveTranscriptDrawerView.swift")
        assertTrue(
            liveViewPolicySource.contains("transcripted.meeting-overlay.live-view.copy")
                && transcriptDrawerSource.contains("MeetingLiveViewAffordancePolicy.copyAutomationIdentifier"),
            "the transcript drawer's copy action should keep a stable automation identifier"
        )
        assertTrue(
            liveViewPolicySource.contains("transcripted.meeting-overlay.live-view.more")
                && transcriptDrawerSource.contains("MeetingLiveViewAffordancePolicy.moreAutomationIdentifier"),
            "the transcript drawer's overflow menu should keep a stable automation identifier"
        )
        assertTrue(
            meetingOverlaySource.contains("MeetingLiveViewAffordancePolicy.discardRecordingMenuTitle")
                && meetingOverlaySource.contains("MeetingLiveViewAffordancePolicy.keepControlsVisibleMenuTitle")
                && transcriptDrawerSource.contains("MeetingLiveViewAffordancePolicy.openInBrowserMenuTitle"),
            "pill context-menu and drawer overflow actions should keep policy-pinned titles for automation"
        )
        assertTrue(
            transcriptDrawerSource.contains("transientStatusText ?? statusText")
                && transcriptDrawerSource.contains("openInBrowserFailedStatus")
                && transcriptDrawerSource.contains(".announcement: MeetingLiveViewAffordancePolicy.openInBrowserFailedStatus"),
            "browser-open failures should remain visible and announced even while transcript updates continue"
        )
        assertTrue(
            meetingOverlaySource.contains("showLiveViewBrowserOpenFailure")
                && meetingOverlaySource.contains("isTranscriptExpanded = true")
                && meetingOverlaySource.contains("rootView?.flashTranscriptBrowserOpenFailure()"),
            "browser-open failures from the collapsed pill menu should reveal the drawer before showing feedback"
        )

        assertTrue(
            deletePolicySource.contains("Delete this meeting?")
                && deletePolicySource.contains("Delete Meeting")
                && deletePolicySource.contains("Delete this failed meeting?")
                && deletePolicySource.contains("Delete Failed Meeting"),
            "delete confirmation copy should stay pinned for destructive-flow automation"
        )

        assertTrue(
            settingsComponentsSource.contains("settingsAutomationIdentifier")
                && settingsComponentsSource.contains("transcripted.settings.permissions.\\(kind.rawValue).action"),
            "settings shared controls should support stable automation IDs"
        )

        assertTrue(
            generalControlsSource.contains("generalAutomationIdentifier")
                && generalControlsSource.contains("transcripted.settings.general.dictation-window.options")
                && generalControlsSource.contains("transcripted.settings.general.dictation-window.\\(mode.rawValue)")
                && generalControlsSource.contains("transcripted.settings.general.info.\\(automationSlug(info.title))"),
            "general settings controls should keep scriptable row and choice IDs"
        )
    }

    runSuite("UI automation surface contract - deterministic click-flow identifiers stay mapped") {
        let settingsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let homeSource = readUIAutomationContractFile("Sources/UI/Settings/HomeView.swift")
        let speakerPeopleSource = readUIAutomationContractFile("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift")
        let settingsComponentsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsComponents.swift")
        let onboardingSource = readUIAutomationContractFile("Sources/UI/Settings/PermissionsOnboardingView.swift")
        let firstRunSource = readUIAutomationContractFile("Sources/UI/Shared/FirstRunExperience.swift")

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
            assertTrue(homeSource.contains(identifier), "\(identifier) should stay attached to Home click-flow controls")
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
            assertTrue(settingsSource.contains(identifier), "\(identifier) should stay attached to Settings click-flow controls")
        }

        assertTrue(
            speakerPeopleSource.contains("transcripted.speakers.inbox")
                && speakerPeopleSource.contains(".id(ScrollTarget.reviewQueue)")
                && settingsSource.contains("proxy.scrollTo(SpeakerPeopleSettingsSection.ScrollTarget.reviewQueue"),
            "The voices-to-name section should keep a stable automation anchor that review deep-links can scroll to"
        )

        assertTrue(
            speakerPeopleSource.contains("enum SpeakerPeopleSettingsPolishContract")
                && speakerPeopleSource.contains("struct SpeakerCompactIconLabel")
                && speakerPeopleSource.contains("static let minimumHitTarget: CGFloat = 40")
                && speakerPeopleSource.contains("static let playButtonVisibleDiameter: CGFloat = 36")
                && speakerPeopleSource.contains("static let compactIconVisibleDiameter: CGFloat = 28")
                && speakerPeopleSource.contains(".contentShape(Rectangle())"),
            "speaker settings should pin compact icon chrome separately from the 40pt hit shape"
        )

        let speakerCompactIconLabelApplications = speakerPeopleSource
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
                speakerPeopleSource.contains(identifier),
                "\(identifier) should keep the speakers surface's icon-only controls scriptable without using speaker names"
            )
        }

        assertTrue(
            homeSource.contains("HomeAttentionPillsRow")
                && homeSource.contains(".accessibilityHint(issue.detail)")
                && homeSource.contains("transcripted.home.needs-attention.review."),
            "Home attention pills should stay labeled and scriptable"
        )

        assertTrue(
            settingsSource.contains("HomeRowMenuItem(title: \"Review speakers\"")
                && settingsSource.contains("let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)")
                && settingsSource.contains("if !audioRevealURLs.isEmpty")
                && settingsSource.contains("title: \"Re-transcribe with speaker ID\""),
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
            assertTrue(onboardingSource.contains(identifier), "\(identifier) should stay attached to onboarding click-flow controls")
        }

        assertTrue(
            onboardingSource.contains("UseCaseChoiceCard(")
                && onboardingSource.contains("transcripted.onboarding.use-case.meetings")
                && onboardingSource.contains("transcripted.onboarding.use-case.dictation")
                && onboardingSource.contains("selectedStateStrokeWidth")
                && onboardingSource.contains(".contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))"),
            "onboarding use-case cards should keep their scriptable card-button and selected-state hooks"
        )

        assertTrue(
            firstRunSource.contains("static let minimumHitTarget: Double = 44")
                && firstRunSource.contains("static let modelProgressLabelMinimumWidth: Double = 104")
                && firstRunSource.contains("static let selectedStateStrokeWidth: Double = 2")
                && onboardingSource.contains("transcripted.onboarding.nav.skip")
                && onboardingSource.contains("transcripted.onboarding.nav.primary")
                && onboardingSource.contains("FirstRunOnboardingPolishContract.minimumHitTarget")
                && onboardingSource.contains(".contentShape(Rectangle())")
                && onboardingSource.contains(".contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))"),
            "onboarding nav and compact controls should keep pinned polish constants and hit-shape hooks"
        )

        assertTrue(
            settingsComponentsSource.contains(".monospacedDigit()")
                && settingsComponentsSource.contains("modelProgressLabelMinimumWidth")
                && settingsComponentsSource.contains(".accessibilityLabel(Text(status))"),
            "onboarding/local-model progress labels should stay stable, tabular, and accessible"
        )
    }

    runSuite("UI automation surface contract - QA CLI exposes a real AX smoke") {
        let qaEntrySource = readUIAutomationContractFile("Tools/TranscriptedQA/Sources/TranscriptedQA/TranscriptedQA.swift")
        let uiSmokeSource = readUIAutomationContractFile("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/UISmoke.swift")
        let qaBenchSource = readUIAutomationContractFile("scripts/ops/transcripted-qa-bench.sh")

        assertTrue(
            qaEntrySource.contains("UISmoke.self")
                && uiSmokeSource.contains("commandName: \"ui-smoke\""),
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
            assertTrue(uiSmokeSource.contains(requiredHarnessHook), "\(requiredHarnessHook) should stay pinned in the UI smoke harness")
        }

        assertTrue(
            qaBenchSource.contains("quick|deep|full|ui|packaged|artifact")
                && qaBenchSource.contains("run_ui_tail")
                && qaBenchSource.contains("transcripted-qa ui-smoke")
                && qaBenchSource.contains("ui-automation-smoke.json"),
            "QA bench should keep a callable ui mode with local JSON evidence"
        )
    }
}

private func readUIAutomationContractFile(_ relativePath: String) -> String {
    (try? String(contentsOf: repoFixtureURL(relativePath), encoding: .utf8)) ?? ""
}
