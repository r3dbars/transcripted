import Foundation

// Pure display/classification contracts. These cases never construct a
// transcription manager, speech router, model, preference store or view.
func testRecoveryLanguageGuidance() {
    let guidance = "Select a model in Settings that supports this recording's saved language, then retry."
    let title = "Choose a compatible model"
    let detail = "This meeting's saved language isn't supported by the selected model. Pick a model that supports it under Model in Settings > General, then retry."

    runSuite("Saved-language recovery guidance describes compatibility instead of prescribing one engine") {
        assertEqual(PipelineFailureDisplayCopy.languageModelGuidance, guidance, "the canonical guidance leaves model choice to language compatibility")
        assertTrue(
            PipelineFailureDisplayCopy.isLanguageModelGuidance(PipelineFailureDisplayCopy.languageModelGuidance.lowercased()),
            "the canonical phrase must recognize its own normalized output"
        )
        assertFalse(guidance.lowercased().contains("whisper"), "do not exclude another compatible model")
        assertFalse(guidance.lowercased().contains("apple speech"), "do not suggest Apple Speech for an unsupported language")
    }

    runSuite("Explicit-language unsupported copy retains Automatic without prescribing Whisper") {
        assertEqual(
            TranscriptionLanguageError.explicitLanguageUnsupported.errorDescription,
            "This transcription engine does not support a selected language. Select a model that supports it or use Automatic.",
            "retain both a compatible model and Automatic as choices without changing language routing"
        )
    }

    let unsupportedLanguageError = TranscriptionLanguageError.explicitLanguageUnsupported
    let legacyMessages = [
        "This transcription engine does not support a selected language. Select Whisper or use Automatic.",
        unsupportedLanguageError.errorDescription ?? "Missing explicit-language error description",
        unsupportedLanguageError.localizedDescription,
        "This recording has a saved language choice. Select a Whisper model in Settings to transcribe it in that language.",
        "Select a Whisper model in Settings to transcribe this recording in its saved language.",
        "This recording has a saved language choice. Select a Whisper model or Apple Speech in Settings to transcribe it in that language.",
        "Apple Speech can't transcribe Finnish. Select a Whisper model in Settings to transcribe this recording in that language."
    ]
    runSuite("The actual unsupported-language error remains actionable through its public descriptions") {
        assertEqual(unsupportedLanguageError.errorDescription, unsupportedLanguageError.localizedDescription,
                    "Foundation must retain the explicit-language error's public recovery copy")
        assertTrue(PipelineFailureDisplayCopy.isLanguageModelGuidance(unsupportedLanguageError.localizedDescription.lowercased()),
                   "the actual error must not depend on a legacy engine name to retain actionable recovery guidance")
        assertEqual(MeetingFailureKind.classify(message: unsupportedLanguageError.localizedDescription),
                    .languageNeedsWhisperModel, "the actual public error must reach compatible-model recovery")
    }

    for message in [guidance] + legacyMessages {
        runSuite("Saved-language recovery retains the stable failure bucket for \(message)") {
            assertTrue(
                PipelineFailureDisplayCopy.isLanguageModelGuidance(message.lowercased()),
                "new and retained legacy guidance share the pure recognition rule"
            )
            for variant in [message, message.uppercased(), "Retry failed: \(message)", "  \(message)\n"] {
                let kind = MeetingFailureKind.classify(message: variant)
                assertEqual(kind, .languageNeedsWhisperModel, "wrappers and case must preserve the saved-language root cause")
                assertEqual(kind.rawValue, "language_needs_whisper_model", "display copy must not rename persisted or telemetry identifiers")
                assertEqual(MeetingFailureKind(rawValue: kind.rawValue), .languageNeedsWhisperModel, "existing raw identifiers still round-trip")
            }
        }
    }

    for message in [guidance] + legacyMessages {
        runSuite("Saved-language recovery presents compatible-model copy for new and old failures — \(message)") {
            let copy = MeetingFailureCopy.make(forMessage: message, shortErrorMessage: message, isRetryable: true)
            assertEqual(copy.title, title, "a legacy error must not restore the old Whisper-only title")
            assertEqual(copy.detail, detail, "explain the saved-language mismatch and actual picker location")
            assertFalse(copy.title.lowercased().contains("whisper"))
            assertFalse(copy.detail.lowercased().contains("whisper"))
            assertFalse(copy.detail.lowercased().contains("apple speech"), "neutral copy must not promise an unsupported engine can handle Finnish")
        }
    }

    runSuite("Home saved-language retry guidance stays neutral about engine support") {
        let reason = HomeFailedMeetingInlinePresentation.retryReason(for: .languageNeedsWhisperModel)
        assertTrue(reason != nil, "Home must retain actionable retry guidance")
        if let reason {
            let normalized = reason.lowercased()
            assertTrue(normalized.contains("model"), "point to choosing a compatible model")
            assertTrue(normalized.contains("language"), "preserve the recording-language cause")
            assertFalse(normalized.contains("whisper"), "Home must not send every saved language to Whisper only")
            assertFalse(normalized.contains("apple speech"), "Home must not promise Apple Speech supports every saved language")
            let inline = HomeFailedMeetingInlinePresentation.make(
                isRetryable: true, isRetrying: false, hasAudioFiles: true,
                detail: guidance, failureKind: .languageNeedsWhisperModel
            )
            assertEqual(inline.inlineDetail, reason, "the actual Home retry surface uses the same neutral reason")
            assertTrue(inline.canShowRetryAction, "correcting copy must retain retry")
        }
    }

    runSuite("Saved-language guidance does not steal unrelated inference or busy failures") {
        let unrelated: [(String, MeetingFailureKind)] = [
            ("Parakeet inference failed: synthetic shape mismatch", .transcriptionInferenceFailed),
            ("Retry failed: Parakeet inference failed", .transcriptionInferenceFailed),
            ("Transcription already in progress", .pipelineBusy),
            ("Select a model in Settings to improve quality.", .unexpectedError)
        ]
        for (message, expected) in unrelated {
            assertFalse(PipelineFailureDisplayCopy.isLanguageModelGuidance(message.lowercased()), "model wording alone is not saved-language guidance")
            assertEqual(MeetingFailureKind.classify(message: message), expected, "preserve unrelated typed failure buckets")
        }
    }
}
