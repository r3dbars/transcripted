import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct RecentMeetingItem: Identifiable, Sendable {
    let title: String
    let date: Date
    let startDate: Date?
    let endDate: Date?
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?
    let speakerStatus: RecentMeetingSpeakerStatus
    var audioHealth: RecentMeetingAudioHealth? = nil

    var id: String { transcriptURL.path }
}

/// Issue #500 post-meeting surfacing: facts read back from the saved
/// transcript's `audio_health` / `mic_boost_prompt` frontmatter keys.
struct RecentMeetingAudioHealth: Equatable, Sendable {
    let micBoostPromptOutcome: String?  // raw frontmatter value; nil when key absent

    static func detect(frontmatter: TranscriptFrontmatterDocument?) -> RecentMeetingAudioHealth? {
        guard frontmatter?.values["audio_health"] == "mic_attenuated_by_call_app" else { return nil }
        return RecentMeetingAudioHealth(micBoostPromptOutcome: frontmatter?.values["mic_boost_prompt"])
    }
}

enum RecentMeetingMicBoostHintPolicy {
    static func shouldOfferEnableAction(
        audioHealth: RecentMeetingAudioHealth?,
        voiceProcessingPreferenceEnabled: Bool
    ) -> Bool {
        guard let audioHealth else { return false }
        guard audioHealth.micBoostPromptOutcome != "accepted" else { return false }
        // Frontmatter is immutable history: once the preference is on, stop
        // hinting on old rows — the user already fixed it.
        return !voiceProcessingPreferenceEnabled
    }
}

enum RecentMeetingSpeakerStatus: Equatable, Sendable {
    case ready
    case needsReview(Int)

