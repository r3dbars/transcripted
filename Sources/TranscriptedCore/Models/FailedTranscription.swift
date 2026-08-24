import Foundation

/// Stable, persistable classification of a pipeline failure.
///
/// This is the single source of truth for "what kind of failure was this"
/// once a typed `PipelineError` (or an error `TranscriptionTaskManager` can
/// otherwise classify) is in hand. It replaces re-deriving the same meaning
/// from `errorMessage` strings in multiple independent places.
///
/// Cases mirror the buckets `TranscriptionTaskManager.safeFailureDiagnosticMessage`
/// already distinguishes (see its switch over `PipelineError` plus its text
/// fallback), because that is the one place a typed Swift `Error` is still in
/// hand when a failure is classified. Downstream consumers such as
/// `MeetingFailureKind` fold these into their own broader taxonomy — which
/// also covers failure sources (permission gates, import preparation, stop
/// timeouts, ...) that never produce a `PipelineError` and so never populate
/// this field; those stay on the legacy string-matching fallback.
///
/// Raw values are persisted (`FailedTranscription.errorKind`) and must stay
/// stable — do not rename or reuse a raw value for a different meaning.
public enum PipelineErrorKind: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case transcriptionAlreadyInProgress = "transcription_already_in_progress"
    case missingSystemAudio = "missing_system_audio"
    case recordingTooShort = "recording_too_short"
    case emptyAudioFile = "empty_audio_file"
    case noSpeechDetected = "no_speech_detected"
    case invalidAudioFormat = "invalid_audio_format"
    case microphoneAudioUnusable = "microphone_audio_unusable"
    case saveFailed = "save_failed"
    case modelNotLoaded = "model_not_loaded"
    case diarizationFailed = "diarization_failed"
    case transcriptionInferenceFailed = "transcription_inference_failed"
    case pipelineFailed = "pipeline_failed"

    /// Whether this failure could succeed if retried, independent of
    /// message text. Mirrors `PipelineError.isRetryable`.
    public var isRetryable: Bool {
        switch self {
        case .emptyAudioFile, .microphoneAudioUnusable, .noSpeechDetected, .recordingTooShort, .invalidAudioFormat, .missingSystemAudio:
            return false
        case .transcriptionAlreadyInProgress, .modelNotLoaded, .diarizationFailed, .transcriptionInferenceFailed, .saveFailed, .pipelineFailed:
            return true
        }
    }

    /// Whether this failure describes **one capture source** breaking rather
    /// than the recording having nothing in it to transcribe.
    ///
    /// This is deliberately a different question from `isRetryable`. That
    /// property answers "was the error itself transient", which is what the
    /// pipeline needs while an error is in flight. A *saved* failed row is a
    /// different situation: the audio is still on disk, and the current
    /// pipeline drops an unusable microphone and continues with whatever else
    /// survived (`TranscriptionPipeline` — an unreadable or silent mic track
    /// becomes a system-audio-only run, not a thrown error).
    ///
    /// So a row labelled `microphoneAudioUnusable` is very often transcribable
    /// today even though the error was correctly classified as permanent when
    /// it was thrown by an older build. Rows whose audio genuinely holds
    /// nothing (`noSpeechDetected`, `recordingTooShort`) stay permanent —
    /// retrying those can only burn inference time to reproduce the same
    /// failure.
    public var describesRecoverableSource: Bool {
        switch self {
        case .emptyAudioFile, .microphoneAudioUnusable, .invalidAudioFormat, .missingSystemAudio:
            return true
        case .noSpeechDetected, .recordingTooShort:
            return false
        case .transcriptionAlreadyInProgress, .modelNotLoaded, .diarizationFailed, .transcriptionInferenceFailed, .saveFailed, .pipelineFailed:
            return false
        }
    }
}

