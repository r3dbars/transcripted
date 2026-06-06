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

enum HomeMeetingDeletion {
    struct Plan: Equatable, Sendable {
        let transcriptURLs: [URL]
        let summaryURLs: [URL]
        let audioDirectoryURLs: [URL]
        let audioAttachmentIDs: [String]
    }

    static func delete(
        _ item: RecentMeetingItem,
        fileManager: FileManager = .default
    ) throws -> HomeMeetingDeletionResult {
        try delete(plan(for: item, fileManager: fileManager), fileManager: fileManager)
    }

    static func delete(
        _ plan: Plan,
        fileManager: FileManager = .default
    ) throws -> HomeMeetingDeletionResult {
        let removedSummaries = try removeExistingItems(plan.summaryURLs, fileManager: fileManager)
        let removedTranscripts = try removeExistingItems(plan.transcriptURLs, fileManager: fileManager)
        let removedAudioDirectories = try removeExistingItems(plan.audioDirectoryURLs, fileManager: fileManager)

        return HomeMeetingDeletionResult(
            removedTranscriptURLs: removedTranscripts,
            removedSummaryURLs: removedSummaries,
            removedAudioDirectoryURLs: removedAudioDirectories
        )
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
        if let audio = item.audio {
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

        guard !candidates.isEmpty,
              let selectedSignature = audioSignature(for: selectedAudio) else {
            return []
        }

        return candidates.filter { _, audio in
            audioSignature(for: audio) == selectedSignature
        }
    }

    private static func insertOwnedSummary(
        for transcriptURL: URL,
        into summaryURLs: inout OrderedURLSet,
        fileManager: FileManager
    ) {
        let summaryURL = LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
        guard isOwnedSummary(summaryURL, for: transcriptURL, fileManager: fileManager) else {
            return
        }
        summaryURLs.insert(summaryURL)
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
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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
