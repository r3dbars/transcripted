import Foundation

struct RecentMeetingItem: Identifiable, Sendable {
    let title: String
    let date: Date
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?

    var id: String { transcriptURL.path }
}

struct RecentCaptureSnapshot: Sendable {
    let meetings: [RecentMeetingItem]
    let dictations: [SavedDictationEntry]
    let dictationCounts: DictationTranscriptCounts
}

enum RecentCaptureLoader {
    static func load(limit: Int = 5) async -> RecentCaptureSnapshot {
        await load(dictationLimit: limit, meetingLimit: limit, includeDictationCounts: false)
    }

    static func load(
        dictationLimit: Int,
        meetingLimit: Int,
        includeDictationCounts: Bool = false
    ) async -> RecentCaptureSnapshot {
        let taskBox = LoadTaskBox()

        return await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                let meetings = RecentMeetingsScanner.loadRecent(limit: meetingLimit)
                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                let dictations = DictationTranscriptStore.recentSavedDictations(limit: dictationLimit)
                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                let dictationCounts = includeDictationCounts
                    ? DictationTranscriptStore.savedDictationCounts()
                    : DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)

                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                return RecentCaptureSnapshot(
                    meetings: meetings,
                    dictations: dictations,
                    dictationCounts: dictationCounts
                )
            }

            taskBox.task = task
            return await task.value
        } onCancel: {
            taskBox.task?.cancel()
        }
    }

    private static func emptySnapshot() -> RecentCaptureSnapshot {
        RecentCaptureSnapshot(
            meetings: [],
            dictations: [],
            dictationCounts: DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)
        )
    }
}

private final class LoadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTask: Task<RecentCaptureSnapshot, Never>?

    var task: Task<RecentCaptureSnapshot, Never>? {
        get {
            lock.withLock { storedTask }
        }
        set {
            lock.withLock { storedTask = newValue }
        }
    }
}

enum RecentMeetingsScanner {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]
    private static let transcriptProbeByteLimit = 64 * 1024

    static func loadRecent(limit: Int = 3) -> [RecentMeetingItem] {
        guard limit > 0 else { return [] }

        let dir = MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let candidates: [(url: URL, date: Date)] = urls.compactMap { url in
            guard isMarkdownCandidate(url, fileManager: fm) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return (url, date)
        }

        var recentItems: [RecentMeetingItem] = []
        for entry in candidates.sorted(by: { $0.date > $1.date }) {
            guard isMeetingTranscript(entry.url) else { continue }
            let styled = MeetingTranscriptStyler.displayTranscript(at: entry.url)
            recentItems.append(
                RecentMeetingItem(
                    title: styled.title,
                    date: entry.date,
                    transcriptURL: styled.url,
                    audio: MeetingAudioArchiveResolver.attachment(forTranscript: styled.url)
                )
            )
            if recentItems.count >= limit {
                break
            }
        }

        return recentItems
    }

    private static func isMarkdownCandidate(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.pathExtension == "md", !excludedMarkdownFilenames.contains(url.lastPathComponent) else {
            return false
        }

        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
           values.isRegularFile == false {
            return false
        }

        return true
    }

    private static func isMeetingTranscript(_ url: URL) -> Bool {
        guard let probe = readPrefix(at: url, limit: transcriptProbeByteLimit),
              probe.text.hasPrefix("---\n") else {
            return false
        }

        if containsTranscriptMarker(probe.text) {
            return true
        }

        guard probe.reachedLimit,
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return containsTranscriptMarker(raw)
    }

    private static func containsTranscriptMarker(_ text: String) -> Bool {
        text.contains("\n## Full Transcript") || text.contains("\n## Transcript")
    }

    private static func readPrefix(at url: URL, limit: Int) -> (text: String, reachedLimit: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: limit),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (text, data.count == limit)
    }
}
