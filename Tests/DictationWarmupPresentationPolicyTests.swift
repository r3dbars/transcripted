import Foundation

func testDictationWarmupPresentationPolicy() {
    runSuite("DictationWarmupPresentationPolicy pre-recording warmup promises an automatic start") {
        let copy = DictationWarmupPresentationPolicy.copy(modelState: .notLoaded, phase: .beforeRecording)

        assertEqual(copy.title, "Warming up", "pre-recording warmup should read as a warmup, not an error")
        assertEqual(
            copy.detail,
            "Starts on its own when ready.",
            "pre-recording warmup must tell the user dictation starts on its own"
        )
        assertEqual(copy.status, "Preparing the voice model", "warmup should surface the concrete stage")
    }

    runSuite("DictationWarmupPresentationPolicy download shows visible percent progress") {
        let copy = DictationWarmupPresentationPolicy.copy(
            modelState: .downloading(progress: 0.5),
            phase: .beforeRecording
        )

        assertEqual(copy.title, "Downloading", "download should be named plainly, in one wing word")
        assertEqual(copy.status, "50% downloaded", "download status must show percent complete")
        assertTrue(
            copy.progress > 0.12 && copy.progress < 0.84,
            "mid-download progress should sit inside the download band"
        )
    }

    runSuite("DictationWarmupPresentationPolicy post-stop warmup reassures instead of promising a recording start") {
        for state: ParakeetModelState in [.notLoaded, .cached, .loading] {
            let copy = DictationWarmupPresentationPolicy.copy(modelState: state, phase: .afterRecording)

            assertEqual(
                copy.title,
                "Warming up",
                "post-stop warmup uses the same short wing word as before recording"
            )
            assertTrue(
                copy.detail.contains("Your recording is safe"),
                "post-stop warmup must reassure that the captured audio is safe"
            )
            assertTrue(
                !copy.detail.lowercased().contains("dictation starts"),
                "post-stop warmup must not reuse the pre-recording auto-start promise"
            )
        }
    }

    runSuite("DictationWarmupPresentationPolicy post-stop download keeps the recording-safe reassurance") {
        let copy = DictationWarmupPresentationPolicy.copy(
            modelState: .downloading(progress: 0.25),
            phase: .afterRecording
        )

        assertTrue(copy.detail.contains("Your recording is safe"), "post-stop download must reassure about the audio")
        assertEqual(copy.status, "25% downloaded", "post-stop download should still show percent complete")
    }

    runSuite("DictationWarmupPresentationPolicy ready and failed states stay direct") {
        let readyBefore = DictationWarmupPresentationPolicy.copy(modelState: .ready, phase: .beforeRecording)
        assertEqual(readyBefore.title, "Mic starting", "ready pre-recording state opens the mic")

        let readyAfter = DictationWarmupPresentationPolicy.copy(modelState: .ready, phase: .afterRecording)
        assertEqual(readyAfter.title, "Writing", "ready post-stop state uses the same word as the writing beat")

        let failed = DictationWarmupPresentationPolicy.copy(
            modelState: .failed("The model download was interrupted."),
            phase: .beforeRecording
        )
        assertEqual(failed.title, "Couldn't start", "failed warmup should say dictation could not start")
        assertEqual(failed.detail, "The model download was interrupted.", "failed warmup should pass through the reason")
    }

    runSuite("DictationWarmupPresentationPolicy keeps every wing title to two words") {
        let states: [ParakeetModelState] = [.notLoaded, .downloading(progress: 0.3), .cached, .loading, .ready, .failed("x")]
        for phase in [DictationWarmupPresentationPolicy.Phase.beforeRecording, .afterRecording] {
            for state in states {
                let title = DictationWarmupPresentationPolicy.copy(modelState: state, phase: phase).title
                assertTrue(title.split(separator: " ").count <= 2, "\(title) fits the wing without ballooning the island")
            }
        }
    }

    runSuite("DictationPostStopModelWaitPolicy keeps the original paste target after a long model wait") {
        assertTrue(
            DictationPostStopModelWaitPolicy.pasteFollowsCurrentFocus(modelWaitSeconds: 0),
            "no model wait should keep following focus as before"
        )
        assertTrue(
            DictationPostStopModelWaitPolicy.pasteFollowsCurrentFocus(modelWaitSeconds: 3),
            "a short warm load should keep following focus"
        )
        assertTrue(
            !DictationPostStopModelWaitPolicy.pasteFollowsCurrentFocus(modelWaitSeconds: 10),
            "a long wait must not paste into whatever app is in front now"
        )
        assertTrue(
            !DictationPostStopModelWaitPolicy.pasteFollowsCurrentFocus(modelWaitSeconds: 120),
            "a full-budget wait must not paste into whatever app is in front now"
        )
    }

    runSuite("DictationPostStopModelWaitPolicy says the recording is saved when the model never loads") {
        let saved = DictationPostStopModelWaitPolicy.modelUnavailableMessage(recordingSaved: true)
        assertTrue(saved.contains("your recording is saved"), "a checkpointed recording must be mentioned")
        assertTrue(saved.contains(DictationSavedAudioActionCopy.transcribeTitle), "the saved-recording copy must name the button that retries it")
        assertFalse(saved.contains("Capture →"), "don't send people to a menu that only shows while the app is in front")

        let unsaved = DictationPostStopModelWaitPolicy.modelUnavailableMessage(recordingSaved: false)
        assertTrue(!unsaved.contains("saved"), "without a checkpoint the copy must not promise saved audio")
    }
}
