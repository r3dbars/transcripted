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
