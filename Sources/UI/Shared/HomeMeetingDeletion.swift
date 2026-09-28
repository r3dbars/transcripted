import CryptoKit
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct HomeMeetingDeletionResult: Equatable {
    let removedTranscriptURLs: [URL]
    let removedSummaryURLs: [URL]
    let removedAudioDirectoryURLs: [URL]
}

enum HomeMeetingDeletionError: LocalizedError {
    case transcriptUnavailable
    case retranscriptionInProgress

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            return "This meeting was moved or removed before it could be deleted. Refresh the meetings list and try again."
        case .retranscriptionInProgress:
            return "This meeting is being re-transcribed. Try deleting it after transcription finishes."
        }
    }
}

enum HomeMeetingDeletion {
    struct Plan: Equatable, Sendable {
        let transcriptURLs: [URL]
        let summaryURLs: [URL]
        let audioDirectoryURLs: [URL]
        let audioAttachmentIDs: [String]
    }

    struct UndoPayload: Sendable {
        let plan: Plan
        let trashedFiles: [TrashedFile]
    }

    /// Planning and moving must be one transaction with restyling, speaker
    /// rewrites, and saves. Otherwise a writer can read a meeting before Trash
    /// and recreate it afterward. Run this off the main actor: planning can
    /// hash large retained recordings and may wait for another file update.
    static func trash(
        _ item: RecentMeetingItem,
        fileManager: FileManager = .default
    ) throws -> UndoPayload {
        try withCurrentPlan(for: item, fileManager: fileManager) { plan in
            let urls = plan.transcriptURLs + plan.summaryURLs + plan.audioDirectoryURLs
            let trashed = try CaptureTrashOperation.trash(urls, fileManager: fileManager)
            return UndoPayload(plan: plan, trashedFiles: trashed)
        }
    }

    static func restore(_ payload: UndoPayload, fileManager: FileManager = .default) {
        MeetingTranscriptFileUpdateSerializer.sync {
            // Preserve the existing non-overwriting Trash restore behavior.
            // Queued writers cannot interleave with the restore. This remains
            // best-effort if a Trash item is gone or a destination is occupied.
            CaptureTrashOperation.restore(payload.trashedFiles, fileManager: fileManager)
        }
    }

    static func delete(
        _ item: RecentMeetingItem,
        fileManager: FileManager = .default
    ) throws -> HomeMeetingDeletionResult {
        try withCurrentPlan(for: item, fileManager: fileManager) { plan in
            try delete(plan, fileManager: fileManager)
        }
    }

    static func delete(
        _ plan: Plan,
        fileManager: FileManager = .default
    ) throws -> HomeMeetingDeletionResult {
        try MeetingTranscriptFileUpdateSerializer.sync(protecting: plan.transcriptURLs) {
            let removedSummaries = try removeExistingItems(plan.summaryURLs, fileManager: fileManager)
            let removedTranscripts = try removeExistingItems(plan.transcriptURLs, fileManager: fileManager)
            let removedAudioDirectories = try removeExistingItems(plan.audioDirectoryURLs, fileManager: fileManager)

            return HomeMeetingDeletionResult(
                removedTranscriptURLs: removedTranscripts,
                removedSummaryURLs: removedSummaries,
                removedAudioDirectoryURLs: removedAudioDirectories
            )
        }
    }

    private static func withCurrentPlan<T>(
        for item: RecentMeetingItem,
        fileManager: FileManager,
        _ operation: (Plan) throws -> T
    ) throws -> T {
        do {
            return try MeetingTranscriptFileUpdateSerializer.sync {
                // A preceding restyle may have renamed this row since its last
                // scan. Do not claim success or remove cached audio on a stale
                // target; let the caller refresh and act on the current row.
                guard isRegularFile(item.transcriptURL, fileManager: fileManager) else {
                    throw HomeMeetingDeletionError.transcriptUnavailable
                }
                let currentPlan = plan(for: item, fileManager: fileManager)
                return try MeetingTranscriptFileUpdateSerializer.sync(protecting: currentPlan.transcriptURLs) {
                    try operation(currentPlan)
                }
            }
        } catch MeetingTranscriptFileUpdateError.replacementInProgress {
            throw HomeMeetingDeletionError.retranscriptionInProgress
        }
    }

