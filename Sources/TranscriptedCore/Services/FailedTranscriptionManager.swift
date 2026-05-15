import Foundation
import Combine

/// Manages the queue of failed transcriptions with persistent storage
@MainActor
public class FailedTranscriptionManager: ObservableObject {
    @Published public var failedTranscriptions: [FailedTranscription] = []

    private let storageURL: URL
    private let allowedAudioRoots: [URL]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(paths: CoreStoragePaths = .default) {
        // Ensure the parent folder exists before first save; the load pass tolerates a missing file.
        do {
            try FileManager.default.createDirectory(
                at: paths.failedQueue.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            AppLogger.pipeline.error("Failed to create failed transcription directory", [
                "path": paths.failedQueue.deletingLastPathComponent().path,
                "error": error.localizedDescription
            ])
        }
        self.storageURL = paths.failedQueue
        self.allowedAudioRoots = [
            paths.audioCaptures,
            paths.transcripts
                .appendingPathComponent("audio", isDirectory: true),
        ].map(Self.canonicalDirectoryURL)

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

            // Security: audio file paths are deserialized from a JSON file that the user could
            // tamper with. Canonicalize first, then only accept files under Transcripted-owned
            // scratch/archive audio roots so cleanup cannot be redirected to arbitrary files.
            let sandboxedEntries = loaded.filter { entry in
                let micSafe = isSafeAudioURL(entry.micAudioURL)
                let systemSafe = entry.systemAudioURL.map(isSafeAudioURL) ?? true
                if !micSafe || !systemSafe {
                    AppLogger.pipeline.error("Rejected failed transcription entry with out-of-sandbox audio path", [
                        "micURL": entry.micAudioURL.path,
                        "systemURL": entry.systemAudioURL?.path ?? "none"
                    ])
                }
                return micSafe && systemSafe
            }

            // Filter out entries where audio files no longer exist
            failedTranscriptions = sandboxedEntries.filter { $0.audioFilesExist() }

            // Save back if we filtered any out
            if failedTranscriptions.count != loaded.count {
                AppLogger.pipeline.info("Removed entries with missing audio files or unsafe paths", ["count": "\(loaded.count - failedTranscriptions.count)"])
                saveFailedTranscriptions()
            }

            AppLogger.pipeline.info("Loaded failed transcriptions", ["count": "\(failedTranscriptions.count)"])
        } catch {
            // Backup corrupt file before it gets overwritten on next save
            let backupURL = storageURL.deletingLastPathComponent().appendingPathComponent("failed_transcriptions_backup.json")
            do {
                try FileManager.default.copyItem(at: storageURL, to: backupURL)
            } catch {
                AppLogger.pipeline.error("Failed to back up corrupt failed transcriptions file", [
                    "source": storageURL.path,
                    "backup": backupURL.path,
                    "error": error.localizedDescription
                ])
            }
            AppLogger.pipeline.error("Corrupt failed transcriptions file, backed up", ["error": "\(error)"])
        }
    }

    /// Saves failed transcriptions to disk
    @discardableResult
    private func saveFailedTranscriptions() -> Bool {
        do {
            let data = try encoder.encode(failedTranscriptions)
            try data.write(to: storageURL, options: .atomic)
            FileManager.default.restrictToOwnerOnly(atPath: storageURL.path)
            AppLogger.pipeline.info("Saved failed transcriptions", ["count": "\(failedTranscriptions.count)"])
            return true
        } catch {
            AppLogger.pipeline.error("Error saving failed transcriptions", ["error": "\(error)"])
            return false
        }
    }

    /// Adds a new failed transcription to the queue
    @discardableResult
    public func addFailedTranscription(
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String? = nil
    ) -> Bool {
        // Security: validate incoming audio URLs before they ever reach the queue.
        // The on-disk load path already re-checks sandboxing, but without this guard an
        // in-memory caller could enqueue an arbitrary file path and trigger deletion before
        // the next reload.
        guard isSafeAudioURL(micAudioURL), systemAudioURL.map(isSafeAudioURL) ?? true else {
            AppLogger.pipeline.error("Rejected failed transcription with out-of-sandbox audio path", [
                "micURL": micAudioURL.path,
                "systemURL": systemAudioURL?.path ?? "none"
            ])
            return false
        }

        let failed = FailedTranscription(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle
        )

        failedTranscriptions.append(failed)
        let didPersist = saveFailedTranscriptions()
        if !didPersist {
            failedTranscriptions.removeAll { $0.id == failed.id }
        }

        AppLogger.pipeline.info("Added failed transcription", [
            "id": "\(failed.id)",
            "persisted": "\(didPersist)"
        ])
        return didPersist
    }

    /// Removes a failed transcription from the queue
    public func removeFailedTranscription(id: UUID) {
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        failedTranscriptions.remove(at: index)
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Removed failed transcription", ["id": "\(id)"])
    }

