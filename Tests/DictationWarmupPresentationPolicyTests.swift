import Foundation

func testDictationWarmupPresentationPolicy() {
    runSuite("DictationWarmupPresentationPolicy pre-recording warmup promises an automatic start") {
        let copy = DictationWarmupPresentationPolicy.copy(modelState: .notLoaded, phase: .beforeRecording)

        assertEqual(copy.title, "Warming up", "pre-recording warmup should read as a warmup, not an error")
        assertEqual(
            copy.detail,
            "Dictation starts automatically as soon as the voice model is ready.",
            "pre-recording warmup must tell the user dictation starts on its own"
        )
        assertEqual(copy.status, "Preparing the voice model", "warmup should surface the concrete stage")
    }

    runSuite("DictationWarmupPresentationPolicy download shows visible percent progress") {
        let copy = DictationWarmupPresentationPolicy.copy(
            modelState: .downloading(progress: 0.5),
            phase: .beforeRecording
        )

        assertEqual(copy.title, "Downloading the voice model", "download should be named plainly")
        assertEqual(copy.status, "50% downloaded", "download status must show percent complete")
        assertTrue(
            copy.progress > 0.12 && copy.progress < 0.84,
            "mid-download progress should sit inside the download band"
        )
    }

    runSuite("DictationWarmupPresentationPolicy post-stop warmup reassures instead of promising a recording start") {
        for state: DictationWarmupPresentationPolicy.ModelState in [.notLoaded, .cached, .loading] {
            let copy = DictationWarmupPresentationPolicy.copy(modelState: state, phase: .afterRecording)

            assertEqual(
                copy.title,
                "Getting ready to transcribe",
                "post-stop warmup should say transcription is coming, not that recording will start"
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
        assertEqual(readyBefore.title, "Starting dictation", "ready pre-recording state should start dictation")

        let readyAfter = DictationWarmupPresentationPolicy.copy(modelState: .ready, phase: .afterRecording)
        assertEqual(readyAfter.title, "Transcribing", "ready post-stop state should say it is transcribing")

        let failed = DictationWarmupPresentationPolicy.copy(
            modelState: .failed("The model download was interrupted."),
            phase: .beforeRecording
        )
        assertEqual(failed.title, "Dictation couldn't start", "failed warmup should say dictation could not start")
        assertEqual(failed.detail, "The model download was interrupted.", "failed warmup should pass through the reason")
    }
}
