import Foundation
import Combine

// MARK: - Failed Action Item Extraction Model

/// Represents an action item extraction that failed and can be retried
struct FailedActionItemExtraction: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let transcriptURL: URL
    let errorMessage: String
    var retryCount: Int
    var lastRetryDate: Date?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        transcriptURL: URL,
        errorMessage: String,
        retryCount: Int = 0,
        lastRetryDate: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.transcriptURL = transcriptURL
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

    /// Returns the transcript filename for display
    var transcriptFilename: String {
        transcriptURL.lastPathComponent
    }

    /// Returns a short error summary for display
    var shortErrorMessage: String {
        if errorMessage.count > 100 {
            return String(errorMessage.prefix(97)) + "..."
        }
        return errorMessage
    }

    /// Checks if the transcript file still exists
    func transcriptExists() -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL.path)
    }

    /// Calculate backoff delay based on retry count (exponential: 2s, 4s, 8s, 16s...)
    var backoffDelay: TimeInterval {
        let baseDelay: TimeInterval = 2.0
        let maxDelay: TimeInterval = 60.0  // Cap at 1 minute
        let delay = baseDelay * pow(2.0, Double(retryCount))
        return min(delay, maxDelay)
    }

    /// Whether enough time has passed since last retry to try again
    var canRetry: Bool {
        guard let lastRetry = lastRetryDate else { return true }
        return Date().timeIntervalSince(lastRetry) >= backoffDelay
    }
}

// MARK: - Failed Action Item Manager

/// Manages the queue of failed action item extractions with persistent storage
@available(macOS 14.0, *)
class FailedActionItemManager: ObservableObject {
    @Published var failedExtractions: [FailedActionItemExtraction] = []

    private let storageURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Maximum retries before giving up
    static let maxRetries = 5

    init() {
        // Store in Documents/Transcripted folder alongside failed_transcriptions.json
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let transcriptedFolder = documentsURL.appendingPathComponent("Transcripted")

        // Create folder if needed
        try? FileManager.default.createDirectory(at: transcriptedFolder, withIntermediateDirectories: true)

        self.storageURL = transcriptedFolder.appendingPathComponent("failed_action_item_extractions.json")

        // Configure date encoding/decoding
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Load existing failures
        loadFailedExtractions()
    }

    // MARK: - Persistence

    private func loadFailedExtractions() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            print("[FailedActionItemManager] No existing failed extractions file")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try decoder.decode([FailedActionItemExtraction].self, from: data)

            // Filter out entries where transcript no longer exists or max retries exceeded
            failedExtractions = loaded.filter { extraction in
                extraction.transcriptExists() && extraction.retryCount < Self.maxRetries
            }

            // Save back if we filtered any out
            if failedExtractions.count != loaded.count {
                let removed = loaded.count - failedExtractions.count
                print("[FailedActionItemManager] Removed \(removed) stale entries")
                saveFailedExtractions()
            }

            print("[FailedActionItemManager] Loaded \(failedExtractions.count) failed extractions")
        } catch {
            print("[FailedActionItemManager] Error loading: \(error)")
        }
    }

    private func saveFailedExtractions() {
        do {
            let data = try encoder.encode(failedExtractions)
            try data.write(to: storageURL, options: .atomic)
            print("[FailedActionItemManager] Saved \(failedExtractions.count) failed extractions")
        } catch {
            print("[FailedActionItemManager] Error saving: \(error)")
        }
    }

    // MARK: - Public API

    /// Add a failed extraction to the retry queue
    func addFailedExtraction(transcriptURL: URL, error: Error) {
        // Don't add duplicates for the same transcript
        if failedExtractions.contains(where: { $0.transcriptURL == transcriptURL }) {
            print("[FailedActionItemManager] Duplicate entry for \(transcriptURL.lastPathComponent), skipping")
            return
        }

        let failed = FailedActionItemExtraction(
            transcriptURL: transcriptURL,
            errorMessage: error.localizedDescription
        )

        failedExtractions.append(failed)
        saveFailedExtractions()

        print("[FailedActionItemManager] Added failed extraction: \(failed.transcriptFilename)")
    }

    /// Remove a failed extraction (after successful retry or user dismissal)
    func removeFailedExtraction(id: UUID) {
        guard let index = failedExtractions.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removed = failedExtractions.remove(at: index)
        saveFailedExtractions()

        print("[FailedActionItemManager] Removed: \(removed.transcriptFilename)")
    }

    /// Increment retry count (call before attempting retry)
    func incrementRetryCount(id: UUID) {
        guard let index = failedExtractions.firstIndex(where: { $0.id == id }) else {
            return
        }

        failedExtractions[index].retryCount += 1
        failedExtractions[index].lastRetryDate = Date()
        saveFailedExtractions()

        let extraction = failedExtractions[index]
        print("[FailedActionItemManager] Retry \(extraction.retryCount)/\(Self.maxRetries) for \(extraction.transcriptFilename)")
    }

    /// Get extractions that are ready to retry (backoff elapsed)
    var extractionsReadyForRetry: [FailedActionItemExtraction] {
        failedExtractions.filter { $0.canRetry }
    }

    /// Total count of failed extractions
    var count: Int {
        failedExtractions.count
    }

    /// Clean up old entries (older than specified days)
    func cleanupOldFailures(olderThanDays days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!

        let oldFailures = failedExtractions.filter { $0.timestamp < cutoffDate }

        for failure in oldFailures {
            removeFailedExtraction(id: failure.id)
        }

        if !oldFailures.isEmpty {
            print("[FailedActionItemManager] Cleaned up \(oldFailures.count) entries older than \(days) days")
        }
    }
}
