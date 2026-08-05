// PipelineErrorKindContractTests.swift
// Pins the typed `PipelineErrorKind` classification path against the legacy
// string-matching fallback so they cannot silently drift apart while the
// fallback still exists for pre-typed-error `FailedTranscription` entries.
// Also pins the per-flow `PipelineFailureDisplayCopy` table (golden copy for
// every kind in both the imported-audio and saved-audio-retranscription
// flows) now that display copy is routed by kind instead of re-matching the
// diagnostic message text.
//
// The canonical messages below are the exact strings
// `TranscriptionTaskManager.safeFailureDiagnosticMessage` produces for each
// `PipelineErrorKind` case (pinned independently by
// `TranscriptionPipelineErrorPolicyTests` in the TranscriptedCore SPM test
// target — that file and this one together cover the full typed-error ->
// canonical-message -> MeetingFailureKind chain, since `TranscriptionTaskManager`
// itself is not part of this fast-test runner's flat compile).

import Foundation

private let pipelineErrorKindCanonicalMessages: [(kind: PipelineErrorKind, message: String)] = [
    (.transcriptionAlreadyInProgress, "Transcription already in progress"),
    (.missingSystemAudio, "System audio is required. Please grant System Audio Recording permission in System Settings."),
    (.recordingTooShort, "Recording too short"),
    (.emptyAudioFile, "Empty audio file"),
    (.noSpeechDetected, "No speech detected"),
    (.invalidAudioFormat, "Invalid audio format"),
    (.microphoneAudioUnusable, "Microphone audio was not usable"),
    (.saveFailed, "Failed to save transcript"),
    (.modelNotLoaded, "Model not loaded"),
    (.diarizationFailed, "Diarization failed"),
    (.transcriptionInferenceFailed, "Transcription inference failed"),
    (.pipelineFailed, "Pipeline failed"),
]

// Golden per-flow display copy for every PipelineErrorKind, pinning the
// `PipelineFailureDisplayCopy` table that replaced the old per-flow
// string-matching chains in `TranscriptionTaskManager`. These strings are the
// exact copy those chains produced for each kind's canonical diagnostic
// message, with one deliberate improvement: `.transcriptionInferenceFailed`
// now shows its specific copy for typed model-inference failures too (the old
// chains only matched the text-classified "Transcription inference failed"
// diagnostic and dropped typed "<model> inference failed" to the generic
// fallback).
private let pipelineFailureDisplayCopyFixtures: [(kind: PipelineErrorKind, importedAudio: String, savedAudioRetranscription: String)] = [
    (
        .transcriptionAlreadyInProgress,
        "Another transcript is already running. Wait for it to finish, then import the file again.",
        "Another transcript is already running. Wait for it to finish, then try again."
    ),
    (
        .recordingTooShort,
        "That audio file is too short to transcribe. Choose audio that is at least two seconds long.",
        "That saved audio is too short to transcribe again."
    ),
    (
        .emptyAudioFile,
        "That audio file has no readable audio. Choose a different recording and try again.",
        "That saved audio has no readable audio. Try another saved recording."
    ),
    (
        .noSpeechDetected,
        "No speech was found in that audio file. Choose a file with clear spoken audio and try again.",
        "No speech was found in that saved audio. Try a recording with clearer spoken audio."
    ),
    (
        .invalidAudioFormat,
        "Transcripted couldn't read that audio file. Choose a WAV, MP3, M4A, AAC, or AIFF file.",
        "Transcripted couldn't read that saved audio. Try another retained recording."
    ),
    (
        .saveFailed,
        "Transcripted couldn't save the transcript. Check your capture folder and try again.",
        "Transcripted couldn't save the transcript. Check your capture folder and try again."
    ),
    (
        .modelNotLoaded,
        "The local transcription model was not ready. Try again after Models finishes loading.",
        "The local transcription model was not ready. Try again after Models finishes loading."
    ),
    (
        .diarizationFailed,
        "Transcripted couldn't separate speakers in that file. Try importing it again.",
        "Transcripted couldn't separate speakers in that saved audio. Try again with the retained recording."
    ),
    (
        .transcriptionInferenceFailed,
        "The local transcription model couldn't process that file. Try converting it to WAV or M4A and import again.",
        "The local transcription model couldn't process that saved audio. Try again, or start a new recording if the retained audio is damaged."
    ),
    // The next three had no branch in the old string-matching chains, so they
    // pin the generic per-flow fallback.
    (
        .missingSystemAudio,
        "Transcripted couldn't transcribe that audio file. Try converting it to WAV or M4A and import again.",
        "Transcripted couldn't re-transcribe that saved audio. Try again, or start a new recording if the retained audio is damaged."
    ),
    (
        .microphoneAudioUnusable,
        "Transcripted couldn't transcribe that audio file. Try converting it to WAV or M4A and import again.",
        "Transcripted couldn't re-transcribe that saved audio. Try again, or start a new recording if the retained audio is damaged."
    ),
    (
        .pipelineFailed,
        "Transcripted couldn't transcribe that audio file. Try converting it to WAV or M4A and import again.",
        "Transcripted couldn't re-transcribe that saved audio. Try again, or start a new recording if the retained audio is damaged."
    ),
]

