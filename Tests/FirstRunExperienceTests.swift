import Foundation

func testFirstRunExperience() {
    runSuite("FirstRunExperience.onboardingSteps — follows the approved first-value journey") {
        let steps = FirstRunExperience.onboardingSteps()

        assertEqual(
            steps,
            [.hero, .value, .dictationSetup, .testDictation, .dictationResult, .meetingsIntro, .meetingSetup, .agentPayoff],
            "onboarding should teach value, prove dictation, introduce meetings, then explain agent payoff"
        )
        assertEqual(
            FirstRunOnboardingStep.hero.screenTitle,
            "Speak and get clean local Markdown your agents can use.",
            "hero should use the approved value proposition"
        )
        assertEqual(
            FirstRunOnboardingStep.value.screenTitle,
            "What Transcripted does",
            "second screen should explain the product instead of asking users to choose a path"
        )
    }

    runSuite("FirstRunExperience step navigation stays bounded") {
        assertNil(FirstRunExperience.previousStep(before: .hero), "hero should be the first onboarding step")
        assertEqual(FirstRunExperience.nextStep(after: .hero), .value, "hero should advance into value copy")
        assertEqual(FirstRunExperience.previousStep(before: .agentPayoff), .meetingSetup, "final step should have a back target")
        assertNil(FirstRunExperience.nextStep(after: .agentPayoff), "agent payoff should be the terminal onboarding step")
    }

    runSuite("FirstRunExperience.onboardingAction — gates first dictation on microphone plus paste-back") {
        let blocked = FirstRunExperience.onboardingAction(
            for: .dictationSetup,
            microphoneGranted: true,
            accessibilityGranted: false,
            hasFirstDictation: false
        )
        let ready = FirstRunExperience.onboardingAction(
            for: .dictationSetup,
            microphoneGranted: true,
            accessibilityGranted: true,
            hasFirstDictation: false
        )

        assertEqual(blocked.primaryTitle, "Turn on Microphone and Paste-back", "blocked setup should name both required dictation capabilities")
        assertFalse(blocked.isPrimaryEnabled, "dictation setup should block until paste-back is ready")
        assertEqual(ready.primaryTitle, "Continue", "ready setup should let users reach the first dictation test")
        assertTrue(ready.isPrimaryEnabled, "ready setup should unlock")
    }

    runSuite("FirstRunExperience.onboardingAction — blocks the dictation test until setup is complete") {
        let blocked = FirstRunExperience.onboardingAction(
            for: .testDictation,
            microphoneGranted: false,
            accessibilityGranted: true,
            hasFirstDictation: false
        )

        assertEqual(blocked.primaryTitle, "Start Dictation", "the test step should keep the same CTA")
        assertFalse(blocked.isPrimaryEnabled, "the first dictation test should stay disabled until required permissions are ready")
        assertTrue(blocked.detail.contains("Finish dictation setup first"), "blocked copy should point back to setup")
    }

    runSuite("FirstRunExperience.onboardingAction — presents meetings and agent payoff after first dictation") {
        let result = FirstRunExperience.onboardingAction(
            for: .dictationResult,
            microphoneGranted: true,
            accessibilityGranted: true,
            hasFirstDictation: true
        )
        let meetings = FirstRunExperience.onboardingAction(
            for: .meetingsIntro,
            microphoneGranted: true,
            accessibilityGranted: true,
            hasFirstDictation: true
        )
        let agent = FirstRunExperience.onboardingAction(
            for: .agentPayoff,
            microphoneGranted: true,
            accessibilityGranted: true,
            hasFirstDictation: true
        )

        assertEqual(result.primaryTitle, "Continue", "saved first dictation should move into meetings")
        assertTrue(
            result.detail.contains("saved local Markdown file"),
            "saved first dictation should prove the local Markdown artifact"
        )
        assertEqual(meetings.primaryTitle, "Set up meetings", "meeting intro should offer setup")
        assertEqual(meetings.secondaryTitle, "Skip for now", "meeting intro should not trap dictation-first users")
        assertEqual(agent.primaryTitle, "Open Transcripted", "last step should land users in the app")
    }

    runSuite("FirstRunExperience.onboardingAction — missing first dictation offers retry") {
        let result = FirstRunExperience.onboardingAction(
            for: .dictationResult,
            microphoneGranted: true,
            accessibilityGranted: true,
            hasFirstDictation: false
        )

        assertEqual(result.primaryTitle, "Try Again", "missing proof should return users to the dictation attempt")
        assertTrue(result.detail.contains("No dictation has been saved yet"), "retry copy should be explicit")
        assertTrue(result.isPrimaryEnabled, "retry should stay available")
    }

    runSuite("FirstRunExperience.onboardingPermissions — keeps dictation setup separate from later meeting permissions") {
        let required = FirstRunExperience.onboardingRequiredPermissions()
        let optional = FirstRunExperience.onboardingOptionalPermissions()

        assertEqual(
            required,
            [.microphone, .accessibility],
            "first-run onboarding should only require dictation-critical permissions"
        )
        assertEqual(
            optional,
            [.systemAudioRecording, .calendar],
            "system audio and calendar should stay in the later optional group"
        )
    }

    runSuite("FirstRunExperience.onboardingPermissions — meetings-first setup does not hard-block on System Audio") {
        assertTrue(
            FirstRunExperience.hasRequiredMeetingSetup(microphoneGranted: true),
            "meetings-first onboarding should let users continue after Microphone so System Audio can be explained in context"
        )
        assertFalse(
            FirstRunExperience.hasRequiredMeetingSetup(microphoneGranted: false),
            "meetings-first onboarding still needs Microphone before call detection or recording can work"
        )
        assertEqual(
            FirstRunExperience.onboardingRequiredPermissions(completionPath: .meetings),
            [.microphone],
            "meetings-first onboarding should not trap users on System Audio before showing the meeting value path"
        )
        assertEqual(
            FirstRunExperience.onboardingRequiredPermissions(completionPath: .dictation),
            [.microphone, .accessibility],
            "dictation onboarding should still require paste-back readiness"
        )
    }

    runSuite("FirstRunExperience.onboardingCompletionAnalyticsProperties — keeps completion payload coarse") {
        let properties = FirstRunExperience.onboardingCompletionAnalyticsProperties(
            completionPath: .meetings,
            systemAudioGranted: true,
            calendarGranted: false,
            meetingPromptsEnabled: true,
            firstDictationSaved: true,
            anonymousUsageEnabled: true,
            crashReportingEnabled: false,
            elapsedSeconds: 75
        )

        assertEqual(properties["completion_flow"], "meetings", "completion flow should stay a coarse enum")
        assertEqual(properties["meeting_recording_ready"], "true", "completion should preserve meeting readiness")
        assertEqual(properties["calendar_status"], "not_granted", "calendar status should avoid raw event details")
        assertEqual(properties["anonymous_usage_enabled"], "true", "completion should preserve analytics preference state")
        assertEqual(properties["crash_reporting_enabled"], "false", "completion should preserve crash preference state")
        assertEqual(properties["first_dictation_saved"], "true", "completion should preserve whether the first dictation save happened")
        assertEqual(properties["flow_elapsed_bucket"], "30_119s", "completion should bucket elapsed time")
        assertEqual(properties["step_id"], "done", "completion should anchor to the final onboarding step")
        assertNil(properties["transcript"], "completion analytics should not include spoken content")
        assertNil(properties["audio_path"], "completion analytics should not include local paths")
        assertNil(properties["meeting_title"], "completion analytics should not include titles")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            properties,
            allowedKeys: AnalyticsEventPolicy.policy(forEvent: "onboarding_completed")?.allowedProperties ?? []
        )
        assertEqual(sanitized["completion_flow"], "meetings", "completion flow should survive analytics sanitization")
    }

    runSuite("FirstRunExperience.onboardingCompletionAnalyticsProperties — handles dictation-only completion without elapsed timing") {
        let properties = FirstRunExperience.onboardingCompletionAnalyticsProperties(
            completionPath: .dictation,
            systemAudioGranted: false,
            calendarGranted: true,
            meetingPromptsEnabled: false,
            firstDictationSaved: false,
            anonymousUsageEnabled: false,
            crashReportingEnabled: true,
            elapsedSeconds: nil
        )

        assertEqual(properties["completion_flow"], "dictation", "dictation-only completion should stay distinct")
        assertEqual(properties["meeting_recording_ready"], "false", "missing system audio should be preserved")
        assertEqual(properties["first_dictation_saved"], "false", "completion should not invent a first dictation save")
        assertEqual(properties["calendar_status"], "disabled", "disabled meeting prompts should not report calendar as granted")
        assertNil(properties["flow_elapsed_bucket"], "missing elapsed time should not invent a duration bucket")
    }

    runSuite("FirstRunExperience.meetingAction — switches menu copy while recording") {
        let idle = FirstRunExperience.meetingAction(
            dictationReady: true,
            meetingsStatus: "Ready",
            isRecording: false
        )
        let recording = FirstRunExperience.meetingAction(
            dictationReady: true,
            meetingsStatus: "Ready",
            isRecording: true
        )

        assertEqual(idle.title, "Start Meeting", "idle menu action should invite starting a meeting")
        assertEqual(idle.symbolName, "record.circle.fill", "idle menu action should use the record icon")
        assertEqual(recording.title, "Stop Meeting", "recording menu action should not keep saying Start Meeting")
        assertEqual(recording.symbolName, "stop.circle.fill", "recording menu action should use the stop icon")
        assertEqual(recording.subtitle, "", "recording row should stay quiet — the red tone and timer carry the state")
    }

    runSuite("FirstRunExperience.meetingAction — exposes retry copy after meeting tool failure") {
        let failed = FirstRunExperience.meetingAction(
            dictationReady: true,
            meetingsStatus: "Failed"
        )
        let lazy = FirstRunExperience.meetingAction(
            dictationReady: false,
            meetingsStatus: "On demand"
        )

        assertEqual(failed.subtitle, "Try again to reload meeting tools", "failed meeting warmup should offer a retry path")
        assertEqual(lazy.subtitle, "Starts local meeting setup on first use", "cold startup should explain lazy meeting setup")
    }

    runSuite("FirstRunExperience.primaryAction — explains only dictation-critical permissions are required up front") {
        let action = FirstRunExperience.primaryAction(
            hasRequiredPermissions: false,
            hasPasteTarget: false,
            modelState: .notLoaded
        )

        assertEqual(action.title, "Turn on the required permissions", "blocked onboarding should still use the required-permissions CTA")
        assertFalse(action.isEnabled, "first-run CTA should stay disabled until the required dictation permissions are granted")
        assertFalse(action.shouldStartDictation, "blocked onboarding should not try to launch dictation")
        assertTrue(
            action.detail.contains("Microphone and Accessibility"),
            "blocked onboarding copy should name the dictation-critical permissions"
        )
        assertTrue(
            action.detail.contains("System Audio Recording and Calendar can wait until later"),
            "blocked onboarding copy should make the later permissions feel optional"
        )
    }

    runSuite("FirstRunExperience.primaryAction — starts dictation when permissions and a paste target are ready") {
        let action = FirstRunExperience.primaryAction(
            hasRequiredPermissions: true,
            hasPasteTarget: true,
            modelState: .loading
        )

        assertEqual(action.title, "Start first dictation", "first-run CTA should point to first value")
        assertTrue(action.isEnabled, "first-run CTA should unlock once required permissions are granted")
        assertTrue(action.shouldStartDictation, "first-run CTA should launch dictation when Transcripted knows the target app")
        assertTrue(
            action.detail.contains("Start now"),
            "loading copy should explain that dictation can begin before the model fully finishes"
        )
    }

    runSuite("FirstRunExperience.primaryAction — falls back to continue when Transcripted does not know the target app") {
        let action = FirstRunExperience.primaryAction(
            hasRequiredPermissions: true,
            hasPasteTarget: false,
            modelState: .ready
        )

        assertEqual(action.title, "Continue to Transcripted", "fallback CTA should keep onboarding moving")
        assertFalse(action.shouldStartDictation, "continue CTA should not try to start dictation without a target app")
        assertTrue(
            action.detail.lowercased().contains("click back into any text field"),
            "fallback copy should tell the user exactly what to do next"
        )
    }

    runSuite("FirstRunExperience.primaryAction — explains cached model without paste target") {
        let action = FirstRunExperience.primaryAction(
            hasRequiredPermissions: true,
            hasPasteTarget: false,
            modelState: .cached
        )

        assertEqual(action.title, "Continue to Transcripted", "cached fallback should keep onboarding moving")
        assertFalse(action.shouldStartDictation, "cached fallback should not start dictation without a target")
        assertTrue(action.detail.contains("cached"), "cached fallback copy should distinguish files from loaded model")
    }

    runSuite("FirstRunExperience.primaryAction — keeps first dictation available after model warmup failed") {
        let action = FirstRunExperience.primaryAction(
            hasRequiredPermissions: true,
            hasPasteTarget: true,
            modelState: .failed("Model load failed")
        )

        assertEqual(action.title, "Start first dictation", "failed warmup should still preserve the first dictation CTA")
        assertTrue(action.isEnabled, "failed warmup should not dead-end onboarding")
        assertTrue(action.shouldStartDictation, "failed warmup should retry dictation when Transcripted knows the target app")
        assertTrue(
            action.detail.lowercased().contains("retry the local voice model"),
            "failed warmup copy should explain that starting dictation retries local setup"
        )
    }

    runSuite("FirstRunExperience.primaryAction — explains retry path when model warmup failed without a paste target") {
        let action = FirstRunExperience.primaryAction(
            hasRequiredPermissions: true,
            hasPasteTarget: false,
            modelState: .failed("Model load failed")
        )

        assertEqual(action.title, "Continue to Transcripted", "failed warmup fallback should keep onboarding moving")
        assertFalse(action.shouldStartDictation, "continue CTA should not attempt dictation without a known target app")
        assertTrue(
            action.detail.lowercased().contains("needs another try"),
            "fallback copy should explain that local model setup still needs a retry"
        )
    }

    runSuite("FirstRunExperience.dictationAction — stays enabled while dictation is still downloading") {
        let state = FirstRunExperience.dictationAction(for: .downloading(progress: 0.35))

        assertTrue(state.isEnabled, "dictation should stay reachable while the local model downloads")
        assertEqual(
            state.subtitle,
            "Downloads once, then starts automatically",
            "dictation row should explain the one-time background wait"
        )
    }

    runSuite("FirstRunExperience.dictationAction — failed model setup still offers retry") {
        let state = FirstRunExperience.dictationAction(for: .failed("load failed"))

        assertTrue(state.isEnabled, "dictation retry should stay available after local model setup fails")
        assertEqual(state.subtitle, "Try again to retry local voice setup", "failed dictation row should explain retry behavior")
    }

    runSuite("FirstRunExperience.meetingAction — stays enabled while meetings load in the background") {
        let state = FirstRunExperience.meetingAction(
            dictationReady: true,
            meetingsStatus: "Loading"
        )

        assertTrue(state.isEnabled, "meeting row should stay reachable while background warmup continues")
        assertEqual(
            state.subtitle,
            "Meeting tools are still loading in the background",
            "meeting row should explain why it is not fully ready yet"
        )
    }

    runSuite("FirstRunExperience.modelCard — names the model and download source during first-run") {
        let card = FirstRunExperience.modelCard(for: .downloading(progress: 0.5))

        assertEqual(card.title, "Downloading Parakeet TDT V3", "model card should name the active first-run step and the model")
        assertTrue(
            card.detail.contains("huggingface.co"),
            "model card should tell the user where the model is being downloaded from"
        )
        assertTrue(
            card.detail.contains("normal Transcripted updates do not download it again"),
            "model card should explain that app updates reuse the cached model"
        )
        assertTrue(
            card.detail.contains("on this Mac") || card.detail.contains("locally"),
            "model card should reassure the user the model stays local"
        )
        assertEqual(card.status, "50% complete", "model card should surface live progress")
        assertNotNil(card.progress, "model card should show a progress bar during downloads")
    }

    runSuite("FirstRunExperience.modelCard — clamps displayed download progress") {
        let belowZero = FirstRunExperience.modelCard(for: .downloading(progress: -0.2))
        let aboveComplete = FirstRunExperience.modelCard(for: .downloading(progress: 1.3))

        assertEqual(belowZero.status, "Starting download", "negative progress should not render a jumpy negative percentage")
        assertEqual(aboveComplete.status, "100% complete", "over-complete progress should keep the label bounded")
    }

    runSuite("FirstRunExperience.modelCard — names Parakeet TDT V3 in ready state") {
        let card = FirstRunExperience.modelCard(for: .ready)

        assertTrue(card.title.contains("Parakeet TDT V3"), "ready card should tell the user which model is running")
    }

    runSuite("FirstRunExperience.modelCard — explains on-demand model loading") {
        let card = FirstRunExperience.modelCard(for: .notLoaded)

        assertEqual(card.status, "On demand", "not-loaded model state should be presented as intentional lazy loading")
        assertTrue(
            card.detail.contains("out of memory"),
            "not-loaded model detail should explain the lightweight launch behavior"
        )
        assertTrue(
            card.detail.contains("One-time ~600 MB download"),
            "not-loaded model detail should warn about the first Parakeet download size"
        )
        assertNil(card.progress, "on-demand model state should not show fake startup progress")
    }

    runSuite("FirstRunExperience.modelCard — explains update-safe model cache when ready") {
        let card = FirstRunExperience.modelCard(for: .ready)

        assertTrue(
            card.detail.contains("outside app updates"),
            "ready model card should explain that future app updates do not redownload the model"
        )
    }

    runSuite("FirstRunExperience.modelCard — distinguishes cached files from loaded model") {
        let card = FirstRunExperience.modelCard(for: .cached)

        assertEqual(card.status, "Cached", "cached model card should not look like a missing download")
        assertTrue(
            card.detail.contains("load them into memory"),
            "cached model copy should explain that dictation still loads the files on first use"
        )
        assertNil(card.progress, "cached files should not show fake download progress")
    }

    runSuite("FirstRunExperience.modelCard — failed setup stays concise and retryable") {
        let card = FirstRunExperience.modelCard(
            for: .failed("CoreML failed while reading /Users/example/Library/Application Support/Transcripted/private-model-file")
        )

        assertEqual(card.title, "Couldn't load Parakeet TDT V3", "failed model card should name the affected model")
        assertEqual(card.status, "Retry needed", "failed model card should make the recovery state clear")
        assertEqual(card.tone, .failed, "failed model card should keep the visual failure tone")
        assertNil(card.progress, "failed model setup should not show fake download progress")
        assertTrue(
            card.detail.contains("Local voice setup needs another try"),
            "failed model card should lead with a plain-language recovery cue"
        )
        assertTrue(
            card.detail.contains("Retry Download"),
            "failed model card should name the retry action"
        )
        assertFalse(
            card.detail.contains("/Users/example"),
            "failed model card should not expose raw local diagnostic paths in onboarding"
        )
    }

    runSuite("FirstRunExperience.modelCard — names Whisper when it is selected") {
        let card = FirstRunExperience.modelCard(
            for: .downloading(progress: 0.25),
            model: .whisperLargeV3Turbo
        )

        assertEqual(card.title, "Downloading Whisper Large V3 Turbo", "advanced model card should name Whisper")
        assertTrue(card.detail.contains("~632 MB"), "Whisper Turbo card should show the expected model size")
        assertEqual(card.status, "25% complete", "Whisper card should keep progress behavior")
    }

    runSuite("FirstRunOnboardingPolishContract — protects first-run polish targets") {
        assertTrue(
            FirstRunOnboardingPolishContract.minimumHitTarget >= 40,
            "onboarding controls should keep at least a 40px hit target"
        )
        assertTrue(
            FirstRunOnboardingPolishContract.minimumCompactButtonHeight >= 40,
            "compact permission buttons should not shrink below the requested target"
        )
        assertTrue(
            FirstRunOnboardingPolishContract.modelProgressLabelMinimumWidth >= 100,
            "download progress labels need a stable tabular slot"
        )
        assertTrue(
            FirstRunOnboardingPolishContract.selectedStateStrokeWidth >= 2,
            "selected cards need a visible state that is not just a faint border"
        )
        assertTrue(
            FirstRunOnboardingPolishContract.bodyCopyLineLimit <= 3,
            "first-run cards should keep short copy from wrapping into tall blocks"
        )
    }
}
