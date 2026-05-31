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
        let genericSpeakers = genericSpeakerLabels(in: transcriptSpeakerLabels(in: markdown))
        guard !genericSpeakers.isEmpty else { return .ready }
        return .needsReview(genericSpeakers.count)
    }

    private static func genericSpeakerLabels(in speakerLabels: [String]) -> Set<String> {
        var labels = Set<String>()
        let patterns = [
            #"(?i)(?:^|[/\[\s])Speaker\s+\d+\b"#,
            #"(?i)\bUnknown speaker\b"#,
            #"(?i)\bReview later\b"#
        ]

        let text = speakerLabels.joined(separator: "\n")
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
                guard let matchRange = match?.range,
                      let range = Range(matchRange, in: text) else { return }
                labels.insert(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }

        return labels
    }

    private static func transcriptSpeakerLabels(in markdown: String) -> [String] {
        markdown
            .components(separatedBy: .newlines)
            .compactMap { speakerLabel(fromTranscriptLine: $0) }
    }

    private static func speakerLabel(fromTranscriptLine rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("**") {
            let unbolded = line
                .dropFirst(2)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return speakerLabel(fromBoldTimestampLine: line) ?? speakerLabel(fromBracketTimestampLine: unbolded)
        }

        if line.hasPrefix("[") {
            return speakerLabel(fromBracketTimestampLine: line)
        }

        return nil
    }

    private static func speakerLabel(fromBoldTimestampLine line: String) -> String? {
        let timeStart = line.index(line.startIndex, offsetBy: 2)
        guard let timeEnd = line[timeStart...].range(of: "**")?.lowerBound else { return nil }
        let time = String(line[timeStart..<timeEnd])
        guard looksLikeTimestamp(time) else { return nil }
        let remainderStart = line.index(timeEnd, offsetBy: 2)
        return leadingBracketLabel(in: String(line[remainderStart...]))
    }

    private static func speakerLabel(fromBracketTimestampLine line: String) -> String? {
        guard let timeEnd = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<timeEnd])
        guard looksLikeTimestamp(time) else { return nil }
        let remainder = String(line[line.index(after: timeEnd)...])
        return leadingBracketLabel(in: remainder)
    }

    private static func leadingBracketLabel(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["),
              let end = text.firstIndex(of: "]") else { return nil }
        let rawLabel = String(text[text.index(after: text.startIndex)..<end])
        let label = rawLabel
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    private static func looksLikeTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

enum RecentMeetingSpeakerReviewActionPolicy {
    static func shouldShowReviewAction(
        speakerStatus: RecentMeetingSpeakerStatus,
        hasSpeakerReviewWork: Bool
    ) -> Bool {
        speakerStatus.needsReview && hasSpeakerReviewWork
    }
}

enum RecentMeetingRetranscriptionActionPolicy {
    static func shouldShowInlineAction(
        speakerStatus: RecentMeetingSpeakerStatus,
        hasRetainedAudio: Bool,
        hasSpeakerReviewWork: Bool
    ) -> Bool {
        hasRetainedAudio && speakerStatus.needsReview && !hasSpeakerReviewWork
    }
}

enum SavedMeetingRetranscriptionAvailabilityPolicy {
    static func unavailableReason(
        isDictationActive: Bool,
        isMeetingRecording: Bool,
        isPreparingModels: Bool,
        hasMeetingWork: Bool,
        isSpeakerReviewPending: Bool
    ) -> String? {
        if isDictationActive {
            return "Wait for the current dictation to finish before re-transcribing saved audio."
        }
        if isMeetingRecording {
            return "Stop the current recording before re-transcribing saved audio."
        }
        if isPreparingModels {
            return "Preparing models..."
        }
        if hasMeetingWork {
            return "Wait for the current meeting to finish saving or transcribing before re-transcribing saved audio."
        }
        if isSpeakerReviewPending {
            return "Finish the speaker review window before re-transcribing saved audio."
        }
        return nil
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
        includeDictationCounts: Bool = false,
        meetingDirectory: URL? = nil,
        dictationDirectory: URL? = nil,
        today: Date = Date()
    ) async -> RecentCaptureSnapshot {
        let taskBox = LoadTaskBox()

        return await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                let meetings = RecentMeetingsScanner.loadRecent(limit: meetingLimit, directory: meetingDirectory)
                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                let dictations = DictationTranscriptStore.recentSavedDictations(
                    limit: dictationLimit,
                    directory: dictationDirectory
                )
                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                let dictationCounts = includeDictationCounts
                    ? DictationTranscriptStore.savedDictationCounts(directory: dictationDirectory, today: today)
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

    static func loadRecent(limit: Int = 3, directory: URL? = nil) -> [RecentMeetingItem] {
        guard limit > 0 else { return [] }

        let dir = directory ?? MeetingStoragePaths.transcriptsFolder
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
