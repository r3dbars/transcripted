import Foundation

func testMeetingFailureCopy() {
    runSuite("MeetingFailureCopy noSpeechDetected points at Try again on the Meetings page") {
        let copy = MeetingFailureCopy.make(
            forMessage: "No speech detected",
            shortErrorMessage: "No speech detected",
            isRetryable: true
        )

        assertEqual(copy.title, "No speech found", "no-speech outcomes should be named plainly")
        assertTrue(
            copy.detail.contains("kept the audio"),
            "no-speech copy should say the audio was kept"
        )
        assertTrue(
            copy.detail.contains("Meetings page") && copy.detail.contains("Try again"),
            "saved no-speech rows now offer Try again, so the copy should say where to find it"
        )
        assertTrue(
            copy.detail.contains("If people were talking"),
            "the retry pointer is conditional, because a silent recording hides the action"
        )
        assertFalse(copy.detail.contains("\u{2014}"), "user copy avoids em dashes")
    }

    runSuite("MeetingFailureCopy noSpeechDetected keeps import and saved-audio copy") {
        // Read from the real table, so a wording change there fails here
        // instead of silently falling back to the Home retry pointer.
        let savedAudio = PipelineFailureDisplayCopy.message(for: .noSpeechDetected, flow: .savedAudioRetranscription)
        let savedCopy = MeetingFailureCopy.make(
            forMessage: savedAudio,
            shortErrorMessage: savedAudio,
            isRetryable: true
        )
        assertEqual(savedCopy.title, "No speech found", "saved-audio no-speech still reads as no speech")
        assertEqual(savedCopy.detail, savedAudio, "a saved-meeting retranscription has no Home row, so it keeps its own copy")

        let imported = PipelineFailureDisplayCopy.message(for: .noSpeechDetected, flow: .importedAudio)
        let importCopy = MeetingFailureCopy.make(
            forMessage: imported,
            shortErrorMessage: imported,
            isRetryable: true
        )
        assertEqual(importCopy.detail, imported, "an import failure keeps its own copy instead of pointing at Home")
    }

    runSuite("MeetingFailureCopy recordingTooShort says capture broke when the session ran long") {
        // TranscriptionTaskManager.recordingTooShortCaptureStoppedEarlyMessage
        let message = "Recording too short because audio capture stopped early"
        let copy = MeetingFailureCopy.make(
            forMessage: message,
            shortErrorMessage: message,
            isRetryable: false
        )
        assertEqual(copy.title, "Recording ended too soon", "it is still a too-short recording")
        assertFalse(copy.detail.contains("Nothing broke"), "capture did break here, so the copy must not say otherwise")
        assertTrue(copy.detail.contains("stopped early"), "the copy should say capture stopped early")
        assertFalse(copy.detail.contains("\u{2014}"), "user copy avoids em dashes")

        let plain = MeetingFailureCopy.make(
            forMessage: "Recording too short",
            shortErrorMessage: "Recording too short",
            isRetryable: false
        )
        assertTrue(plain.detail.contains("Nothing broke"), "a plain too-short recording keeps its old copy")
    }

    runSuite("MeetingFailureCopy gives classified engine failures plain copy") {
        // Each of these used to fall through to "Transcript needs another
        // pass" with the raw engine error as the detail.
        let cases: [(message: String, title: String)] = [
            ("Parakeet inference failed: MLMultiArray shape mismatch", "Transcription didn't finish"),
            ("Parakeet model not loaded", "Speech model wasn't ready"),
            ("Model download failed: offline", "Speech model didn't download"),
            ("Invalid audio format: unsupported sample rate", "Couldn't read the recording"),
            ("PyAnnote diarization crashed", "Couldn't sort out the speakers"),
            ("Transcription already in progress", "Transcription didn't start"),
            ("Transcription pipeline error", "Transcription didn't finish"),
            ("No microphone found", "No microphone found"),
        ]
        for (message, title) in cases {
            let copy = MeetingFailureCopy.make(
                forMessage: message,
                shortErrorMessage: message,
                isRetryable: true
            )
            assertEqual(copy.title, title, "\(message) should get a plain title")
            assertFalse(copy.detail == message, "\(message) should not show the raw engine error")
            assertFalse(copy.detail.lowercased().contains("parakeet"), "engine names stay out of user copy")
            assertFalse(copy.detail.contains("\u{2014}"), "user copy avoids em dashes")
        }
    }

    runSuite("MeetingFailureCopy keeps Core's catch-all live failure neutral") {
        // TranscriptionTaskManager publishes "Transcription failed" for every
        // live throw, so the pill must not pin it on the speech model.
        let copy = MeetingFailureCopy.make(
            forMessage: "Transcription failed",
            shortErrorMessage: "Transcription failed",
            isRetryable: true
        )
        assertEqual(copy.title, "Transcription didn't finish", "the catch-all still gets a plain title")
        assertFalse(copy.detail.contains("speech model"), "the cause is unknown here, so the copy must not name one")
        assertTrue(copy.detail.contains("Meetings page"), "the failed row on the Meetings page says the real reason")
    }

    runSuite("MeetingFailureCopy says when nothing was recorded") {
        for message in [
            "No meeting audio was captured.",
            "Recording stopped early and no meeting audio was saved.",
        ] {
            let copy = MeetingFailureCopy.make(
                forMessage: message,
                shortErrorMessage: message,
                isRetryable: true
            )
            assertEqual(copy.title, "Nothing was recorded", "no-audio stops should not read as a transcript retry")
            assertTrue(copy.detail.contains("nothing to retry"), "there is no saved audio, so the copy must not offer a retry")
        }
        assertEqual(
            MeetingFailureKind.classify(message: "No meeting audio was captured."),
            .unexpectedError,
            "the copy match must not move the analytics kind"
        )
    }

    runSuite("MeetingFailureCopy names stopped-early and unclean-close pills") {
        let early = MeetingFailureCopy.make(
            forMessage: "Recording stopped early. Open the Meetings page to retry the saved audio.",
            shortErrorMessage: "Recording stopped early. Open the Meetings page to retry the saved audio.",
            isRetryable: true
        )
        assertEqual(early.title, "Recording stopped early", "an early stop should say so")

        let unclean = MeetingFailureCopy.make(
            forMessage: "Recording didn't close cleanly. Open the Meetings page to retry.",
            shortErrorMessage: "Recording didn't close cleanly. Open the Meetings page to retry.",
            isRetryable: true
        )
        assertEqual(unclean.title, "Recording didn't close cleanly", "the stop-timeout pill should match the failed row")
    }

    runSuite("MeetingFailureCopy never points at a Home page") {
        // The sidebar calls it Meetings; there is no page named Home.
        let messages = [
            "No audio",
            "Empty audio file",
            "No speech detected",
            "Meeting saved before quit.",
            "Recording didn't close cleanly.",
            "Parakeet inference failed: x",
            "Model not loaded",
        ]
        for message in messages {
            let copy = MeetingFailureCopy.make(forMessage: message, shortErrorMessage: message, isRetryable: true)
            assertFalse(copy.detail.contains("Home"), "\(message) copy should say Meetings page, not Home")
        }
    }
}
