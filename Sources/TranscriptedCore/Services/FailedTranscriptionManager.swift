import Foundation
import Combine

/// Manages the queue of failed transcriptions with persistent storage
@MainActor
public class FailedTranscriptionManager: ObservableObject {
    @Published public var failedTranscriptions: [FailedTranscription] = []

    private let storageURL: URL
    private let allowedAudioRoots: [URL]
    private let audioArchiveRoot: URL
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
        self.audioArchiveRoot = Self.canonicalDirectoryURL(
            paths.transcripts.appendingPathComponent("audio", isDirectory: true)
        )
        self.allowedAudioRoots = [
            paths.audioCaptures,
            paths.transcripts
                .appendingPathComponent("audio", isDirectory: true),
        ].map(Self.canonicalDirectoryURL)

        // Configure date encoding/decoding
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Load existing failed transcriptions. User-visible failed meetings stay
        // queued until the user retries, deletes, or the age-based cleanup runs.
        loadFailedTranscriptions()
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

            var healedCount = 0
            var removedCount = 0
            var unavailableCount = 0
            var reconciledEntries: [FailedTranscription] = []

            for loadedEntry in loaded {
                let relocation = healRelocatedAudioReferences(of: loadedEntry)
                if relocation.didHeal {
                    healedCount += 1
                }
                let relocatedEntry = relocation.entry

                // Security: audio file paths are deserialized from a JSON file that the user could
                // tamper with. Canonicalize first, then only accept files under Transcripted-owned
                // scratch/archive audio roots so cleanup cannot be redirected to arbitrary files.
                let micSafe = isSafeAudioURL(relocatedEntry.micAudioURL)
                let systemSafe = relocatedEntry.systemAudioURL.map(isSafeAudioURL) ?? true
                guard micSafe && systemSafe else {
                    AppLogger.pipeline.error("Rejected failed transcription entry with out-of-sandbox audio path", [
                        "micURL": relocatedEntry.micAudioURL.path,
                        "systemURL": relocatedEntry.systemAudioURL?.path ?? "none"
                    ])
                    removedCount += 1
                    continue
                }

                // Heal stale audio references before the existence filter. A crash
                // between the merger's segment cleanup and the queue repoint leaves
                // an entry pointing at a deleted pre-merge WAV while
                // `<stem>_merged.wav` sits on disk — dropping that entry here would
                // make the meeting disappear permanently.
                let reconciliation = reconcileAudioReferences(of: relocatedEntry)
                if reconciliation.didHeal {
                    healedCount += 1
                }
                if reconciliation.hasUnavailableAudio {
                    unavailableCount += 1
                }
                guard let entry = reconciliation.entry else {
                    removedCount += 1
                    continue
                }
                reconciledEntries.append(entry)
            }
            failedTranscriptions = reconciledEntries

