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
        assertEqual(meetings.primaryTitle, "Set up meetings", "meeting intro should offer setup")
        assertEqual(meetings.secondaryTitle, "Skip for now", "meeting intro should not trap dictation-first users")
        assertEqual(agent.primaryTitle, "Open Transcripted", "last step should land users in the app")
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
            card.detail.contains("on this Mac") || card.detail.contains("locally"),
            "model card should reassure the user the model stays local"
        )
        assertEqual(card.status, "50% complete", "model card should surface live progress")
        assertNotNil(card.progress, "model card should show a progress bar during downloads")
    }

    runSuite("FirstRunExperience.modelCard — names Parakeet TDT V3 in ready state") {
        let card = FirstRunExperience.modelCard(for: .ready)

        assertTrue(card.title.contains("Parakeet TDT V3"), "ready card should tell the user which model is running")
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
}
