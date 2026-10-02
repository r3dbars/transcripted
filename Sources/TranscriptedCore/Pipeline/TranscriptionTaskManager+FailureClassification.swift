import Foundation

// MARK: - Failure classification: pipeline errors to PipelineErrorKind and display copy

extension TranscriptionTaskManager {
    public static func safeFailureDiagnosticMessage(for error: Error) -> String {
        failureClassification(for: error).message
    }

    /// Everything a failure call site publishes for a thrown pipeline error,
    /// derived from one classification pass.
    struct FailurePresentation {
        let displayMessage: String
        let diagnosticMessage: String
        /// The narrow typed kind that gets PERSISTED — see `failureKind(for:)`.
        /// nil for anything that didn't arrive as a genuine typed `PipelineError`,
        /// even though `displayMessage` still uses the broad text classification.
        let errorKind: PipelineErrorKind?
    }

    /// Classifies `error` once and routes the resulting `PipelineErrorKind`
    /// through the per-flow `PipelineFailureDisplayCopy` table, instead of
    /// re-deriving the failure bucket by string-matching the diagnostic
    /// message it just produced.
    ///
    /// One deliberate behavior change from the old string-matching chains:
    /// a typed `PipelineError.modelInferenceFailed` produces the diagnostic
    /// "<model> inference failed", which the old chains failed to match
    /// (they only looked for "transcription inference failed"), silently
    /// dropping typed inference failures to the generic fallback copy. The
    /// kind-routed table now shows the inference-specific copy for both the
    /// typed and text-classified paths.
    static func failurePresentation(for error: Error, flow: PipelineFailureDisplayCopy.Flow) -> FailurePresentation {
        let classification = failureClassification(for: error)
        return FailurePresentation(
            displayMessage: displayMessage(for: classification, flow: flow),
            diagnosticMessage: classification.message,
            errorKind: failureKind(for: error)
        )
    }

    /// Typed classification to PERSIST as `FailedTranscription.errorKind` —
    /// deliberately narrower than `safeFailureDiagnosticMessage(for:)`.
    ///
    /// This only returns non-nil when `error` is a genuine `PipelineError`
    /// case with the typed error actually in hand (excluding `.unknown`,
    /// which just wraps free text). Every other error — including any
    /// `PipelineError.unknown` — returns nil here, even though
    /// `safeFailureDiagnosticMessage` classifies a much broader set of
    /// free-form `NSError`/`localizedDescription` text for the *display*
    /// message. That broad text net must never leak into what gets
    /// persisted as `errorKind`: `FailedTranscription.isRetryable` and
    /// `MeetingFailureKind` trust `errorKind` over the legacy string
    /// fallback, and the legacy fallback's keyword net (in
    /// `FailedTranscription.legacyPipelineError` / `MeetingFailureKind
    /// .classify(message:)`) is intentionally much narrower than the
    /// display-message net — e.g. a raw CoreAudio `-50` NSError's
    /// description contains "avfaudio"/"coreaudio", which the display-message
    /// fallback recognizes as invalid-audio-format, but which the legacy
    /// retry-classification net does not, so on `main` that failure stayed
    /// retryable and bucketed as unexpected rather than becoming permanently
    /// non-retryable. Returning nil here for text-routed errors preserves
    /// that behavior: the caller keeps using the (unchanged) legacy fallback
    /// for anything that didn't arrive as a typed `PipelineError`.
    public static func failureKind(for error: Error) -> PipelineErrorKind? {
        guard let pipelineError = error as? PipelineError else { return nil }
        switch pipelineError {
        case .emptyAudioFile:
            return .emptyAudioFile
        case .microphoneAudioUnusable:
            return .microphoneAudioUnusable
        case .noSpeechDetected:
            return .noSpeechDetected
        case .recordingTooShort:
            return .recordingTooShort
        case .invalidAudioFormat:
            return .invalidAudioFormat
        case .missingSystemAudio:
            return .missingSystemAudio
        case .modelNotLoaded:
            return .modelNotLoaded
        case .modelInferenceFailed:
            // NOTE: legacy text classification would bucket an underlying
            // message naming a diarization model (e.g. "PyAnnote") as
            // `.diarizationFailed` instead. No current throw site passes a
            // diarization model name through `.modelInferenceFailed` — every
            // call site here is a transcription-model failure — so this is a
            // latent divergence, not an active one. If a diarization engine
            // ever starts throwing `.modelInferenceFailed`, this should
            // switch on the model name the same way the legacy text path
            // does, rather than assuming transcription.
            return .transcriptionInferenceFailed
        case .saveFailed:
            return .saveFailed
        case .unknown:
            // Free text wrapped in a PipelineError case, not a real typed
            // classification — treat it like any other untyped error.
            return nil
        }
    }

