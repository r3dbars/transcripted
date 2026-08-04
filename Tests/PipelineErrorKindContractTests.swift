// PipelineErrorKindContractTests.swift
// Pins the typed `PipelineErrorKind` classification path against the legacy
// string-matching fallback so they cannot silently drift apart while the
// fallback still exists for pre-typed-error `FailedTranscription` entries.
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
}