    var summary: String {
        switch self {
        case .ready:
            return "Speakers ready"
        case .needsReview(let count):
            return count == 1 ? "1 speaker label needs a name" : "\(count) speaker labels need names"
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
        // Callers besides the direct "[" dispatch (e.g. the bold-prefix fallback in
        // speakerLabel(fromTranscriptLine:)) can hand this a string that never had a
        // leading "[". Without this guard, a line whose first character is "]" (e.g. the
        // malformed "**]" transcript line, which unbolds to "]") makes firstIndex(of: "]")
        // land at startIndex while line.index(after: line.startIndex) steps one past it,
        // producing an inverted range and trapping.
        guard line.hasPrefix("["), let timeEnd = line.firstIndex(of: "]") else { return nil }
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

enum RecentMeetingRetranscriptionMenuActionPolicy {
    static func isEnabled(globalUnavailableReason: String?) -> Bool {
        globalUnavailableReason == nil
    }
}

enum SavedMeetingRetranscriptionAvailabilityPolicy {
    static func unavailableReason(
        isDictationActive: Bool,
        isMeetingRecording: Bool,
        isPreparingModels: Bool,
        hasMeetingWork: Bool,
        isSpeakerReviewPending: Bool,
        isTargetSpeakerReview: Bool
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
        if isSpeakerReviewPending && !isTargetSpeakerReview {
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

                async let meetings = RecentMeetingsScanner.loadRecent(
                    limit: meetingLimit,
                    directory: meetingDirectory
                )
                async let dictations = DictationTranscriptStore.recentSavedDictations(
                    limit: dictationLimit,
                    directory: dictationDirectory
                )
                async let dictationCounts = includeDictationCounts
                    ? DictationTranscriptStore.savedDictationCounts(directory: dictationDirectory, today: today)
                    : DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)

                let snapshot = await RecentCaptureSnapshot(
                    meetings: meetings,
                    dictations: dictations,
                    dictationCounts: dictationCounts
                )
                guard !Task.isCancelled else {
                    return emptySnapshot()
                }

                return snapshot
            }

            taskBox.task = task
            return await task.value
        } onCancel: {
            taskBox.cancel()
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
    private var isCancelled = false

    var task: Task<RecentCaptureSnapshot, Never>? {
        get {
            lock.withLock { storedTask }
        }
        set {
            lock.withLock {
                storedTask = newValue
                if isCancelled {
                    newValue?.cancel()
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            storedTask?.cancel()
        }
    }
}

/// Why the meetings-folder scan could not list rows. Separates the benign
/// "folder isn't there yet" empty state from a genuinely damaged/broken path
/// (the path exists but isn't a directory, or it can't be read) so Home can
/// surface a named warning only in the second case.
enum RecentMeetingsScanDiagnosis: Equatable, Sendable {
    case ok
    /// Folder does not exist yet — normal first-run empty state, not a warning.
    case missingFolder
    /// The path exists but the app cannot scan it as a meetings folder.
    case damagedPath(reason: RecentMeetingsScanDamageReason)
}

enum RecentMeetingsScanDamageReason: Equatable, Sendable {
    /// The capture-library meetings path resolves to a file, not a folder.
    case notADirectory
    /// The folder exists but its contents could not be listed.
    case unreadable
}

enum RecentMeetingsScanner {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]

    /// Classifies the meetings folder without loading rows. `loadRecent` fails
    /// closed (returns `[]`) for both a missing folder and a damaged path, which
    /// is correct for the list but hides breakage from the user — Home calls this
    /// to tell those two cases apart and warn only on real damage.
    static func diagnose(directory: URL? = nil) -> RecentMeetingsScanDiagnosis {
        let dir = directory ?? MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
            return .missingFolder
        }
        guard isDirectory.boolValue else {
            return .damagedPath(reason: .notADirectory)
        }
        do {
            _ = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .damagedPath(reason: .unreadable)
        }
        return .ok
    }

    static func loadRecent(
        limit: Int = 3,
        directory: URL? = nil,
        cache: RecentMeetingMetadataCache? = .shared
    ) -> [RecentMeetingItem] {
        guard limit > 0 else { return [] }

        let dir = directory ?? MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default

        // Self-heal before scanning: drop cached rows whose transcript no longer
        // exists so deleted/moved meetings (and any fixture rows a mis-scoped
        // caller wrote) can't strand the Home list. This runs on the background
        // refresh task, so the `stat`-per-row cost stays off the main thread.
        cache?.pruneMissingPathsIfNeeded(fileManager: fm)

        guard fm.fileExists(atPath: dir.path) else { return [] }

        let keys: [URLResourceKey] = [
            .creationDateKey, .contentModificationDateKey, .isRegularFileKey, .fileSizeKey
        ]
        let requestedKeys = Set(keys)
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, date: Date, modified: Double, size: Int64)] = []
        for url in urls {
            if Task.isCancelled { return [] }
            guard isMarkdownCandidate(url) else { continue }
            let values = try? url.resourceValues(forKeys: requestedKeys)
            if values?.isRegularFile == false {
                continue
            }
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let size = Int64(values?.fileSize ?? 0)
            candidates.append((url, date, modified, size))
        }

        var recentItems: [RecentMeetingItem] = []
        for entry in candidates.sorted(by: { $0.date > $1.date }) {
            if Task.isCancelled { return [] }

            let stamp = RecentMeetingCacheStamp(
                transcriptModified: entry.modified,
                transcriptSize: entry.size
            )

            // Warm path: serve the row straight from the index, with no transcript
            // content read. Only the live audio attachment is resolved.
            if let cache,
               let cached = cache.lookup(path: entry.url.path, stamp: stamp) {
                recentItems.append(
                    cached.makeItem(
                        transcriptURL: entry.url,
                        audio: MeetingAudioArchiveResolver.attachment(forTranscript: entry.url)
                    )
                )
                if recentItems.count >= limit {
                    break
                }
                continue
            }

            // Cold path: parse the transcript, then populate the index so the next
            // refresh stays off disk.
            guard let styled = MeetingTranscriptStyler.displayTranscriptPreview(at: entry.url) else {
                continue
            }
            let markdown = (try? String(contentsOf: styled.url, encoding: .utf8)) ?? ""
            let frontmatter = TranscriptFrontmatter.document(in: markdown)
            let timing = meetingTiming(
                frontmatter: frontmatter,
                fallbackDate: entry.date
            )
            let displayDate = timing.start ?? entry.date
            let item = RecentMeetingItem(
                title: styled.title,
                date: displayDate,
                startDate: timing.start,
                endDate: timing.end,
                transcriptURL: styled.url,
                audio: MeetingAudioArchiveResolver.attachment(forTranscript: styled.url),
                speakerStatus: RecentMeetingSpeakerStatus.detect(in: markdown),
                audioHealth: RecentMeetingAudioHealth.detect(frontmatter: frontmatter)
            )
            cache?.store(
                path: entry.url.path,
                stamp: stamp,
                metadata: CachedRecentMeetingMetadata(item: item)
            )
            recentItems.append(item)
            if recentItems.count >= limit {
                break
            }
        }

        return recentItems
    }

    private static func isMarkdownCandidate(_ url: URL) -> Bool {
        url.pathExtension == "md"
            && !url.deletingPathExtension().lastPathComponent.hasSuffix(".summary")
            && !excludedMarkdownFilenames.contains(url.lastPathComponent)
    }

    private static func meetingTiming(
        frontmatter: TranscriptFrontmatterDocument?,
        fallbackDate: Date
    ) -> (start: Date?, end: Date?) {
        guard let frontmatter else { return (fallbackDate, nil) }
        let start = TranscriptFrontmatter.recordedAt(values: frontmatter.values) ?? fallbackDate
        let durationSeconds = TranscriptFrontmatter.durationSeconds(from: frontmatter.values["duration"]) ?? 0
        let end = durationSeconds > 0 ? start.addingTimeInterval(TimeInterval(durationSeconds)) : nil
        return (start, end)
    }

}