    /// Backs `safeFailureDiagnosticMessage(for:)` and the display-copy routing
    /// in `failurePresentation(for:flow:)`. Its `kind` half is the BROAD
    /// display classification — it is deliberately NOT the source of
    /// `failureKind(for:)` above, which uses its own narrower, typed-only
    /// switch instead of this text-inclusive one.
    private static func failureClassification(for error: Error) -> (kind: PipelineErrorKind, message: String) {
        if let pipelineError = error as? PipelineError {
            switch pipelineError {
            case .emptyAudioFile:
                return (.emptyAudioFile, "Empty audio file")
            case .microphoneAudioUnusable:
                return (.microphoneAudioUnusable, "Microphone audio was not usable")
            case .noSpeechDetected:
                return (.noSpeechDetected, "No speech detected")
            case .recordingTooShort:
                return (.recordingTooShort, "Recording too short")
            case .invalidAudioFormat:
                return (.invalidAudioFormat, "Invalid audio format")
            case .missingSystemAudio:
                return (.missingSystemAudio, PipelineError.missingSystemAudio.localizedDescription)
            case .modelNotLoaded(let model):
                return (.modelNotLoaded, "\(model) model not loaded")
            case .modelInferenceFailed(let model, _):
                // Assumes transcription, like failureKind(for:) — see the NOTE
                // there about the latent diarization-model-name divergence from
                // the legacy text net. Display copy inherits the same assumption.
                return (.transcriptionInferenceFailed, "\(model) inference failed")
            case .saveFailed:
                return (.saveFailed, "Failed to save transcript")
            case .unknown(let underlying):
                return failureClassification(forText: underlying)
            }
        }

        return failureClassification(forText: error.localizedDescription)
    }

    /// A capture with an explicit language can only be transcribed by a
    /// Whisper model (`STTRouter` refuses it on Parakeet). The fix is a
    /// settings change, so this guidance is published as-is instead of a
    /// bucket's generic copy. Must stay matchable by
    /// `isLanguageNeedsWhisperModelText` so the text wrappers agree.
    static let languageNeedsWhisperModelMessage =
        "Select a Whisper model in Settings to transcribe this recording in its saved language."

    private static func isLanguageNeedsWhisperModelText(_ normalized: String) -> Bool {
        normalized.contains("select a whisper model")
    }

    private static func displayMessage(
        for classification: (kind: PipelineErrorKind, message: String),
        flow: PipelineFailureDisplayCopy.Flow
    ) -> String {
        if classification.message == languageNeedsWhisperModelMessage {
            return languageNeedsWhisperModelMessage
        }
        return PipelineFailureDisplayCopy.message(for: classification.kind, flow: flow)
    }

    private static func failureClassification(forText message: String) -> (kind: PipelineErrorKind, message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("transcription already in progress") {
            return (.transcriptionAlreadyInProgress, "Transcription already in progress")
        }

        // Checked before the inference bucket below, which would otherwise
        // file this under "whisper" and show a vague model failure.
        if isLanguageNeedsWhisperModelText(normalized) {
            return (.pipelineFailed, languageNeedsWhisperModelMessage)
        }

        if normalized.contains(anyOf: [
            "system audio is required",
            "system audio recording",
            "screen recording",
        ]) {
            return (.missingSystemAudio, PipelineError.missingSystemAudio.localizedDescription)
        }

        if normalized.contains(anyOf: [
            "recording too short",
            "audio file is too short",
            "saved audio is too short",
            "audio is too short",
            "recording is too short",
            "too short to transcribe",
            "at least 1 second",
            "at least 2 seconds",
            "at least one second",
            "at least two seconds",
        ]) && (normalized.contains("audio") || normalized.contains("recording")) {
            return (.recordingTooShort, "Recording too short")
        }

        if normalized.contains(anyOf: [
            "empty audio",
            "empty audio file",
            "no samples recorded",
        ]) {
            return (.emptyAudioFile, "Empty audio file")
        }

        if normalized.contains(anyOf: [
            "no speech detected",
            "no speech was found",
        ]) {
            return (.noSpeechDetected, "No speech detected")
        }

        if normalized.contains(anyOf: [
            "invalid audio",
            "invalid audio data",
            "invalid audio format",
            "audio file has an invalid sample rate or channel count",
            "avaudiofile",
            "avfaudio error",
            "com.apple.coreaudio.avfaudio",
            "coreaudio error",
            "failed to create avaudioconverter",
        ]) {
            return (.invalidAudioFormat, "Invalid audio format")
        }

        if normalized.contains(anyOf: [
            "failed to save",
            "could not write transcript",
            "permission denied",
        ]) {
            return (.saveFailed, "Failed to save transcript")
        }

        if normalized.contains(anyOf: [
            "model not loaded",
            "models were not ready",
            "model failed to load",
            "speech model failed to load",
        ]) {
            return (.modelNotLoaded, "Model not loaded")
        }

        if normalized.contains(anyOf: [
            "pyannote",
            "sortformer",
            "wespeaker",
            "diarization",
        ]) {
            return (.diarizationFailed, "Diarization failed")
        }

        if normalized.contains(anyOf: [
            "asr",
            "core ml",
            "coreml",
            "failed to transcribe",
            "fluid",
            "inference",
            "mlmodel",
            "multiarray",
            "parakeet",
            "prediction",
            "preprocessor",
            "transcription failed",
            "whisper",
        ]) {
            return (.transcriptionInferenceFailed, "Transcription inference failed")
        }

        return (.pipelineFailed, "Pipeline failed")
    }

    // Text-based display-copy entry points, kept only for diagnostic strings
    // that arrive without the original error in hand. The production failure
    // paths classify the thrown error directly via `failurePresentation(for:flow:)`;
    // these reuse the same text classifier + kind table rather than a separate
    // string-matching chain.

    static func importedAudioFailureDisplayMessage(forDiagnosticMessage message: String) -> String {
        displayMessage(for: failureClassification(forText: message), flow: .importedAudio)
    }

    static func savedAudioRetranscriptionFailureDisplayMessage(forDiagnosticMessage message: String) -> String {
        displayMessage(for: failureClassification(forText: message), flow: .savedAudioRetranscription)
    }
}

private extension String {
    func contains(anyOf fragments: [String]) -> Bool {
        fragments.contains(where: contains)
    }
}
