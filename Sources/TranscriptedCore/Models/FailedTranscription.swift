import Foundation

/// Represents a transcription that failed and can be retried
public struct FailedTranscription: Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let micAudioURL: URL
    public let systemAudioURL: URL?
    public let errorMessage: String
    public let meetingTitle: String?
    public var retryCount: Int
    public var lastRetryDate: Date?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String? = nil,
        retryCount: Int = 0,
        lastRetryDate: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.micAudioURL = micAudioURL
        self.systemAudioURL = systemAudioURL
        self.errorMessage = errorMessage
        self.meetingTitle = meetingTitle
        self.retryCount = retryCount
        self.lastRetryDate = lastRetryDate
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

    /// Whether this failure could succeed if retried.
    /// Uses PipelineError classification when available, falls back to keyword matching
    /// for entries persisted before typed errors were introduced.
    public var isRetryable: Bool {
        if let typed = pipelineError {
            return typed.isRetryable
        }
        // Legacy fallback: keyword matching for pre-typed-error entries
        let permanent = [
            "Empty audio file",
            "no samples recorded",
            "at least 1 second",
            "Invalid audio data",
            "Recording too short",
            "Invalid audio format",
            "System audio is required",
            "System Audio Recording"
        ]
        return !permanent.contains(where: { errorMessage.localizedCaseInsensitiveContains($0) })
    }

    /// Attempt to reconstruct the typed PipelineError from the stored message.
    /// Returns nil for legacy entries that don't match any known pattern.
    private var pipelineError: PipelineError? {
        let normalized = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("no samples recorded") || normalized.contains("empty audio file") {
            return .emptyAudioFile
        }
        if Self.isRecordingTooShortMessage(normalized) {
            return .recordingTooShort(duration: 0)
        }
        if normalized.contains("invalid audio") {
            return .invalidAudioFormat(detail: errorMessage)
        }
        if normalized.contains("system audio is required")
            || normalized.contains("system audio recording") {
            return .missingSystemAudio
        }
        if normalized.contains("model not loaded") {
            return .modelNotLoaded(model: "Unknown")
        }
        if normalized.contains("failed to save") {
            return .saveFailed(detail: errorMessage)
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

        return message.contains("recording too short") || mentionsAudioMinimum
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
