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

    // MARK: - failurePresentation(for:flow:) — what the failure call sites publish

    func testFailurePresentationRoutesTypedErrorsThroughTheKindTable() {
        // For every genuine typed PipelineError, the display message must come
        // from the per-flow kind table for the broad classification kind, the
        // diagnostic must match safeFailureDiagnosticMessage, and the persisted
        // errorKind must match the (narrower) failureKind(for:).
        let typedErrors: [(error: PipelineError, displayKind: PipelineErrorKind)] = [
            (.emptyAudioFile, .emptyAudioFile),
            (.microphoneAudioUnusable, .microphoneAudioUnusable),
            (.noSpeechDetected, .noSpeechDetected),
            (.recordingTooShort(duration: 0.5), .recordingTooShort),
            (.invalidAudioFormat(detail: "bad"), .invalidAudioFormat),
            (.missingSystemAudio, .missingSystemAudio),
            (.modelNotLoaded(model: "Parakeet"), .modelNotLoaded),
            (.modelInferenceFailed(model: "Parakeet", underlying: "boom"), .transcriptionInferenceFailed),
            (.saveFailed(detail: "disk full"), .saveFailed),
        ]

        for testCase in typedErrors {
            for flow in [PipelineFailureDisplayCopy.Flow.importedAudio, .savedAudioRetranscription] {
                let presentation = TranscriptionTaskManager.failurePresentation(for: testCase.error, flow: flow)
                XCTAssertEqual(
                    presentation.displayMessage,
                    PipelineFailureDisplayCopy.message(for: testCase.displayKind, flow: flow),
                    "display copy for \(testCase.error) should route through kind \(testCase.displayKind.rawValue)"
                )
                XCTAssertEqual(
                    presentation.diagnosticMessage,
                    TranscriptionTaskManager.safeFailureDiagnosticMessage(for: testCase.error)
                )
                XCTAssertEqual(
                    presentation.errorKind,
                    TranscriptionTaskManager.failureKind(for: testCase.error),
                    "persisted errorKind must stay the narrow typed-only classification"
                )
            }
        }
    }

    func testFailurePresentationTextFallbackAgreesWithDiagnosticMessageWrappers() {
        // Untyped errors take the text-classification fallback. The display
        // copy the call sites publish must agree with what the text-based
        // wrapper derives from the same diagnostic message — the typed and
        // text paths share one kind table, so they cannot drift.
        let untypedErrors: [Error] = [
            NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "TRANSCRIPTION ALREADY IN PROGRESS"]),
            NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Audio recording was too short — at least 2 seconds required"]),
            NSError(domain: "com.apple.coreaudio.avfaudio", code: -50, userInfo: [NSLocalizedDescriptionKey: "avfaudio error -50"]),
            NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "pyannote raised an internal error"]),
            NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Parakeet prediction failed at step 42"]),
            NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Something opaque happened in an unrelated subsystem"]),
        ]

        for error in untypedErrors {
            let imported = TranscriptionTaskManager.failurePresentation(for: error, flow: .importedAudio)
            XCTAssertEqual(
                imported.displayMessage,
                TranscriptionTaskManager.importedAudioFailureDisplayMessage(forDiagnosticMessage: imported.diagnosticMessage)
            )
            let saved = TranscriptionTaskManager.failurePresentation(for: error, flow: .savedAudioRetranscription)
            XCTAssertEqual(
                saved.displayMessage,
                TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(forDiagnosticMessage: saved.diagnosticMessage)
            )
            XCTAssertNil(imported.errorKind, "untyped errors must not persist an errorKind")
            XCTAssertNil(saved.errorKind, "untyped errors must not persist an errorKind")
        }
    }

    func testTypedModelInferenceFailureGetsInferenceSpecificDisplayCopy() {
        // Deliberate behavior change from the old string-matching chains: the
        // typed diagnostic is "Parakeet inference failed", which the old chains
        // failed to match (they only looked for "transcription inference
        // failed"), so typed inference failures showed the generic fallback.
        // Kind routing now shows the inference-specific copy on both flows.
        let error = PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "boom")

        let imported = TranscriptionTaskManager.failurePresentation(for: error, flow: .importedAudio)
        XCTAssertEqual(
            imported.displayMessage,
            "The local transcription model couldn't process that file. Try converting it to WAV or M4A and import again."
        )

        let saved = TranscriptionTaskManager.failurePresentation(for: error, flow: .savedAudioRetranscription)
        XCTAssertEqual(
            saved.displayMessage,
            "The local transcription model couldn't process that saved audio. Try again, or start a new recording if the retained audio is damaged."
        )
    }

    // MARK: - failureKind(for:) — narrower than safeFailureDiagnosticMessage
    //
    // `failureKind(for:)` only returns non-nil for a genuine typed
    // `PipelineError` (excluding `.unknown`, which just wraps free text).
    // It is deliberately NOT sourced from the same broad text-fallback net
    // `safeFailureDiagnosticMessage` uses for display messages — see the
    // "text-routed" tests below for why leaking that broad net into the
    // persisted `errorKind` would regress retryability/bucketing for
    // failures that never carried a typed `PipelineError`.

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

    func testFailureKindReturnsNilForUnknownPipelineError() {
        // .unknown(underlying:) just wraps free text in a PipelineError case —
        // it is not a genuine typed classification, so it must not persist a kind.
        XCTAssertNil(
            TranscriptionTaskManager.failureKind(
                for: PipelineError.unknown(underlying: "Transcription already in progress, please wait")
            )
        )
    }

    func testFailureKindReturnsNilForNonPipelineErrors() {
        // Table of (error, expected message) — safeFailureDiagnosticMessage still
        // classifies these broadly for display purposes, but none of them carry a
        // typed PipelineError, so failureKind(for:) must return nil for every one.
        let cases: [(error: Error, message: String)] = [
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "TRANSCRIPTION ALREADY IN PROGRESS"]),
                "Transcription already in progress"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "System audio recording permission is required"]),
                PipelineError.missingSystemAudio.localizedDescription
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Audio recording was too short — at least 2 seconds required"]),
                "Recording too short"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "No samples recorded"]),
                "Empty audio file"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "No speech detected in the recording"]),
                "No speech detected"
            ),
            (
                NSError(domain: "com.apple.coreaudio.avfaudio", code: -50, userInfo: [NSLocalizedDescriptionKey: "avfaudio error -50"]),
                "Invalid audio format"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to save the transcript to disk"]),
                "Failed to save transcript"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Speech model failed to load"]),
                "Model not loaded"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "pyannote raised an internal error"]),
                "Diarization failed"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Parakeet prediction failed at step 42"]),
                "Transcription inference failed"
            ),
            (
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Something opaque happened in an unrelated subsystem"]),
                "Pipeline failed"
            ),
        ]

        for testCase in cases {
            XCTAssertNil(
                TranscriptionTaskManager.failureKind(for: testCase.error),
                "expected nil errorKind for a non-PipelineError, got a kind for message: \(testCase.message)"
            )
            // The display message classifier is unaffected by this change.
            XCTAssertEqual(
                TranscriptionTaskManager.safeFailureDiagnosticMessage(for: testCase.error),
                testCase.message
            )
        }
    }

    // MARK: - Codex review regression: text-routed errors must not become
    // permanently non-retryable / misclassified via a persisted errorKind.
    //
    // Concrete regression this guards against: a raw CoreAudio NSError whose
    // description happens to contain "avfaudio"/"coreaudio" would, before this
    // fix, get classified by the broad display-message net as `.invalidAudioFormat`
    // and PERSISTED as `errorKind`, making `FailedTranscription.isRetryable` false
    // (Try Again hidden) for what was — on `main`, before typed errorKind existed —
    // a transient, retryable CoreAudio device error bucketed as `unexpected_error`.

    func testFailureKindIsNilForCoreAudioDeviceErrorText() {
        // Exact fixture already pinned by
        // testSafeFailureDiagnosticMessageClassifiesAvfaudioStringAsInvalidFormat.
        let error = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: -50,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. (com.apple.coreaudio.avfaudio error -50.)"]
        )

        XCTAssertNil(TranscriptionTaskManager.failureKind(for: error))

        let failed = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/pipeline-error-kind-regression-mic.wav"),
            systemAudioURL: nil,
            errorMessage: error.localizedDescription,
            errorKind: TranscriptionTaskManager.failureKind(for: error)
        )
        XCTAssertTrue(failed.isRetryable, "a transient CoreAudio device error should stay retryable, matching main")
    }

    func testFailureKindIsNilForBroadEmptyAudioVariantText() {
        // Broader than "empty audio file" / "no samples recorded" — matches the
        // display-message net's "empty audio" fragment but not the legacy
        // row-level parser's narrower "empty audio file" / "no samples recorded".
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Empty audio was captured from the input device"]
        )

        XCTAssertNil(TranscriptionTaskManager.failureKind(for: error))

        let failed = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/pipeline-error-kind-regression-mic.wav"),
            systemAudioURL: nil,
            errorMessage: error.localizedDescription,
            errorKind: TranscriptionTaskManager.failureKind(for: error)
        )
        XCTAssertTrue(failed.isRetryable, "a broad 'empty audio' variant not matching the legacy permanent list should stay retryable")
    }

    func testFailureKindIsNilForScreenRecordingVariantText() {
        // Matches the display-message net's "screen recording" fragment (used to
        // pick the missingSystemAudio display message) but not the legacy
        // row-level parser's permanent-failure keyword list, which only checks
        // "System audio is required" / "System Audio Recording" verbatim.
        let error = NSError(
            domain: "Test",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Recording stopped because Screen Recording access was revoked mid-capture"]
        )

        XCTAssertNil(TranscriptionTaskManager.failureKind(for: error))

        let failed = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/pipeline-error-kind-regression-mic.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/pipeline-error-kind-regression-system.wav"),
            errorMessage: error.localizedDescription,
            errorKind: TranscriptionTaskManager.failureKind(for: error)
        )
        XCTAssertTrue(failed.isRetryable, "a 'screen recording' variant not matching the legacy permanent list should stay retryable")
    }
}
