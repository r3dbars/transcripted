import Foundation

struct RecentMeetingItem: Identifiable, Sendable {
    let title: String
    let date: Date
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?
    let speakerStatus: RecentMeetingSpeakerStatus

    var id: String { transcriptURL.path }
}

enum RecentMeetingSpeakerStatus: Equatable, Sendable {
    case ready
    case needsReview(Int)

    var summary: String {
        switch self {
        case .ready:
            return "Speakers ready"
        case .needsReview(let count):
            return count == 1 ? "1 speaker needs review" : "\(count) speakers need review"
        }
    }

    var needsReview: Bool {
        if case .needsReview = self { return true }
        return false
    }

    static func detect(in markdown: String) -> RecentMeetingSpeakerStatus {
        let genericSpeakers = genericSpeakerLabels(in: markdown)
        guard !genericSpeakers.isEmpty else { return .ready }
        return .needsReview(genericSpeakers.count)
    }

    private static func genericSpeakerLabels(in markdown: String) -> Set<String> {
        var labels = Set<String>()
        let patterns = [
            #"(?i)(?:^|[/\[\s])Speaker\s+\d+\b"#,
            #"(?i)\bUnknown speaker\b"#,
            #"(?i)\bReview later\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
            regex.enumerateMatches(in: markdown, range: nsRange) { match, _, _ in
                guard let matchRange = match?.range,
                      let range = Range(matchRange, in: markdown) else { return }
                labels.insert(String(markdown[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }

        return labels
    }
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
            guard let styled = MeetingTranscriptStyler.displayTranscriptPreview(at: entry.url) else {
                continue
            }
            let markdown = (try? String(contentsOf: styled.url, encoding: .utf8)) ?? ""
            recentItems.append(
                RecentMeetingItem(
                    title: styled.title,
                    date: entry.date,
                    transcriptURL: styled.url,
                    audio: MeetingAudioArchiveResolver.attachment(forTranscript: styled.url),
                    speakerStatus: RecentMeetingSpeakerStatus.detect(in: markdown)
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
}