            // Save back if we filtered or healed any, unless a missing file may
            // be caused by an unavailable library/volume. In that case, keep the
            // in-memory queue visible and avoid making any destructive rewrite.
            if removedCount > 0 || healedCount > 0 {
                AppLogger.pipeline.info("Reconciled failed transcription entries on load", [
                    "removed": "\(removedCount)",
                    "healed": "\(healedCount)",
                    "unavailable": "\(unavailableCount)"
                ])
                if unavailableCount == 0 {
                    saveFailedTranscriptions()
                } else {
                    AppLogger.pipeline.warning("Skipped saving failed transcription reconciliation because audio root is unavailable", [
                        "unavailable": "\(unavailableCount)"
                    ])
                }
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

    /// Repairs an entry whose audio references no longer match the disk state.
    /// Returns the healed entry, or nil when nothing needed healing.
    private typealias AudioReconciliation = (
        entry: FailedTranscription?,
        didHeal: Bool,
        hasUnavailableAudio: Bool
    )

    private func reconcileAudioReferences(of entry: FailedTranscription) -> AudioReconciliation {
        let fileManager = FileManager.default
        var micURL = entry.micAudioURL
        var systemURL = entry.systemAudioURL
        var didHeal = false
        var hasUnavailableAudio = false

        // A merge that completed after the entry was written deletes the
        // pre-merge segments and leaves `<stem>_merged.wav` in their place.
        if !fileManager.fileExists(atPath: micURL.path) {
            if let mergedCandidate = mergedSibling(for: micURL),
               fileManager.fileExists(atPath: mergedCandidate.path),
               isSafeAudioURL(mergedCandidate) {
                micURL = mergedCandidate
                didHeal = true
                AppLogger.pipeline.info("Healed failed transcription mic audio to merged file", [
                    "id": entry.id.uuidString,
                    "file": mergedCandidate.lastPathComponent
                ])
            } else if !isContainingAudioRootReachable(for: micURL) {
                hasUnavailableAudio = true
            }
        }

        // Keep the meeting retryable with mic audio only rather than dropping
        // it because the system-audio file went missing.
        if let existingSystemURL = systemURL,
           !fileManager.fileExists(atPath: existingSystemURL.path) {
            if !isContainingAudioRootReachable(for: existingSystemURL) {
                hasUnavailableAudio = true
            } else if fileManager.fileExists(atPath: micURL.path) {
                systemURL = nil
                didHeal = true
                AppLogger.pipeline.warning("Dropped missing system audio reference from failed transcription", [
                    "id": entry.id.uuidString,
                    "file": existingSystemURL.lastPathComponent
                ])
            }
        }

        if hasUnavailableAudio {
            return (entry, didHeal, true)
        }

        // Audio preserved during a quit that interrupted finalization can have
        // an unpatched WAV header, which reads back as zero-length and makes
        // every retry fail. Nothing else re-runs finalization after relaunch.
        repairWAVHeaderIfNeeded(at: micURL, entryId: entry.id)
        if let systemURL {
            repairWAVHeaderIfNeeded(at: systemURL, entryId: entry.id)
        }

        if !fileManager.fileExists(atPath: micURL.path) {
            AppLogger.pipeline.error("Dropping failed transcription entry with missing audio", [
                "id": entry.id.uuidString,
                "micFile": micURL.lastPathComponent,
                "systemFile": systemURL?.lastPathComponent ?? "none"
            ])
            return (nil, didHeal, false)
        }
        if let systemURL, !fileManager.fileExists(atPath: systemURL.path) {
            AppLogger.pipeline.error("Dropping failed transcription entry with missing audio", [
                "id": entry.id.uuidString,
                "micFile": micURL.lastPathComponent,
                "systemFile": systemURL.lastPathComponent
            ])
            return (nil, didHeal, false)
        }

        guard didHeal else { return (entry, false, false) }
        return (FailedTranscription(
            id: entry.id,
            timestamp: entry.timestamp,
            recordingDate: entry.recordingDate,
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: entry.errorMessage,
            meetingTitle: entry.meetingTitle,
            retryCount: entry.retryCount,
            lastRetryDate: entry.lastRetryDate
        ), true, false)
    }

    private func healRelocatedAudioReferences(of entry: FailedTranscription) -> (entry: FailedTranscription, didHeal: Bool) {
        var micURL = entry.micAudioURL
        var systemURL = entry.systemAudioURL
        var didHeal = false

        if !isSafeAudioURL(micURL),
           let relocatedMicURL = relocatedAudioURL(for: micURL),
           FileManager.default.fileExists(atPath: relocatedMicURL.path),
           isSafeAudioURL(relocatedMicURL) {
            micURL = relocatedMicURL
            didHeal = true
        }

        if let existingSystemURL = systemURL,
           !isSafeAudioURL(existingSystemURL),
           let relocatedSystemURL = relocatedAudioURL(for: existingSystemURL),
           FileManager.default.fileExists(atPath: relocatedSystemURL.path),
           isSafeAudioURL(relocatedSystemURL) {
            systemURL = relocatedSystemURL
            didHeal = true
        }

        guard didHeal else { return (entry, false) }
        AppLogger.pipeline.info("Healed failed transcription audio paths after capture library relocation", [
            "id": entry.id.uuidString
        ])
        return (FailedTranscription(
            id: entry.id,
            timestamp: entry.timestamp,
            recordingDate: entry.recordingDate,
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: entry.errorMessage,
            meetingTitle: entry.meetingTitle,
            retryCount: entry.retryCount,
            lastRetryDate: entry.lastRetryDate
        ), true)
    }

    private func relocatedAudioURL(for url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasSuffix("_audio") else { return nil }
        return audioArchiveRoot
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
    }

    private func mergedSibling(for url: URL) -> URL? {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_merged.wav")
    }

    private func isContainingAudioRootReachable(for url: URL) -> Bool {
        guard let root = allowedAudioRoots.first(where: { Self.isFile(url, containedIn: $0) }) else {
            return true
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func repairWAVHeaderIfNeeded(at url: URL, entryId: UUID) {
        guard url.pathExtension.lowercased() == "wav",
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            if try WAVHeaderRepair.repairIfNeeded(at: url) {
                AppLogger.pipeline.info("Repaired unfinalized WAV header for failed transcription audio", [
                    "id": entryId.uuidString,
                    "file": url.lastPathComponent
                ])
            }
        } catch {
            AppLogger.pipeline.warning("Could not inspect failed transcription WAV header", [
                "id": entryId.uuidString,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
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
        id: UUID = UUID(),
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil
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
            id: id,
            recordingDate: recordingDate,
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

    @discardableResult
    public func updateFailedTranscriptionAudio(
        id: UUID,
        micAudioURL: URL,
        systemAudioURL: URL?
    ) -> Bool {
        guard isSafeAudioURL(micAudioURL), systemAudioURL.map(isSafeAudioURL) ?? true else {
            AppLogger.pipeline.error("Rejected failed transcription audio update with out-of-sandbox path", [
                "id": id.uuidString,
                "micURL": micAudioURL.path,
                "systemURL": systemAudioURL?.path ?? "none"
            ])
            return false
        }
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let existing = failedTranscriptions[index]
        failedTranscriptions[index] = FailedTranscription(
            id: existing.id,
            timestamp: existing.timestamp,
            recordingDate: existing.recordingDate,
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: existing.errorMessage,
            meetingTitle: existing.meetingTitle,
            retryCount: existing.retryCount,
            lastRetryDate: existing.lastRetryDate
        )

        let didPersist = saveFailedTranscriptions()
        if !didPersist {
            failedTranscriptions[index] = existing
        }
        AppLogger.pipeline.info("Updated failed transcription audio", [
            "id": "\(id)",
            "persisted": "\(didPersist)"
        ])
        return didPersist
    }

    /// Removes a failed transcription from the queue.
    @discardableResult
    public func removeFailedTranscription(id: UUID) -> Bool {
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let removed = failedTranscriptions.remove(at: index)
        let didPersist = saveFailedTranscriptions()
        if !didPersist {
            failedTranscriptions.insert(removed, at: index)
        }

        AppLogger.pipeline.info("Removed failed transcription", [
            "id": "\(id)",
            "persisted": "\(didPersist)"
        ])
        return didPersist
    }

    @discardableResult
    public func updateFailedTranscriptionError(id: UUID, errorMessage: String) -> Bool {
        guard let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let existing = failedTranscriptions[index]
        failedTranscriptions[index] = FailedTranscription(
            id: existing.id,
            timestamp: existing.timestamp,
            recordingDate: existing.recordingDate,
            micAudioURL: existing.micAudioURL,
            systemAudioURL: existing.systemAudioURL,
            errorMessage: errorMessage,
            meetingTitle: existing.meetingTitle,
            retryCount: existing.retryCount,
            lastRetryDate: existing.lastRetryDate
        )

        let didPersist = saveFailedTranscriptions()
        AppLogger.pipeline.info("Updated failed transcription error", [
            "id": "\(id)",
            "persisted": "\(didPersist)"
        ])
        return didPersist
    }

    /// Removes a failed transcription and deletes its audio files.
    @discardableResult
    public func deleteFailedTranscription(id: UUID) -> Bool {
        guard let failed = failedTranscriptions.first(where: { $0.id == id }) else {
            return false
        }

        guard removeFailedTranscription(id: id) else {
            return false
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

        return true
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

    /// Cleans up failed transcriptions older than the specified number of days
    public func cleanupOldFailedTranscriptions(olderThanDays days: Int) {
        // Nil-coalesce: date arithmetic rarely returns nil, but force unwrap would crash on edge cases
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let oldFailures = failedTranscriptions.filter { $0.timestamp < cutoffDate }
        guard !oldFailures.isEmpty else {
            AppLogger.pipeline.info("Cleaned up old failed transcriptions", ["count": "0", "olderThanDays": "\(days)"])
            return
        }

        // Persist the entry removal before touching audio files. Deleting
        // audio first means a crash in between leaves entries pointing at
        // missing files, which the load filter then drops silently.
        let removedIds = Set(oldFailures.map { $0.id })
        let previousEntries = failedTranscriptions
        failedTranscriptions.removeAll { removedIds.contains($0.id) }
        guard saveFailedTranscriptions() else {
            failedTranscriptions = previousEntries
            AppLogger.pipeline.error("Skipped old failed transcription cleanup because removal did not persist", [
                "count": "\(oldFailures.count)",
                "olderThanDays": "\(days)"
            ])
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
