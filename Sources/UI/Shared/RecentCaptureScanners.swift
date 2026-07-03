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
    let summaryPreview: RecentMeetingSummaryPreview?
    var audioHealth: RecentMeetingAudioHealth? = nil

    var id: String { transcriptURL.path }
    var displayTitle: String { summaryPreview?.title ?? title }
    var hasGeneratedTitle: Bool {
        guard let generated = summaryPreview?.title else { return false }
        return generated.compare(
            title,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != .orderedSame
    }
}

struct RecentMeetingSummaryPreview: Equatable, Sendable {
    let title: String?
    let summary: String
    let sections: [RecentMeetingSummarySection]
    let url: URL
}

struct RecentMeetingSummarySection: Identifiable, Equatable, Sendable {
    let title: String
    let text: String

    var id: String { title }
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

enum RecentMeetingRetranscriptionMenuActionPolicy {
    static func isEnabled(
        globalUnavailableReason: String?,
        hasSpeakerReviewWork: Bool
    ) -> Bool {
        globalUnavailableReason == nil && !hasSpeakerReviewWork
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

enum LocalMeetingSummaryAvailabilityPolicy {
    static func unavailableReason(
        isDictationActive: Bool,
        isMeetingRecording: Bool,
        isPreparingModels: Bool,
        isPreparingLocalSummaryModel: Bool = false,
        hasMeetingWork: Bool,
        isSpeakerReviewPending: Bool
    ) -> String? {
        if isDictationActive {
            return "Wait for the current dictation to finish before summarizing a meeting."
        }
        if isMeetingRecording {
            return "Stop the current recording before summarizing a saved meeting."
        }
        if isPreparingModels {
            return "Preparing models..."
        }
        if isPreparingLocalSummaryModel {
            return "Gemma is still preparing. Wait for setup to finish, or cancel setup from Beta settings before summarizing."
        }
        if hasMeetingWork {
            return "Wait for the current meeting to finish saving or transcribing before summarizing."
        }
        if isSpeakerReviewPending {
            return "Finish the speaker review window before summarizing a meeting."
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
    private static let summaryPreviewByteLimit = 64 * 1024

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

            let stamp = cacheStamp(
                transcriptModified: entry.modified,
                transcriptSize: entry.size,
                transcriptURL: entry.url
            )

            // Warm path: serve the row straight from the index, with no transcript
            // or summary content read. Only the live audio attachment is resolved.
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

            // Cold path: parse the transcript (and any summary sidecar), then
            // populate the index so the next refresh stays off disk.
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
                summaryPreview: loadSummaryPreview(for: styled.url, markdown: markdown, frontmatter: frontmatter),
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

    /// Build the cache validity stamp from cheap `stat` metadata only. The summary
    /// sidecar is folded in so a sidecar that appears or changes without rewriting
    /// the transcript still invalidates the cached row.
    private static func cacheStamp(
        transcriptModified: Double,
        transcriptSize: Int64,
        transcriptURL: URL
    ) -> RecentMeetingCacheStamp {
        let summaryURL = LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
        let summaryValues = try? summaryURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let summaryModified = summaryValues?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let summarySize = summaryValues?.fileSize.map(Int64.init) ?? -1
        return RecentMeetingCacheStamp(
            transcriptModified: transcriptModified,
            transcriptSize: transcriptSize,
            summaryModified: summaryModified,
            summarySize: summarySize
        )
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

    private static func loadSummaryPreview(
        for transcriptURL: URL,
        markdown: String,
        frontmatter: TranscriptFrontmatterDocument?
    ) -> RecentMeetingSummaryPreview? {
        if let preview = RecentMeetingSummaryPreviewParser.inlinePreview(
            from: markdown,
            frontmatter: frontmatter,
            url: transcriptURL
        ) {
            return preview
        }

        let summaryURL = LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
        guard FileManager.default.fileExists(atPath: summaryURL.path),
              let markdown = readSummaryPreviewMarkdown(at: summaryURL) else {
            return nil
        }
        return RecentMeetingSummaryPreviewParser.preview(
            from: markdown,
            url: summaryURL,
            sourceTranscriptFilename: transcriptURL.lastPathComponent
        )
    }

    private static func readSummaryPreviewMarkdown(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: summaryPreviewByteLimit),
              !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

enum RecentMeetingSummaryPreviewParser {
    private static let maximumPreviewCharacters = 2_400

    static func inlinePreview(
        from markdown: String,
        frontmatter: TranscriptFrontmatterDocument? = nil,
        url: URL
    ) -> RecentMeetingSummaryPreview? {
        let document = frontmatter ?? TranscriptFrontmatter.document(in: markdown)
        guard let document,
              document.values["local_summary_version"] != nil else {
            return nil
        }

        let summarySections = sectionsFromLocalSummaryBody(document.body)
        let frontmatterSections = sectionsFromFrontmatter(document.values)
        let sections = summarySections.isEmpty ? frontmatterSections : summarySections
        guard let summary = sections.first(where: { $0.title == "Summary" })?.text,
              !summary.isEmpty,
              summary != "None found." else {
            return nil
        }

        return RecentMeetingSummaryPreview(
            title: cleanTitle(document.values["local_summary_title"]),
            summary: limited(summary, to: maximumPreviewCharacters),
            sections: sections,
            url: url
        )
    }

    static func preview(
        from markdown: String,
        url: URL,
        sourceTranscriptFilename: String? = nil
    ) -> RecentMeetingSummaryPreview? {
        let frontmatter = TranscriptFrontmatter.document(in: markdown)
        guard let frontmatter,
              frontmatter.values["capture_type"] == "meeting_summary" else {
            return nil
        }
        if let sourceTranscriptFilename,
           let sourceTranscript = frontmatter.values["source_transcript"],
           sourceTranscript != sourceTranscriptFilename {
            return nil
        }
        let body = frontmatter.body
        let title = cleanTitle(frontmatter.values["summary_title"])
            ?? summaryTitle(in: body)
        let sections = sectionsFromGeneratedSummaryBody(body)
        let summary = sections.first(where: { $0.title == "Summary" })?.text ?? ""

        guard !summary.isEmpty else { return nil }
        return RecentMeetingSummaryPreview(
            title: title,
            summary: limited(summary, to: maximumPreviewCharacters),
            sections: sections,
            url: url
        )
    }

    private static func sectionsFromFrontmatter(_ values: [String: String]) -> [RecentMeetingSummarySection] {
        [
            ("Participants", values["local_summary_participants"]),
            ("Summary", values["local_summary"]),
            ("Next Steps", values["local_summary_next_steps"]),
            ("Decisions", values["local_summary_decisions"]),
            ("Action Items", values["local_summary_action_items"]),
            ("Open Questions", values["local_summary_open_questions"]),
            ("Risks or Follow-ups", values["local_summary_risks_or_followups"]),
            ("Accuracy Notes", values["local_summary_accuracy_notes"])
        ].compactMap { title, value in
            guard let text = cleanSummaryValue(value), !text.isEmpty else { return nil }
            return RecentMeetingSummarySection(title: title, text: text)
        }
    }

    private static func sectionsFromLocalSummaryBody(_ body: String) -> [RecentMeetingSummarySection] {
        let searchBody = LocalMeetingSummaryMarkdownUpdater.localSummaryBlock(in: body) ?? body
        guard let localSummary = section("## Local Apple Summary", in: searchBody, headingLevel: "##")
            ?? section("## Local Gemma Summary", in: searchBody, headingLevel: "##")
            ?? section("## Local Summary", in: searchBody, headingLevel: "##") else {
            return []
        }

        return [
            "Participants",
            "Summary",
            "Next Steps",
            "Decisions",
            "Action Items",
            "Open Questions",
            "Risks or Follow-ups",
            "Accuracy Notes"
        ].compactMap { title in
            guard let rawText = section("### \(title)", in: localSummary, headingLevel: "###") else {
                return nil
            }
            let text = cleanSectionText(rawText)
            guard !text.isEmpty else {
                return nil
            }
            return RecentMeetingSummarySection(title: title, text: text)
        }
    }

    private static func sectionsFromGeneratedSummaryBody(_ body: String) -> [RecentMeetingSummarySection] {
        [
            ("Participants", "# Participants"),
            ("Summary", "# Summary"),
            ("Next Steps", "# Next Steps"),
            ("Decisions", "# Decisions"),
            ("Action Items", "# Action Items"),
            ("Open Questions", "# Open Questions"),
            ("Risks or Follow-ups", "# Risks or Follow-ups"),
            ("Accuracy Notes", "# Accuracy Notes")
        ].compactMap { title, heading in
            guard let rawText = section(heading, in: body, headingLevel: "#") else {
                return nil
            }
            let text = cleanSectionText(rawText)
            guard !text.isEmpty,
                  text != "None found." else {
                return nil
            }
            return RecentMeetingSummarySection(title: title, text: text)
        }
    }

    private static func summaryTitle(in body: String) -> String? {
        cleanTitle(section("# Title", in: body, headingLevel: "#")?.components(separatedBy: .newlines).first)
    }

    private static func summaryText(in body: String) -> String {
        guard let raw = section("# Summary", in: body, headingLevel: "#") else { return "" }
        let lines = raw
            .components(separatedBy: .newlines)
            .map(cleanSummaryLine)
            .filter { !$0.isEmpty }

        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "None found." ? "" : text
    }

    private static func section(_ heading: String, in body: String, headingLevel: String) -> String? {
        let body = LocalMeetingSummaryMarkdownUpdater.removingLocalSummaryMarkers(from: body)
        let lines = body.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading
        }) else {
            return nil
        }

        var endIndex = lines.endIndex
        for index in lines.index(after: startIndex)..<lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(headingLevel) "), trimmed != heading {
                endIndex = index
                break
            }
        }

        return lines[lines.index(after: startIndex)..<endIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTitle(_ raw: String?) -> String? {
        let title = cleanMarkdown(raw)
        guard !title.isEmpty, title != "None found." else { return nil }
        return String(title.prefix(96))
    }

    private static func cleanSummaryLine(_ raw: String) -> String {
        cleanMarkdown(raw)
    }

    private static func cleanSectionText(_ raw: String) -> String {
        let text = raw
            .components(separatedBy: .newlines)
            .map(cleanSummaryLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "None found." ? "" : text
    }

    private static func cleanSummaryValue(_ raw: String?) -> String? {
        let text = cleanMarkdown(raw)
            .replacingOccurrences(of: " | ", with: "\n")
        return text.isEmpty || text == "None found." ? nil : text
    }

    private static func cleanMarkdown(_ raw: String?) -> String {
        var text = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for prefix in ["- ", "* "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limited(_ value: String, to characterLimit: Int) -> String {
        guard value.count > characterLimit else { return value }
        return String(value.prefix(characterLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