/// Represents a transcription that failed and can be retried
public struct FailedTranscription: Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let recordingDate: Date?
    public var micAudioURL: URL
    public var systemAudioURL: URL?
    public var errorMessage: String
    public let meetingTitle: String?
    public var retryCount: Int
    public var lastRetryDate: Date?
    /// Typed classification captured at the point the original error was thrown.
    /// `nil` for entries persisted before this field existed, or for failures
    /// that never carried a typed `PipelineError` (e.g. permission/import
    /// failures) — those keep classifying through the legacy string fallback.
    public var errorKind: PipelineErrorKind?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        recordingDate: Date? = nil,
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String? = nil,
        retryCount: Int = 0,
        lastRetryDate: Date? = nil,
        errorKind: PipelineErrorKind? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.recordingDate = recordingDate
        self.micAudioURL = micAudioURL
        self.systemAudioURL = systemAudioURL
        self.errorMessage = errorMessage
        self.meetingTitle = meetingTitle
        self.retryCount = retryCount
        self.lastRetryDate = lastRetryDate
        self.errorKind = errorKind
    }

    /// Returns a user-friendly formatted timestamp
    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Returns a short error summary for display
    public var shortErrorMessage: String {
        // Truncate long error messages
        if errorMessage.count > 100 {
            return String(errorMessage.prefix(97)) + "..."
        }
        return errorMessage
    }

    /// Whether this row is worth offering a retry for.
    ///
    /// A saved failed row still has its audio on disk, so the question is not
    /// "was the original error transient" but "could the current pipeline make
    /// a transcript out of what survived". Single-source failures qualify
    /// (see `PipelineErrorKind.describesRecoverableSource`); failures whose
    /// audio genuinely holds nothing do not.
    ///
    /// This intentionally does not inspect the audio itself — it must stay
    /// cheap enough to evaluate on every list refresh. Whether the surviving
    /// files actually contain audible signal is answered separately and
    /// asynchronously by `FailedRecordingSignalProbe`, and callers gate the
    /// retry affordance on both.
    ///
    /// Uses the typed `errorKind` when available (captured at throw time).
    /// Legacy fallback: keyword matching for entries persisted before typed
    /// errors were introduced, used only when `errorKind` is nil.
    public var isRetryable: Bool {
        if let errorKind {
            return errorKind.isRetryable || errorKind.describesRecoverableSource
        }
        return legacyIsRetryable
    }

    /// Legacy fallback: keyword matching for pre-typed-error entries.
    ///
    /// These rows are the main reason this policy changed. They were written by
    /// builds whose pipeline aborted when one capture source broke, so their
    /// messages describe a limitation that no longer exists — a row saying the
    /// microphone was unusable is usually sitting on perfectly good system
    /// audio. Only the genuinely content-empty messages stay permanent.
    private var legacyIsRetryable: Bool {
        if let kind = legacyErrorKind {
            return kind.isRetryable || kind.describesRecoverableSource
        }
        let permanent = [
            "No speech detected",
            "at least 1 second",
            "Recording too short"
        ]
        return !permanent.contains(where: { errorMessage.localizedCaseInsensitiveContains($0) })
    }

    /// Legacy fallback: reconstruct the failure classification from the stored
    /// message via keyword matching. Returns nil for legacy entries that don't
    /// match any known pattern. Used only when `errorKind` is nil.
    private var legacyErrorKind: PipelineErrorKind? {
        let normalized = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("no samples recorded") || normalized.contains("empty audio file") {
            return .emptyAudioFile
        }
        if normalized.contains("microphone audio was not usable") {
            return .microphoneAudioUnusable
        }
        if normalized.contains("no speech detected") || normalized.contains("no speech was found") {
            return .noSpeechDetected
        }
        if Self.isRecordingTooShortMessage(normalized) {
            return .recordingTooShort
        }
        if normalized.contains("invalid audio") {
            return .invalidAudioFormat
        }
        if normalized.contains("system audio is required")
            || normalized.contains("system audio recording") {
            return .missingSystemAudio
        }
        if normalized.contains("model not loaded") {
            return .modelNotLoaded
        }
        if normalized.contains("failed to save") {
            return .saveFailed
        }
        return nil
    }

    private static func isRecordingTooShortMessage(_ message: String) -> Bool {
        let mentionsAudioMinimum = (
            message.contains("at least 1 second")
                || message.contains("at least 2 seconds")
                || message.contains("at least one second")
                || message.contains("at least two seconds")
        ) && (message.contains("audio") || message.contains("recording"))
        let mentionsTooShortAudio = (
            message.contains("audio file is too short")
                || message.contains("saved audio is too short")
                || message.contains("audio is too short")
                || message.contains("recording is too short")
                || message.contains("too short to transcribe")
        )

        return message.contains("recording too short") || mentionsTooShortAudio || mentionsAudioMinimum
    }

    /// Checks if the audio files still exist on disk
    public func audioFilesExist() -> Bool {
        let micExists = FileManager.default.fileExists(atPath: micAudioURL.path)
        if let systemURL = systemAudioURL {
            let systemExists = FileManager.default.fileExists(atPath: systemURL.path)
            return micExists && systemExists
        }
        return micExists
    }

    /// Returns the total size of audio files in bytes
    public func totalAudioSize() -> Int64? {
        var totalSize: Int64 = 0

        do {
            let micAttributes = try FileManager.default.attributesOfItem(atPath: micAudioURL.path)
            if let micSize = micAttributes[.size] as? Int64 {
                totalSize += micSize
            }

            if let systemURL = systemAudioURL {
                let systemAttributes = try FileManager.default.attributesOfItem(atPath: systemURL.path)
                if let systemSize = systemAttributes[.size] as? Int64 {
                    totalSize += systemSize
                }
            }

            return totalSize
        } catch {
            return nil
        }
    }

    /// Returns formatted file size string (e.g., "25.3 MB")
    public var formattedFileSize: String {
        guard let bytes = totalAudioSize() else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
