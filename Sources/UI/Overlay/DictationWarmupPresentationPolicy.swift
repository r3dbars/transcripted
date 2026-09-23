import Foundation

/// User-facing copy for the dictation voice-model warmup overlay.
///
/// The same model states read very differently depending on when they happen:
/// before recording the user is waiting for the mic to open, but after they
/// stop they have already spoken and need to know the recording is safe and
/// will be transcribed as soon as the model is ready.
enum DictationWarmupPresentationPolicy {
    enum Phase: Equatable {
        /// Warmup before recording has started — dictation will start on its own.
        case beforeRecording
        /// Warmup after the user stopped — audio is captured and waiting to transcribe.
        case afterRecording
    }

    struct Copy: Equatable {
        let title: String
        let detail: String
        let progress: Double
        let status: String?
    }

    static func copy(modelState: ParakeetModelState, phase: Phase) -> Copy {
        switch phase {
        case .beforeRecording:
            return beforeRecordingCopy(modelState: modelState)
        case .afterRecording:
            return afterRecordingCopy(modelState: modelState)
        }
    }

    private static let startsAutomaticallyDetail =
        "Dictation starts automatically as soon as the voice model is ready."
    private static let recordingSafeDetail =
        "Your recording is safe — transcription starts as soon as the voice model is ready."

    private static func downloadProgress(_ progress: Double) -> Double {
        max(0.12, min(0.84, 0.12 + progress * 0.72))
    }

    private static func downloadStatus(_ progress: Double) -> String {
        "\(Int(progress * 100))% downloaded"
    }

    private static func beforeRecordingCopy(modelState: ParakeetModelState) -> Copy {
        switch modelState {
        case .notLoaded:
            return Copy(
                title: "Warming up",
                detail: startsAutomaticallyDetail,
                progress: 0.08,
                status: "Preparing the voice model"
            )
        case .downloading(let progress):
            return Copy(
                title: "Downloading the voice model",
                detail: "One-time setup. Dictation starts automatically when it finishes.",
                progress: downloadProgress(progress),
                status: downloadStatus(progress)
            )
        case .cached:
            return Copy(
                title: "Warming up",
                detail: startsAutomaticallyDetail,
                progress: 0.88,
                status: "Loading the voice model"
            )
        case .loading:
            return Copy(
                title: "Warming up",
                detail: startsAutomaticallyDetail,
                progress: 0.92,
                status: "Almost ready"
            )
        case .ready:
            return Copy(
                title: "Starting dictation",
                detail: "The voice model is ready — opening the microphone.",
                progress: 1.0,
                status: "Starting microphone"
            )
        case .failed(let message):
            return Copy(
                title: "Dictation couldn't start",
                detail: message,
                progress: 0,
                status: "The voice model didn't load"
            )
        }
    }

    private static func afterRecordingCopy(modelState: ParakeetModelState) -> Copy {
        switch modelState {
        case .notLoaded:
            return Copy(
                title: "Getting ready to transcribe",
                detail: recordingSafeDetail,
                progress: 0.08,
                status: "Warming up the voice model"
            )
        case .downloading(let progress):
            return Copy(
                title: "Downloading the voice model",
                detail: "Your recording is safe. Transcription starts when the download finishes.",
                progress: downloadProgress(progress),
                status: downloadStatus(progress)
            )
        case .cached:
            return Copy(
                title: "Getting ready to transcribe",
                detail: recordingSafeDetail,
                progress: 0.88,
                status: "Loading the voice model"
            )
        case .loading:
            return Copy(
                title: "Getting ready to transcribe",
                detail: recordingSafeDetail,
                progress: 0.92,
                status: "Almost ready"
            )
        case .ready:
            return Copy(
                title: "Transcribing",
                detail: "Turning your words into text.",
                progress: 1.0,
                status: nil
            )
        case .failed(let message):
            return Copy(
                title: "Transcription couldn't start",
                detail: message,
                progress: 0,
                status: "The voice model didn't load"
            )
        }
    }
}

/// What happens when the user stopped before the voice model was ready and
/// the stop path had to wait for it (for example a first-run download or a
/// Whisper load).
enum DictationPostStopModelWaitPolicy {
    /// Past this wait, paste-back keeps the app the user dictated into instead
    /// of following focus to whatever is in front now. The user has most
    /// likely moved on, and a moved focus then lands the text on the
    /// clipboard rather than in an unrelated app.
    static let pasteFollowsFocusMaxWait: TimeInterval = 10

    static func pasteFollowsCurrentFocus(modelWaitSeconds: TimeInterval) -> Bool {
        modelWaitSeconds < pasteFollowsFocusMaxWait
    }

    /// Error copy when the model still isn't ready after the wait budget.
    /// The stopped audio is checkpointed before the wait, so say so when it is.
    static func modelUnavailableMessage(recordingSaved: Bool) -> String {
        guard recordingSaved else {
            return "The voice model didn't load. Please try dictating again in a moment."
        }
        return "The voice model didn't load in time, but your recording is saved. Retry it with Capture → Transcribe Audio File once the model is ready."
    }
}
