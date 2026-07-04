import Foundation

func testFailedMeetingPresentation() {
    runSuite("FailedMeetingPresentation short audio failures get actionable copy") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            shortErrorMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            isRetryable: false
        )

        assertEqual(copy.title, "Recording ended too soon", "short captures should stop looking like generic retries")
        assertEqual(
            copy.detail,
            "Nothing broke - there just was not enough audio to transcribe. Record at least two seconds before stopping.",
            "short captures should explain the intentional terminal outcome"
        )
    }

    runSuite("FailedMeetingPresentation does not classify unrelated minimum-copy as short audio") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Upload failed after at least one retry because the destination was unavailable.",
            shortErrorMessage: "Upload failed after at least one retry.",
            isRetryable: true
        )

        assertEqual(copy.title, "Transcript needs another pass", "generic retry copy should not look like short audio")
        assertEqual(copy.detail, "Upload failed after at least one retry.", "generic retry detail should be preserved")
    }

    runSuite("FailedMeetingPresentation system audio failures point to settings") {
        let copy = MeetingFailureCopy.make(
            forMessage: "System audio is required. Turn on System Audio Recording and retry.",
            shortErrorMessage: "System audio is required. Turn on System Audio Recording and retry.",
            isRetryable: false
        )

        assertEqual(copy.title, "Turn on System Audio Recording", "permission failures should name the missing permission")
        assertEqual(
            copy.detail,
            "Turn on System Audio Recording in System Settings, then retry the meeting.",
            "permission failures should point to the recovery step"
        )
    }

    runSuite("FailedMeetingPresentation microphone failures point to settings") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Turn on Microphone access in System Settings before recording a meeting.",
            shortErrorMessage: "Turn on Microphone access in System Settings before recording a meeting.",
            isRetryable: false
        )

        assertEqual(copy.title, "Turn on Microphone", "microphone failures should name the missing permission")
        assertEqual(
            copy.detail,
            "Turn on Microphone access in System Settings, then retry the meeting.",
            "microphone failures should point to the recovery step"
        )
    }

    runSuite("FailedMeetingPresentation save failures keep the short error detail") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Failed to save transcript: Could not write transcript to meetings",
            shortErrorMessage: "Could not write transcript to meetings",
            isRetryable: false
        )

        assertEqual(copy.title, "Couldn't save the transcript", "save failures should keep the save-specific title")
        assertEqual(copy.detail, "Could not write transcript to meetings", "save failures should preserve the short write error")
    }

    runSuite("FailedMeetingPresentation no-speech failures point to Home recovery") {
        let copy = MeetingFailureCopy.make(
            forMessage: "No speech detected",
            shortErrorMessage: "No speech detected",
            isRetryable: true
        )

        assertEqual(copy.title, "No speech found", "no-speech outcomes should be named plainly")
        assertEqual(
            copy.detail,
            "Transcripted found audio, but not enough spoken words to write a transcript. Open Home to retry, or record again with clearer voices.",
            "no-speech outcomes should point to a visible recovery path"
        )
    }

    runSuite("MeetingSessionController surfaces skipped no-speech outcomes visibly") {
        let source = (try? String(
            contentsOf: repoFixtureURL("Sources/Meeting/MeetingSessionController.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            source.contains("lastTerminalTranscriptionOutcome = .failed(diagnosticMessage)\n                state = .error(diagnosticMessage)"),
            "skipped no-speech transcripts should still publish a visible recovery notice"
        )
    }

    runSuite("HomeFailedMeetingInlinePresentation shows details for non-retryable failures") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: false,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Turn on System Audio Recording in System Settings, then retry the meeting."
        )

        assertEqual(presentation.statusText, "Needs attention", "non-retryable rows should not ask for a retry")
        assertEqual(
            presentation.inlineDetail,
            "Turn on System Audio Recording in System Settings, then retry the meeting.",
            "the recovery detail should be visible inline instead of only in a tooltip"
        )
        assertFalse(presentation.canShowRetryAction, "non-retryable failures should not show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation explains retryable saved audio") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Model was not ready."
        )

        assertEqual(presentation.statusText, "Retry ready", "retryable rows should show that recovery is available")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is still here. Try again will transcribe it.",
            "retryable rows should make saved audio preservation visible"
        )
        assertTrue(presentation.canShowRetryAction, "retryable failures with audio should show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation stop-timeout retained audio appears retry-ready in Home") {
        let directory = makeFailedMeetingPresentationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let micURL = directory.appendingPathComponent("microphone.wav")
        let systemURL = directory.appendingPathComponent("system_audio.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8))

        let hasAudioFiles = FileManager.default.fileExists(atPath: micURL.path)
            && FileManager.default.fileExists(atPath: systemURL.path)
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: hasAudioFiles,
            detail: "Recording stop timed out before audio files were finalized."
        )

        assertEqual(
            MeetingFailureKind.classify(message: "Recording stop timed out before audio files were finalized."),
            .stopTimeout,
            "stop-timeout failures should keep their recovery category"
        )
        assertTrue(hasAudioFiles, "retained timeout audio should make the Home row retry-ready")
        assertEqual(presentation.statusText, "Retry ready", "Home should show that saved audio can be retried")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is still here. Try again will transcribe it.",
            "Home should make the recovery path visible"
        )
        assertTrue(presentation.canShowRetryAction, "retained stop-timeout audio should show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation blocks retries when audio is gone") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: false,
            detail: "Model was not ready."
        )

        assertEqual(presentation.statusText, "Audio missing", "missing audio should not look like a normal retry")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is missing, so this meeting cannot be retried.",
            "missing audio should explain why Try again is unavailable"
        )
        assertFalse(presentation.canShowRetryAction, "missing audio should suppress Try again")
    }

    runSuite("FailedMeetingPresentation speaker-name failures stay speaker-specific") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Speaker names could not be saved. The transcript saved, but speaker-name finalization failed.",
            shortErrorMessage: "Speaker names could not be saved.",
            isRetryable: true
        )

        assertEqual(copy.title, "Couldn't save speaker names", "speaker finalization failures should not look like full transcript failures")
        assertTrue(copy.detail.contains("transcript saved"), "copy should say the transcript itself was saved")
    }

    runSuite("FailedMeetingPresentation separates retained audio from retry-ready audio") {
        let source = (try? String(
            contentsOf: repoFixtureURL("Sources/Meeting/FailedMeetingPresentation.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            source.contains("let availableAudioURLs = audioURLs(for: failed)"),
            "available retained audio should stay separate from retry readiness"
        )
        assertTrue(
            source.contains("let hasRetryableAudioFiles = failed.audioFilesExist()"),
            "retry readiness should require all failed-transcription audio files"
        )
        assertTrue(
            source.contains("hasAudioFiles: hasRetryableAudioFiles"),
            "partial retained audio should not enable the retry action"
        )
    }

    runSuite("Home failed meeting row reveals partial audio separately from retry readiness") {
        let homeSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/HomeView.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            homeSource.contains("if hasRetainedAudioFiles {\n                Button {\n                    onRevealAudio()"),
            "failed rows should keep Show Audio visible when any retained audio URL exists"
        )
        assertTrue(
            homeSource.contains("private var retryDisabled: Bool {\n        FailedMeetingRecoveryPresentation.retryDisabled(\n            canRetry: canRetry,\n            isRetryable: item.isRetryable,\n            isRetrying: item.isRetrying,\n            hasAudioFiles: item.hasAudioFiles\n        )"),
            "failed rows should keep retry readiness tied to complete retryable audio, not mere visibility"
        )

        let recoveryPresentationSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/FailedMeetingRecoveryPresentation.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            recoveryPresentationSource.contains("!canRetry || !isRetryable || !hasAudioFiles || isRetrying"),
            "the shared retry-readiness helper Home delegates to should still require complete retryable audio"
        )
        assertTrue(
            homeSource.contains("private var hasRetainedAudioFiles: Bool {\n        !item.audioURLs.isEmpty"),
            "failed rows should use available retained audio URLs for the reveal affordance"
        )
    }

    runSuite("FailedMeetingPresentation labels retained WAVs as raw audio") {
        let source = (try? String(
            contentsOf: repoFixtureURL("Sources/Meeting/FailedMeetingPresentation.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            source.contains("pathExtension.localizedCaseInsensitiveCompare(\"wav\")"),
            "failed meeting metadata should detect retained WAV audio"
        )
        assertTrue(
            source.contains("availableAudioURLs.contains"),
            "failed meeting metadata should label raw audio from files that still exist"
        )
        assertTrue(
            source.contains("\"Raw audio kept\"")
                && source.contains("\"\\(sizeText) raw audio kept\""),
            "failed meeting metadata should label retained WAVs as raw audio"
        )
    }
}

private func makeFailedMeetingPresentationTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailedMeetingPresentationTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
