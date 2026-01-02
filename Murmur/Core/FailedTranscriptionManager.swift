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
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let transcriptedFolder = documentsURL.appendingPathComponent("Transcripted")

        // Create Transcripted folder if it doesn't exist
        try? FileManager.default.createDirectory(at: transcriptedFolder, withIntermediateDirectories: true)

        self.storageURL = transcriptedFolder.appendingPathComponent("failed_transcriptions.json")

        // Configure date encoding/decoding
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Load existing failed transcriptions
        loadFailedTranscriptions()
    }

    /// Loads failed transcriptions from disk
    private func loadFailedTranscriptions() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            print("[FailedTranscriptionManager] No existing failed transcriptions file")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try decoder.decode([FailedTranscription].self, from: data)

            // Filter out entries where audio files no longer exist
            failedTranscriptions = loaded.filter { $0.audioFilesExist() }

            // Save back if we filtered any out
            if failedTranscriptions.count != loaded.count {
                print("[FailedTranscriptionManager] Removed \(loaded.count - failedTranscriptions.count) entries with missing audio files")
                saveFailedTranscriptions()
            }

            print("[FailedTranscriptionManager] Loaded \(failedTranscriptions.count) failed transcriptions")
        } catch {
            print("[FailedTranscriptionManager] Error loading failed transcriptions: \(error)")
        }
    }

    /// Saves failed transcriptions to disk
    private func saveFailedTranscriptions() {
        do {
            let data = try encoder.encode(failedTranscriptions)
            try data.write(to: storageURL, options: .atomic)
            print("[FailedTranscriptionManager] Saved \(failedTranscriptions.count) failed transcriptions")
        } catch {
            print("[FailedTranscriptionManager] Error saving failed transcriptions: \(error)")
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

        print("[FailedTranscriptionManager] Added failed transcription: \(failed.id)")
    }

    /// Removes a failed transcription from the queue
    func removeFailedTranscription(id: UUID) {
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        failedTranscriptions.remove(at: index)
        saveFailedTranscriptions()

        print("[FailedTranscriptionManager] Removed failed transcription: \(id)")
    }

    /// Removes a failed transcription and deletes its audio files
    func deleteFailedTranscription(id: UUID) {
        guard let failed = failedTranscriptions.first(where: { $0.id == id }) else {
            return
        }

        // Delete audio files
        do {
            try FileManager.default.removeItem(at: failed.micAudioURL)
            print("[FailedTranscriptionManager] Deleted mic audio: \(failed.micAudioURL.lastPathComponent)")

            if let systemURL = failed.systemAudioURL {
                try? FileManager.default.removeItem(at: systemURL)
                print("[FailedTranscriptionManager] Deleted system audio: \(systemURL.lastPathComponent)")
            }
        } catch {
            print("[FailedTranscriptionManager] Error deleting audio files: \(error)")
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

        print("[FailedTranscriptionManager] Incremented retry count for \(id): \(failedTranscriptions[index].retryCount)")
    }

    /// Gets the total number of failed transcriptions
    var count: Int {
        return failedTranscriptions.count
    }

    /// Cleans up failed transcriptions older than the specified number of days
    func cleanupOldFailedTranscriptions(olderThanDays days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!

        let oldFailures = failedTranscriptions.filter { $0.timestamp < cutoffDate }

        for failure in oldFailures {
            deleteFailedTranscription(id: failure.id)
        }

        print("[FailedTranscriptionManager] Cleaned up \(oldFailures.count) failed transcriptions older than \(days) days")
    }
}