    static func plan(
        for item: RecentMeetingItem,
        fileManager: FileManager = .default
    ) -> Plan {
        var transcriptURLs = OrderedURLSet()
        var summaryURLs = OrderedURLSet()
        var audioDirectoryURLs = OrderedURLSet()
        var audioAttachmentIDs: [String] = []

        transcriptURLs.insert(item.transcriptURL)
        insertOwnedSummary(for: item.transcriptURL, into: &summaryURLs, fileManager: fileManager)
        // Retained audio can be attached or recompressed after Home scanned the
        // row. Resolve it again while the deletion transaction owns the files.
        if let audio = MeetingAudioArchiveResolver.attachment(forTranscript: item.transcriptURL, fileManager: fileManager) {
            audioDirectoryURLs.insert(audio.directoryURL)
            audioAttachmentIDs.append(audio.id)
            if isAppOwnedMeetingTranscript(item.transcriptURL) {
                for duplicate in duplicateRetainedAudioMeetings(
                    matching: audio,
                    selectedTranscriptURL: item.transcriptURL,
                    fileManager: fileManager
                ) {
                    transcriptURLs.insert(duplicate.transcriptURL)
                    insertOwnedSummary(for: duplicate.transcriptURL, into: &summaryURLs, fileManager: fileManager)
                    audioDirectoryURLs.insert(duplicate.audio.directoryURL)
                    audioAttachmentIDs.append(duplicate.audio.id)
                }
            }
        }

        return Plan(
            transcriptURLs: transcriptURLs.urls,
            summaryURLs: summaryURLs.urls,
            audioDirectoryURLs: audioDirectoryURLs.urls,
            audioAttachmentIDs: audioAttachmentIDs
        )
    }

    private static func duplicateRetainedAudioMeetings(
        matching selectedAudio: MeetingAudioAttachment,
        selectedTranscriptURL: URL,
        fileManager: FileManager
    ) -> [(transcriptURL: URL, audio: MeetingAudioAttachment)] {
        guard let selectedValues = appOwnedMeetingTranscriptValues(selectedTranscriptURL),
              let selectedTitle = normalizedTitle(selectedValues["title"]) else {
            return []
        }

        let meetingsDirectory = selectedTranscriptURL.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let selectedPath = canonicalPath(selectedTranscriptURL)
        var candidates: [(URL, MeetingAudioAttachment)] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard url.pathExtension == "md",
                  !url.deletingPathExtension().lastPathComponent.hasSuffix(".summary"),
                  canonicalPath(url) != selectedPath,
                  isRegularFile(url, fileManager: fileManager),
                  let values = appOwnedMeetingTranscriptValues(url),
                  normalizedTitle(values["title"]) == selectedTitle,
                  let audio = MeetingAudioArchiveResolver.attachment(forTranscript: url, fileManager: fileManager) else {
                continue
            }
            candidates.append((url, audio))
        }

        // Hashing reads every byte of retained audio, and this runs while the
        // transcript serializer is held (main-thread saves wait on it). A
        // recurring title can have many hour-long recordings, so only hash
        // candidates whose files are the same sizes in the same roles.
        guard !candidates.isEmpty,
              let selectedSizes = audioSizeSignature(for: selectedAudio, fileManager: fileManager) else {
            return []
        }
        let sizeMatches = candidates.filter { _, audio in
            audioSizeSignature(for: audio, fileManager: fileManager) == selectedSizes
        }
        guard !sizeMatches.isEmpty,
              let selectedSignature = audioSignature(for: selectedAudio) else {
            return []
        }

