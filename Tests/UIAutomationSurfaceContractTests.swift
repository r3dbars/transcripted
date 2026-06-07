import Foundation

func testUIAutomationSurfaceContract() {
    runSuite("UI automation surface contract - menubar controls expose stable identifiers") {
        let appSource = readUIAutomationContractFile("Sources/TranscriptedApp.swift")
        let actionRowSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarActionRowView.swift")
        let primarySource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarPrimaryActionsView.swift")
        let utilitySource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuBarUtilityActionsView.swift")
        let agentMenuSource = readUIAutomationContractFile("Sources/UI/MenuBar/MenuAgentConnectPageView.swift")
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
                && actionRowSource.contains("accessibilityIdentifier()"),
            "menubar smoke snapshots should carry the same accessibility identifier AppKit automation sees"
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

        for identifier in [
            "transcripted.menubar.agent.back",
            "transcripted.menubar.agent.copy-claude-desktop-steps",
            "transcripted.menubar.agent.copy-folder-paths",
            "transcripted.menubar.agent.copy-local-agent-prompt",
        ] {
            assertTrue(
                agentMenuSource.contains(identifier),
                "\(identifier) should keep the menubar agent page clickable by automation"
            )
        }
    }

    runSuite("UI automation surface contract - major settings and Home flows stay mapped") {
        let pagesSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsPage.swift")
        let settingsSidebarSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsSidebar.swift")
        let settingsComponentsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsComponents.swift")
        let generalControlsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift")
        let settingsSource = readUIAutomationContractFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let homeSource = readUIAutomationContractFile("Sources/UI/Settings/HomeView.swift")
        let onboardingSource = readUIAutomationContractFile("Sources/UI/Settings/PermissionsOnboardingView.swift")
        let speakerReviewSource = readUIAutomationContractFile("Sources/UI/Settings/SpeakerNamingSheet.swift")
        let agentSettingsSource = readUIAutomationContractFile("Sources/UI/Settings/AgentConnectionSettingsPage.swift")
        let deletePolicySource = readUIAutomationContractFile("Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift")

        for pageCase in [
            "case home",
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
        ] {
            assertTrue(settingsSource.contains(requiredHomeActionHook), "\(requiredHomeActionHook) should keep Home action coverage visible")
        }

        for requiredHomeRendererHook in [
            "title: hasRetainedAudioFiles ? \"Delete\" : \"Dismiss\"",
            "HomeRowMoreMenuButton(items:",
            "title: \"Copy for agent\"",
        ] {
            assertTrue(homeSource.contains(requiredHomeRendererHook), "\(requiredHomeRendererHook) should keep Home action rendering visible")
        }

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

        for requiredAgentHook in [
            "Install in Claude",
            "Copy Folder Prompt",
            "Copy Paths",
            "Copy for Agent",
            "Live meeting sidecar",
        ] {
            assertTrue(agentSettingsSource.contains(requiredAgentHook), "\(requiredAgentHook) should stay in agent/connect automation scope")
        }

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
        let onboardingSource = readUIAutomationContractFile("Sources/UI/Settings/PermissionsOnboardingView.swift")

        for identifier in [
            "transcripted.home.mode.meetings",
            "transcripted.home.mode.dictation",
            "transcripted.home.mode.speakers",
            "transcripted.home.stats.view",
            "transcripted.home.stats.done",
            "transcripted.home.row.copy",
            "transcripted.home.row.more",
            "transcripted.home.dictation.open-markdown",
            "transcripted.home.dictation.expand",
            "transcripted.home.meeting.preview",
            "transcripted.home.meeting.summary-expand",
            "transcripted.home.meeting.review-speakers",
            "transcripted.home.meeting.retranscribe-speakers",
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
            "transcripted.home.needs-attention.review",
            "transcripted.home.needs-attention.review-menu",
        ] {
            assertTrue(homeSource.contains(identifier), "\(identifier) should stay attached to Home click-flow controls")
        }

        assertTrue(
            homeSource.contains("transcripted.home.audio.\\(isPlaying ?"),
            "Home audio play/pause action should keep a stable dynamic automation ID"
        )

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

        for identifier in [
            "transcripted.onboarding.nav.back",
            "transcripted.onboarding.nav.skip",
            "transcripted.onboarding.nav.primary",
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
            "transcripted.onboarding.agent.copy-claude-desktop-steps",
            "transcripted.onboarding.agent.copy-local-agent-prompt",
        ] {
            assertTrue(onboardingSource.contains(identifier), "\(identifier) should stay attached to onboarding click-flow controls")
        }
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
            "transcripted.status-item.button",
            "transcripted.menubar.primary.home",
            "transcripted.settings.sidebar.general",
            "transcripted.home.mode.meetings",
        ] {
            assertTrue(uiSmokeSource.contains(requiredHarnessHook), "\(requiredHarnessHook) should stay pinned in the UI smoke harness")
        }

        assertTrue(
            qaBenchSource.contains("quick|deep|ui|artifact")
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