    /// Removes a failed transcription and deletes its audio files
    public func deleteFailedTranscription(id: UUID) {
        guard let failed = failedTranscriptions.first(where: { $0.id == id }) else {
            return
        }

        // Delete audio files independently so one failure does not hide the other.
        removeAudioFile(failed.micAudioURL, label: "mic audio")

        if let systemURL = failed.systemAudioURL {
            removeAudioFile(systemURL, label: "system audio")
        }
        removeEmptyAudioArchiveDirectoryIfNeeded(containing: failed.micAudioURL)
        if let systemURL = failed.systemAudioURL {
            removeEmptyAudioArchiveDirectoryIfNeeded(containing: systemURL)
        }

        // Remove from queue
        removeFailedTranscription(id: id)
    }

    /// Increments retry count for a failed transcription
    public func incrementRetryCount(id: UUID) {
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        failedTranscriptions[index].retryCount += 1
        failedTranscriptions[index].lastRetryDate = Date()
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Incremented retry count", ["id": "\(id)", "retryCount": "\(failedTranscriptions[index].retryCount)"])
    }

    /// Gets the total number of failed transcriptions
    public var count: Int {
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
            removeAudioFile(failure.micAudioURL, label: "cleanup mic audio")
            if let systemURL = failure.systemAudioURL {
                removeAudioFile(systemURL, label: "cleanup system audio")
            }
            removeEmptyAudioArchiveDirectoryIfNeeded(containing: failure.micAudioURL)
            if let systemURL = failure.systemAudioURL {
                removeEmptyAudioArchiveDirectoryIfNeeded(containing: systemURL)
            }
        }

        let removedIds = Set(toRemove.map { $0.id })
        failedTranscriptions.removeAll { removedIds.contains($0.id) }
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Auto-cleaned permanent failures", ["count": "\(toRemove.count)"])
    }

    /// Cleans up failed transcriptions older than the specified number of days
    public func cleanupOldFailedTranscriptions(olderThanDays days: Int) {
        // Nil-coalesce: date arithmetic rarely returns nil, but force unwrap would crash on edge cases
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let oldFailures = failedTranscriptions.filter { $0.timestamp < cutoffDate }
        guard !oldFailures.isEmpty else {
            AppLogger.pipeline.info("Cleaned up old failed transcriptions", ["count": "0", "olderThanDays": "\(days)"])
            return
        }

        for failure in oldFailures {
            removeAudioFile(failure.micAudioURL, label: "old failure mic audio")
            if let systemURL = failure.systemAudioURL {
                removeAudioFile(systemURL, label: "old failure system audio")
            }
            removeEmptyAudioArchiveDirectoryIfNeeded(containing: failure.micAudioURL)
            if let systemURL = failure.systemAudioURL {
                removeEmptyAudioArchiveDirectoryIfNeeded(containing: systemURL)
            }
        }

        let removedIds = Set(oldFailures.map { $0.id })
        failedTranscriptions.removeAll { removedIds.contains($0.id) }
        saveFailedTranscriptions()

        AppLogger.pipeline.info("Cleaned up old failed transcriptions", ["count": "\(oldFailures.count)", "olderThanDays": "\(days)"])
    }

    private func removeAudioFile(_ url: URL, label: String) {
        // Security: re-check containment at deletion time so a mutated in-memory entry cannot
        // redirect cleanup to arbitrary files outside Transcripted-managed audio directories.
        guard isSafeAudioURL(url) else {
            AppLogger.pipeline.error("Refused to delete out-of-sandbox audio file", [
                "label": label,
                "path": url.path
            ])
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            AppLogger.pipeline.info("Deleted audio file", [
                "label": label,
                "file": url.lastPathComponent
            ])
        } catch {
            AppLogger.pipeline.warning("Failed to delete audio file", [
                "label": label,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    private func removeEmptyAudioArchiveDirectoryIfNeeded(containing url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasSuffix("_audio"),
              isSafeAudioURL(directory),
              let remaining = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ),
              remaining.isEmpty else {
            return
        }

        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            AppLogger.pipeline.warning("Failed to remove empty failed-audio directory", [
                "errorType": "\(type(of: error))"
            ])
        }
    }

    private func isSafeAudioURL(_ url: URL) -> Bool {
        let canonicalURL = Self.canonicalFileURL(url)
        return allowedAudioRoots.contains { root in
            Self.isFile(canonicalURL, containedIn: root)
        }
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func canonicalDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let filePath = canonicalFileURL(fileURL).path
        let directoryPath = canonicalDirectoryURL(directoryURL).path
        let normalizedDirectoryPath = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath == directoryPath || filePath.hasPrefix(normalizedDirectoryPath)
    }
}
