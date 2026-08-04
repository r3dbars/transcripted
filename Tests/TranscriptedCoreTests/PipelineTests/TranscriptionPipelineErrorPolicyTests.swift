import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class TranscriptionPipelineErrorPolicyTests: XCTestCase {

    // MARK: - safeFailureDiagnosticMessage(for: PipelineError)

    func testSafeFailureDiagnosticMessageRoutesTypedAudioErrors() {
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.emptyAudioFile),
            "Empty audio file"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.noSpeechDetected),
            "No speech detected"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.recordingTooShort(duration: 0.5)),
            "Recording too short"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.invalidAudioFormat(detail: "bad")),
            "Invalid audio format"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.microphoneAudioUnusable),
            "Microphone audio was not usable"
        )
    }

    func testSafeFailureDiagnosticMessageRoutesTypedSystemAndModelErrors() {
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.missingSystemAudio),
            PipelineError.missingSystemAudio.localizedDescription
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.modelNotLoaded(model: "Parakeet")),
            "Parakeet model not loaded"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "boom")),
            "Parakeet inference failed"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: PipelineError.saveFailed(detail: "disk full")),
            "Failed to save transcript"
        )
    }

    func testSafeFailureDiagnosticMessageDelegatesUnknownPipelineErrorToTextClassifier() {
        // unknown(underlying:) is treated as freeform text — the classifier
        // should still recognize structured phrases inside the payload.
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.unknown(underlying: "Transcription already in progress, please wait")
            ),
            "Transcription already in progress"
        )
    }

    // MARK: - safeFailureDiagnosticMessage(for: Error) — text routing

    func testSafeFailureDiagnosticMessageClassifiesRecordingTooShortText() {
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Audio recording was too short — at least 2 seconds required"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
            "Recording too short"
        )
    }

    func testSafeFailureDiagnosticMessageClassifiesNoSpeechText() {
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "No speech detected in the recording"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
            "No speech detected"
        )
    }

    func testSafeFailureDiagnosticMessageClassifiesAvfaudioStringAsInvalidFormat() {
        let error = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: -50,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. (com.apple.coreaudio.avfaudio error -50.)"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
            "Invalid audio format"
        )
    }

    func testSafeFailureDiagnosticMessageClassifiesModelLoadFailure() {
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Speech model failed to load"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
            "Model not loaded"
        )
    }

    func testSafeFailureDiagnosticMessageClassifiesDiarizationVendorNames() {
        for vendor in ["pyannote", "Sortformer", "wespeaker"] {
            let error = NSError(
                domain: "Test",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "\(vendor) raised an internal error"]
            )
            XCTAssertEqual(
                TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
                "Diarization failed",
                "Expected diarization fallback for vendor: \(vendor)"
            )
        }
    }

    func testSafeFailureDiagnosticMessageClassifiesAsrInferenceFailures() {
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Parakeet prediction failed at step 42"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
            "Transcription inference failed"
        )
    }

    func testSafeFailureDiagnosticMessageFallsBackToGenericLabel() {
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Something opaque happened in an unrelated subsystem"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
            "Pipeline failed"
        )
    }

    func testSafeFailureDiagnosticMessageIsCaseInsensitive() {
        let upperCase = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "TRANSCRIPTION ALREADY IN PROGRESS"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: upperCase),
            "Transcription already in progress"
        )
    }

    func testSafeFailureDiagnosticMessageRequiresAudioContextForShortText() {
        // "at least 2 seconds" alone is too generic — the classifier requires
        // "audio" or "recording" co-occurrence before declaring too-short.
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Please wait at least 2 seconds before retrying"]
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(for: error),
            "Pipeline failed"
        )
    }

    // MARK: - savedAudioRetranscriptionFailureDisplayMessage

    func testSavedAudioRetranscriptionMessageMapsKnownDiagnostics() {
        let cases: [(diagnostic: String, expectedSubstring: String)] = [
            ("Transcription already in progress", "Wait for it to finish"),
            ("Recording too short", "too short to transcribe again"),
            ("Empty audio file", "no readable audio"),
            ("No speech detected", "No speech was found"),
            ("Invalid audio format", "couldn't read that saved audio"),
            ("Failed to save transcript", "Check your capture folder"),
            ("Model not loaded", "local transcription model was not ready"),
            ("Diarization failed", "couldn't separate speakers"),
            ("Transcription inference failed", "couldn't process that saved audio"),
        ]

        for testCase in cases {
            let actual = TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(
                forDiagnosticMessage: testCase.diagnostic
            )
            XCTAssertTrue(
                actual.contains(testCase.expectedSubstring),
                "Expected \"\(testCase.expectedSubstring)\" in mapping for \"\(testCase.diagnostic)\", got: \(actual)"
            )
        }
    }

    func testSavedAudioRetranscriptionMessageFallsBackToGenericRetryAdvice() {
        let actual = TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(
            forDiagnosticMessage: "Pipeline failed"
        )
        XCTAssertTrue(
            actual.contains("couldn't re-transcribe"),
            "Generic fallback should suggest re-transcribe, got: \(actual)"
        )
    }

    func testSavedAudioRetranscriptionMessageIsCaseInsensitive() {
        let actual = TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(
            forDiagnosticMessage: "RECORDING TOO SHORT"
        )
        XCTAssertTrue(
            actual.contains("too short to transcribe again"),
            actual
        )
    }

    func testSavedAudioRetranscriptionMessageTrimsWhitespacePadding() {
        let actual = TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(
            forDiagnosticMessage: "  \n  No speech detected  \n  "
        )
        XCTAssertTrue(
            actual.contains("No speech was found"),
            actual
        )
    }

    // MARK: - failureKind(for:) — computed alongside safeFailureDiagnosticMessage
    //
    // `failureKind(for:)` and `safeFailureDiagnosticMessage(for:)` share one
    // internal classification pass (`failureClassification(for:)`), so these
    // pin kind and message together for every error this function can see.
    // A future edit that changes one without the other breaks here first.

    func testFailureKindRoutesTypedAudioErrors() {
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.emptyAudioFile), .emptyAudioFile)
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.noSpeechDetected), .noSpeechDetected)
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.recordingTooShort(duration: 0.5)), .recordingTooShort)
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.invalidAudioFormat(detail: "bad")), .invalidAudioFormat)
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.microphoneAudioUnusable), .microphoneAudioUnusable)
    }

    func testFailureKindRoutesTypedSystemAndModelErrors() {
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.missingSystemAudio), .missingSystemAudio)
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.modelNotLoaded(model: "Parakeet")), .modelNotLoaded)
        XCTAssertEqual(
            TranscriptionTaskManager.failureKind(for: PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "boom")),
            .transcriptionInferenceFailed
        )
        XCTAssertEqual(TranscriptionTaskManager.failureKind(for: PipelineError.saveFailed(detail: "disk full")), .saveFailed)
    }

    func testFailureKindDelegatesUnknownPipelineErrorToTextClassifier() {
        XCTAssertEqual(
            TranscriptionTaskManager.failureKind(
                for: PipelineError.unknown(underlying: "Transcription already in progress, please wait")
            ),
            .transcriptionAlreadyInProgress
        )
    }

    func testFailureKindClassifiesTextRoutedErrorsConsistentlyWithTheirMessage() {
        // Table of (error, expected kind, expected message) — every entry here
        // exercises the same classification pass safeFailureDiagnosticMessage
        // uses, so kind and message can never silently disagree.
        let cases: [(error: Error, kind: PipelineErrorKind, message: String)] = [
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "TRANSCRIPTION ALREADY IN PROGRESS"]),
                .transcriptionAlreadyInProgress,
                "Transcription already in progress"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "System audio recording permission is required"]),
                .missingSystemAudio,
                PipelineError.missingSystemAudio.localizedDescription
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Audio recording was too short — at least 2 seconds required"]),
                .recordingTooShort,
                "Recording too short"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "No samples recorded"]),
                .emptyAudioFile,
                "Empty audio file"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "No speech detected in the recording"]),
                .noSpeechDetected,
                "No speech detected"
            ),
            (
                NSError(domain: "com.apple.coreaudio.avfaudio", code: -50, userInfo: [NSLocalizedDescriptionKey: "avfaudio error -50"]),
                .invalidAudioFormat,
                "Invalid audio format"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to save the transcript to disk"]),
                .saveFailed,
                "Failed to save transcript"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Speech model failed to load"]),
                .modelNotLoaded,
                "Model not loaded"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "pyannote raised an internal error"]),
                .diarizationFailed,
                "Diarization failed"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Parakeet prediction failed at step 42"]),
                .transcriptionInferenceFailed,
                "Transcription inference failed"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Something opaque happened in an unrelated subsystem"]),
                .pipelineFailed,
                "Pipeline failed"
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                TranscriptionTaskManager.failureKind(for: testCase.error),
                testCase.kind,
                "kind mismatch for message: \(testCase.message)"
            )
            XCTAssertEqual(
                TranscriptionTaskManager.safeFailureDiagnosticMessage(for: testCase.error),
                testCase.message
            )
        }
    }

    func testFailureKindCoversEveryPipelineErrorKindCase() {
        // Every PipelineErrorKind case must be reachable from this classifier —
        // an unreachable case would be dead weight nothing could ever set.
        let reachableKinds = Set(
            TranscriptionPipelineErrorPolicyTests_allCanonicalErrors.map {
                TranscriptionTaskManager.failureKind(for: $0)
            }
        )
        XCTAssertEqual(reachableKinds, Set(PipelineErrorKind.allCases))
    }
}

private let TranscriptionPipelineErrorPolicyTests_allCanonicalErrors: [Error] = [
    PipelineError.emptyAudioFile,
    PipelineError.microphoneAudioUnusable,
    PipelineError.noSpeechDetected,
    PipelineError.recordingTooShort(duration: 0.5),
    PipelineError.invalidAudioFormat(detail: "bad"),
    PipelineError.missingSystemAudio,
    PipelineError.modelNotLoaded(model: "Parakeet"),
    PipelineError.saveFailed(detail: "disk full"),
    NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "TRANSCRIPTION ALREADY IN PROGRESS"]),
    NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "pyannote raised an internal error"]),
    NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Parakeet prediction failed at step 42"]),
    NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Something opaque happened in an unrelated subsystem"]),
]