private func makeFailedTranscription(errorMessage: String, errorKind: PipelineErrorKind?) -> FailedTranscription {
    FailedTranscription(
        micAudioURL: URL(fileURLWithPath: "/tmp/pipeline-error-kind-contract-mic.wav"),
        systemAudioURL: URL(fileURLWithPath: "/tmp/pipeline-error-kind-contract-system.wav"),
        errorMessage: errorMessage,
        errorKind: errorKind
    )
}

func testPipelineErrorKindContract() {
    runSuite("PipelineErrorKind covers every canonical safeFailureDiagnosticMessage bucket") {
        assertEqual(
            Set(pipelineErrorKindCanonicalMessages.map(\.kind)),
            Set(PipelineErrorKind.allCases),
            "every PipelineErrorKind case needs a canonical message fixture here, or the contract below silently skips it"
        )
    }

    for fixture in pipelineErrorKindCanonicalMessages {
        runSuite("PipelineErrorKind.\(fixture.kind.rawValue) — typed and legacy paths agree on MeetingFailureKind") {
            let typedResult = MeetingFailureKind.classify(errorKind: fixture.kind, message: fixture.message)
            let legacyResult = MeetingFailureKind.classify(errorKind: nil, message: fixture.message)

            assertEqual(
                typedResult,
                legacyResult,
                "typed kind \(fixture.kind.rawValue) classified as \(typedResult.rawValue) but legacy string matching on its canonical message classified as \(legacyResult.rawValue)"
            )
        }

        runSuite("PipelineErrorKind.\(fixture.kind.rawValue) — typed and legacy isRetryable agree") {
            let typedEntry = makeFailedTranscription(errorMessage: fixture.message, errorKind: fixture.kind)
            let legacyEntry = makeFailedTranscription(errorMessage: fixture.message, errorKind: nil)

            assertEqual(
                typedEntry.isRetryable,
                legacyEntry.isRetryable,
                "typed kind \(fixture.kind.rawValue) disagreed with legacy string matching on isRetryable for its canonical message"
            )
        }
    }

    runSuite("PipelineFailureDisplayCopy covers every PipelineErrorKind") {
        assertEqual(
            Set(pipelineFailureDisplayCopyFixtures.map(\.kind)),
            Set(PipelineErrorKind.allCases),
            "every PipelineErrorKind case needs a per-flow display copy fixture here, or the golden checks below silently skip it"
        )
    }

    for fixture in pipelineFailureDisplayCopyFixtures {
        runSuite("PipelineFailureDisplayCopy.\(fixture.kind.rawValue) — per-flow copy pinned") {
            assertEqual(
                PipelineFailureDisplayCopy.message(for: fixture.kind, flow: .importedAudio),
                fixture.importedAudio,
                "imported-audio display copy drifted for kind \(fixture.kind.rawValue)"
            )
            assertEqual(
                PipelineFailureDisplayCopy.message(for: fixture.kind, flow: .savedAudioRetranscription),
                fixture.savedAudioRetranscription,
                "saved-audio-retranscription display copy drifted for kind \(fixture.kind.rawValue)"
            )
        }

        runSuite("PipelineFailureDisplayCopy.\(fixture.kind.rawValue) — copy stays in its flow's lane") {
            let importedCopy = PipelineFailureDisplayCopy.message(for: fixture.kind, flow: .importedAudio).lowercased()
            let savedCopy = PipelineFailureDisplayCopy.message(for: fixture.kind, flow: .savedAudioRetranscription).lowercased()
            assertTrue(
                !savedCopy.contains("import"),
                "saved-audio failures must not tell the user to import the file again (kind \(fixture.kind.rawValue))"
            )
            assertTrue(
                !importedCopy.contains("saved audio"),
                "imported-audio failures must not reference saved audio (kind \(fixture.kind.rawValue))"
            )
        }
    }
}
