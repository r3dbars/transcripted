import Foundation

/// Represents a transcription that failed and can be retried
struct FailedTranscription: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let micAudioURL: URL
    let systemAudioURL: URL?
    let errorMessage: String
    var retryCount: Int
    var lastRetryDate: Date?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String,
        retryCount: Int = 0,
        lastRetryDate: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.micAudioURL = micAudioURL
        self.systemAudioURL = systemAudioURL
        self.errorMessage = errorMessage
        self.retryCount = retryCount
        self.lastRetryDate = lastRetryDate
    }

    /// Returns a user-friendly formatted timestamp
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Returns a short error summary for display
    var shortErrorMessage: String {
        // Truncate long error messages
        if errorMessage.count > 100 {
            return String(errorMessage.prefix(97)) + "..."
        }
        return errorMessage
    }

    /// Whether this failure could succeed if retried.
    /// Uses PipelineError classification when available, falls back to keyword matching
    /// for entries persisted before typed errors were introduced.
    var isRetryable: Bool {
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
            "System audio is required"
        ]
        return !permanent.contains(where: { errorMessage.localizedCaseInsensitiveContains($0) })
    }

    /// Attempt to reconstruct the typed PipelineError from the stored message.
    /// Returns nil for legacy entries that don't match any known pattern.
    private var pipelineError: PipelineError? {
        if errorMessage.contains("no samples recorded") || errorMessage.contains("Empty audio file") {
            return .emptyAudioFile
        }
        if errorMessage.contains("Recording too short") || errorMessage.contains("at least") {
            return .recordingTooShort(duration: 0)
        }
        if errorMessage.contains("Invalid audio") {
            return .invalidAudioFormat(detail: errorMessage)
        }
        if errorMessage.contains("System audio is required") {
            return .missingSystemAudio
        }
        if errorMessage.contains("model not loaded") {
            return .modelNotLoaded(model: "Unknown")
        }
        if errorMessage.contains("Failed to save") {
            return .saveFailed(detail: errorMessage)
        }
        return nil
    }

    /// Checks if the audio files still exist on disk
    func audioFilesExist() -> Bool {
        let micExists = FileManager.default.fileExists(atPath: micAudioURL.path)
        if let systemURL = systemAudioURL {
            let systemExists = FileManager.default.fileExists(atPath: systemURL.path)
            return micExists && systemExists
        }
        return micExists
    }

    /// Returns the total size of audio files in bytes
    func totalAudioSize() -> Int64? {
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
    var formattedFileSize: String {
        guard let bytes = totalAudioSize() else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
