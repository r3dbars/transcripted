import Foundation

func testMeetingFailureKind() {
    runSuite("MeetingFailureKind classifies recording-too-short errors") {
        let kind = MeetingFailureKind.classify(
            message: "Invalid audio data provided. Must be at least 1 second of 16kHz audio."
        )

        assertEqual(kind, .recordingTooShort, "short captures should stay out of the generic bucket")
    }

    runSuite("MeetingFailureKind does not overmatch generic minimum language") {
        let kind = MeetingFailureKind.classify(
            message: "Upload failed after at least one retry because the destination was unavailable."
        )

        assertEqual(kind, .unexpectedError, "minimum-language without audio context should not become recording_too_short")
    }

    runSuite("MeetingFailureKind keeps generic invalid audio separate from short recordings") {
        let kind = MeetingFailureKind.classify(
            message: "Invalid audio data: file header could not be decoded."
        )

        assertEqual(kind, .invalidAudioFormat, "generic invalid audio should not masquerade as a too-short recording")
    }

    runSuite("MeetingFailureKind classifies diarization failures") {
        let kind = MeetingFailureKind.classify(
            message: "PyAnnote inference failed: model weights missing"
        )

        assertEqual(kind, .diarizationFailed, "diarization-specific failures should be preserved for analytics")
    }

    runSuite("MeetingFailureKind classifies speaker finalization failures") {
        let kind = MeetingFailureKind.classify(
            message: "Failed to finalize speaker names"
        )

        assertEqual(kind, .speakerFinalizationFailed, "post-save speaker naming errors should stay out of transcript-failed telemetry")
    }

    runSuite("MeetingFailureKind classifies broader microphone-access wording") {
        let kind = MeetingFailureKind.classify(
            message: "Turn on Microphone access in System Settings before recording a meeting."
        )

        assertEqual(kind, .microphonePermission, "microphone access wording should stay centralized in the canonical classifier")
    }

    runSuite("MeetingFailureKind classifies no-speech results") {
        let kind = MeetingFailureKind.classify(
            message: "No speech detected in the audio."
        )

        assertEqual(kind, .noSpeechDetected, "audio with no spoken content should get a direct user-facing bucket")
    }

    runSuite("MeetingFailureKind marks expected empty transcript outcomes as skipped") {
        assertTrue(
            MeetingFailureKind.recordingTooShort.shouldReportAsSkippedTranscript,
            "short recordings should be reported as expected skips"
        )
        assertTrue(
            MeetingFailureKind.emptyAudio.shouldReportAsSkippedTranscript,
            "empty audio should be reported as an expected skip"
        )
        assertTrue(
            MeetingFailureKind.noSpeechDetected.shouldReportAsSkippedTranscript,
            "audio with no speech should be reported as an expected skip"
        )
        assertFalse(
            MeetingFailureKind.transcriptionInferenceFailed.shouldReportAsSkippedTranscript,
            "model failures should still report as transcript failures"
        )
        assertFalse(
            MeetingFailureKind.pipelineFailed.shouldReportAsSkippedTranscript,
            "pipeline failures should still report as transcript failures"
        )
    }

    runSuite("MeetingFailureKind classifies save failures") {
        let kind = MeetingFailureKind.classify(
            message: "Failed to save transcript: Could not write transcript to meetings"
        )

        assertEqual(kind, .saveFailed, "save failures should keep their own analytics bucket")
    }

    runSuite("MeetingFailureKind classifies speaker-name finalization failures") {
        let kind = MeetingFailureKind.classify(
            message: "Speaker names could not be saved. The transcript saved, but speaker-name finalization failed."
        )

        assertEqual(kind, .speakerNameFinalizationFailed, "speaker-name save failures should stay out of generic transcript save failures")
    }

    runSuite("MeetingFailureKind classifies support-thread speaker-name save wording") {
        let kind = MeetingFailureKind.classify(
            message: "Couldnt save speaker names. Saved them all in preview window, then got failed to save need another pass."
        )

        assertEqual(kind, .speakerNameFinalizationFailed, "Grigory-style save-stage speaker-name failures should not become generic transcript save failures")
    }

    runSuite("MeetingFailureKind classifies pipeline-busy errors") {
        let kind = MeetingFailureKind.classify(
            message: "Transcription already in progress"
        )

        assertEqual(kind, .pipelineBusy, "pipeline-busy rejections from TranscriptionTaskManager should not fall to unexpected_error")
    }

    runSuite("MeetingFailureKind classifies retry pipeline failures") {
        let kind = MeetingFailureKind.classify(
            message: "Retry failed"
        )

        assertEqual(kind, .pipelineFailed, "retry orchestration failures should stay out of unexpected_error")
    }

    runSuite("MeetingFailureKind preserves retry root causes") {
        let kind = MeetingFailureKind.classify(
            message: "Retry failed: Parakeet inference failed"
        )

        assertEqual(kind, .transcriptionInferenceFailed, "retry wrappers should not hide the concrete model failure")
    }

    runSuite("MeetingFailureKind classifies model-not-ready wording") {
        let kind = MeetingFailureKind.classify(
            message: "Meeting transcription models were not ready. Try again after models finish loading."
        )

        assertEqual(kind, .modelNotLoaded, "model warmup failures should not fall to unexpected_error")
    }

    runSuite("MeetingFailureKind classifies generic pipeline failures") {
        let kind = MeetingFailureKind.classify(
            message: "Pipeline failed"
        )

        assertEqual(kind, .pipelineFailed, "generic pipeline failures should have a stable bucket")
    }

    runSuite("MeetingFailureKind classifies model runtime wording") {
        let kind = MeetingFailureKind.classify(
            message: "ASR preprocessor failed while running CoreML prediction"
        )

        assertEqual(kind, .transcriptionInferenceFailed, "model runtime failures should land in the inference bucket")
    }

    runSuite("MeetingFailureKind classifies stop-timeout errors") {
        let kind = MeetingFailureKind.classify(
            message: "Recording stop timed out before audio files were finalized."
        )

        assertEqual(kind, .stopTimeout, "stop-timeout failures should keep their own bucket so retry copy can target them")
    }

    runSuite("MeetingFailureKind classifies saved-before-quit recovery") {
        let kind = MeetingFailureKind.classify(
            message: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening."
        )

        assertEqual(kind, .savedBeforeQuit, "intentional quit recovery should not look like a broken meeting")
    }

    runSuite("MeetingFailureKind classifies imported-audio preparation failures") {
        assertEqual(
            MeetingFailureKind.classify(message: "The selected audio file could not be found. It may have been moved or deleted."),
            .importFileMissing,
            "missing import files should not fall into unexpected_error"
        )
        assertEqual(
            MeetingFailureKind.classify(message: "That file does not look like audio. Choose a WAV, MP3, M4A, AAC, or AIFF file."),
            .importUnsupportedFile,
            "unsupported import files should have a stable bucket"
        )
        assertEqual(
            MeetingFailureKind.classify(message: "Transcripted couldn't copy that audio file into its working area. Check disk space and try again."),
            .importCopyFailed,
            "copy failures should point to the working-area step"
        )
    }

    runSuite("MeetingFailureCopy surfaces imported-audio repair guidance") {
        let copy = MeetingFailureCopy.make(
            forMessage: "That file does not look like audio. Choose a WAV, MP3, M4A, AAC, or AIFF file.",
            shortErrorMessage: "Unsupported audio file.",
            isRetryable: false
        )

        assertEqual(copy.title, "Choose an audio file", "unsupported import files should get direct user guidance")
    }

    runSuite("MeetingFailureCopy surfaces stop-timeout retry guidance") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Recording stop timed out before audio files were finalized.",
            shortErrorMessage: "Recording stop timed out.",
            isRetryable: true
        )

        assertEqual(copy.title, "Recording didn't close cleanly", "stop-timeout users should see specific copy, not generic retry phrasing")
    }

    runSuite("MeetingFailureCopy surfaces saved-before-quit recovery guidance") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening.",
            shortErrorMessage: "Meeting saved before quit.",
            isRetryable: true
        )

        assertEqual(copy.title, "Meeting saved before quit", "quit recovery should not look like a failure")
        assertTrue(copy.detail.contains("Audio is safe"), "quit recovery should reassure users that audio was kept")
    }

    runSuite("MeetingFailureKind falls back to an explicit unexpected bucket") {
        let kind = MeetingFailureKind.classify(
            message: "Something odd happened while processing the meeting"
        )

        assertEqual(kind, .unexpectedError, "unknown failures should avoid the vague 'other' label")
    }
}