        return sizeMatches.filter { _, audio in
            audioSignature(for: audio) == selectedSignature
        }
    }

    /// Cheap pre-filter for `audioSignature`: equal digests imply equal sizes
    /// per role, so this never drops a real duplicate.
    private static func audioSizeSignature(
        for audio: MeetingAudioAttachment,
        fileManager: FileManager
    ) -> [String]? {
        var parts: [String] = []
        for url in audio.retranscriptionURLs {
            guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                return nil
            }
            parts.append("\(url.deletingPathExtension().lastPathComponent):\(size.uint64Value)")
        }
        return parts.isEmpty ? nil : parts.sorted()
    }

    /// Legacy artifact hygiene: users who ran the (now-removed) local AI
    /// summarizer have `<stem>.summary.md` sidecars on disk. Remove the
    /// sidecar alongside its transcript so it doesn't outlive the meeting
    /// it describes.
    private static func insertOwnedSummary(
        for transcriptURL: URL,
        into summaryURLs: inout OrderedURLSet,
        fileManager: FileManager
    ) {
        let summaryURL = legacySummarySidecarURL(for: transcriptURL)
        guard isOwnedSummary(summaryURL, for: transcriptURL, fileManager: fileManager) else {
            return
        }
        summaryURLs.insert(summaryURL)
    }

    /// `<stem>.summary.md` next to the transcript, matching the sidecar name
    /// the legacy local AI summarizer wrote.
    private static func legacySummarySidecarURL(for transcriptURL: URL) -> URL {
        let base = transcriptURL.deletingPathExtension()
        return base
            .deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent).summary")
            .appendingPathExtension("md")
    }

    private static func isOwnedSummary(
        _ summaryURL: URL,
        for transcriptURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: summaryURL.path),
              let values = try? TranscriptFrontmatter.readValues(from: summaryURL),
              values["capture_type"] == "meeting_summary",
              values["source_transcript"] == transcriptURL.lastPathComponent else {
            return false
        }
        return true
    }

    private static func isAppOwnedMeetingTranscript(_ url: URL) -> Bool {
        appOwnedMeetingTranscriptValues(url) != nil
    }

    private static func appOwnedMeetingTranscriptValues(_ url: URL) -> [String: String]? {
        guard let values = try? TranscriptFrontmatter.readValues(from: url),
              values["capture_type"]?.lowercased() == "meeting" else {
            return nil
        }
        guard isValidTranscriptIdentifier(values["transcript_id"])
            || isValidTranscriptIdentifier(values["capture_id"])
        else {
            return nil
        }
        return values
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func isValidTranscriptIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return UUID(uuidString: value) != nil
    }

    private static func audioSignature(for audio: MeetingAudioAttachment) -> AudioSignature? {
        let parts = audio.retranscriptionURLs.compactMap { url -> AudioSignature.Part? in
            guard let digest = audioFileDigest(url) else { return nil }
            return AudioSignature.Part(
                role: url.deletingPathExtension().lastPathComponent,
                digest: digest
            )
        }
        guard parts.count == audio.retranscriptionURLs.count,
              !parts.isEmpty else {
            return nil
        }
        return AudioSignature(parts: parts.sorted { lhs, rhs in
            lhs.role.localizedStandardCompare(rhs.role) == .orderedAscending
        })
    }

    private static func audioFileDigest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data: Data?
            do {
                data = try handle.read(upToCount: 1024 * 1024)
            } catch {
                return nil
            }
            guard let data, !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func removeExistingItems(
        _ urls: [URL],
        fileManager: FileManager
    ) throws -> [URL] {
        var removed: [URL] = []
        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        // Home's directory scan prefetches URL resource values. Those values can
        // still say "regular file" after a restyle moves the transcript, so a
        // destructive action must query the current filesystem, not that cache.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private struct AudioSignature: Equatable {
    struct Part: Equatable {
        let role: String
        let digest: String
    }

    let parts: [Part]
}

private struct OrderedURLSet {
    private var seen: Set<String> = []
    private(set) var urls: [URL] = []

    mutating func insert(_ url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard seen.insert(key).inserted else { return }
        urls.append(url)
    }
}
