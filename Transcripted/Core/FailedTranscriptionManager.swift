import Foundation
import Combine

/// Manages the queue of failed transcriptions with persistent storage
@MainActor
class FailedTranscriptionManager: ObservableObject {
    @Published var failedTranscriptions: [FailedTranscription] = []

    private let storageURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        // Store failed transcriptions JSON in Documents/Transcripted folder
        // Guard against force unwrap: FileManager.urls() is empty in restricted sandboxes
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            AppLogger.pipeline.error("Documents directory unavailable — failed transcription queue disabled")
            self.storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("failed_transcriptions.json")
            return
        }
        let transcriptedFolder = documentsURL.appendingPathComponent("Transcripted")

        // Create Transcripted folder if it doesn't exist
        try? FileManager.default.createDirectory(at: transcriptedFolder, withIntermediateDirectories: true)

        self.storageURL = transcriptedFolder.appendingPathComponent("failed_transcriptions.json")

        // Configure date encoding/decoding
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Load existing failed transcriptions and auto-clean permanent failures
        loadFailedTranscriptions()
        cleanupPermanentFailures()
    }

    /// Loads failed transcriptions from disk
    private func loadFailedTranscriptions() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            AppLogger.pipeline.debug("No existing failed transcriptions file")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try decoder.decode([FailedTranscription].self, from: data)

            // Filter out entries where audio files no longer exist
            failedTranscriptions = loaded.filter { $0.audioFilesExist() }

            // Save back if we filtered any out
            if failedTranscriptions.count != loaded.count {
                AppLogger.pipeline.info("Removed entries with missing audio files", ["count": "\(loaded.count - failedTranscriptions.count)"])
                saveFailedTranscriptions()
            }

            AppLogger.pipeline.info("Loaded failed transcriptions", ["count": "\(failedTranscriptions.count)"])
        } catch {
            // Backup corrupt file before it gets overwritten on next save
            let backupURL = storageURL.deletingLastPathComponent().appendingPathComponent("failed_transcriptions_backup.json")
            try? FileManager.default.copyItem(at: storageURL, to: backupURL)
            AppLogger.pipeline.error("Corrupt failed transcriptions file, backed up", ["error": "\(error)"])
        }
    }

    /// Saves failed transcriptions to disk
    private func saveFailedTranscriptions() {
        do {
            let data = try encoder.encode(failedTranscriptions)
            try data.write(to: storageURL, options: .atomic)
            AppLogger.pipeline.info("Saved failed transcriptions", ["count": "\(failedTranscriptions.count)"])
        } catch {
            AppLogger.pipeline.error("Error saving failed transcriptions", ["error": "\(error)"])
        }
    }

    /// Adds a new failed transcription to the queue
    func addFailedTranscription(
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String
    ) {
        let failed = FailedTranscription(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage
        )

        failedTranscriptions.append(failed)
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Added failed transcription", ["id": "\(failed.id)"])
    }

    /// Removes a failed transcription from the queue
    func removeFailedTranscription(id: UUID) {
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        failedTranscriptions.remove(at: index)
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Removed failed transcription", ["id": "\(id)"])
    }

    /// Removes a failed transcription and deletes its audio files
    func deleteFailedTranscription(id: UUID) {
        guard let failed = failedTranscriptions.first(where: { $0.id == id }) else {
            return
        }

        // Delete audio files
        do {
            try FileManager.default.removeItem(at: failed.micAudioURL)
            AppLogger.pipeline.info("Deleted mic audio", ["file": failed.micAudioURL.lastPathComponent])

            if let systemURL = failed.systemAudioURL {
                try? FileManager.default.removeItem(at: systemURL)
                AppLogger.pipeline.info("Deleted system audio", ["file": systemURL.lastPathComponent])
            }
        } catch {
            AppLogger.pipeline.error("Error deleting audio files", ["error": "\(error)"])
        }

        // Remove from queue
        removeFailedTranscription(id: id)
    }

    /// Increments retry count for a failed transcription
    func incrementRetryCount(id: UUID) {
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        failedTranscriptions[index].retryCount += 1
        failedTranscriptions[index].lastRetryDate = Date()
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Incremented retry count", ["id": "\(id)", "retryCount": "\(failedTranscriptions[index].retryCount)"])
    }

    /// Gets the total number of failed transcriptions
    var count: Int {
        return failedTranscriptions.count
    }

    /// Auto-clean permanent failures (unrecoverable errors or exhausted retries).
    /// Deletes audio files and removes from queue on launch.
    private func cleanupPermanentFailures() {
        let toRemove = failedTranscriptions.filter { failed in
            // Permanent error that will never succeed
            !failed.isRetryable ||
            // Exhausted retries (3+ attempts, still failing)
            failed.retryCount >= 3
        }

        guard !toRemove.isEmpty else { return }

        for failure in toRemove {
            // Delete audio files to reclaim disk space
            try? FileManager.default.removeItem(at: failure.micAudioURL)
            if let systemURL = failure.systemAudioURL {
                try? FileManager.default.removeItem(at: systemURL)
            }
        }

        let removedIds = Set(toRemove.map { $0.id })
        failedTranscriptions.removeAll { removedIds.contains($0.id) }
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Auto-cleaned permanent failures", ["count": "\(toRemove.count)"])
    }

    /// Cleans up failed transcriptions older than the specified number of days
    func cleanupOldFailedTranscriptions(olderThanDays days: Int) {
        // Nil-coalesce: date arithmetic rarely returns nil, but force unwrap would crash on edge cases
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let oldFailures = failedTranscriptions.filter { $0.timestamp < cutoffDate }

        for failure in oldFailures {
            deleteFailedTranscription(id: failure.id)
        }

        AppLogger.pipeline.info("Cleaned up old failed transcriptions", ["count": "\(oldFailures.count)", "olderThanDays": "\(days)"])
    }
}
