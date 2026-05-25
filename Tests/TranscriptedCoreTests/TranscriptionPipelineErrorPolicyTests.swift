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
}
