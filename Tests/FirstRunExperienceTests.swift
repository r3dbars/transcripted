import Foundation

func testFirstRunExperience() {
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

    runSuite("FirstRunExperience.modelCard — explains the one-time local download") {
        let card = FirstRunExperience.modelCard(for: .downloading(progress: 0.5))

        assertEqual(card.title, "Downloading local dictation", "model card should name the active first-run step")
        assertTrue(
            card.detail.contains("one-time download"),
            "model card should explain why the download is happening"
        )
        assertEqual(card.status, "50% complete", "model card should surface live progress")
        assertNotNil(card.progress, "model card should show a progress bar during downloads")
    }
}
