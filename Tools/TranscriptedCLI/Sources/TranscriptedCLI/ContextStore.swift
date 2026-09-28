import ArgumentParser
import Foundation
import TranscriptedCaptureKit

struct CLIContextDirectories {
    let meetingDirs: [URL]
    let dictationDirs: [URL]
    /// Writing day files. Empty when meetings or dictations were pointed at
    /// specific folders without `--writing-dir` (see CaptureLibraryResolver).
    let writingDirs: [URL]

    var meetingsDir: URL {
        meetingDirs[0]
    }

    var dictationsDir: URL {
        dictationDirs[0]
    }

    init(meetingsDir: URL, dictationsDir: URL, writingDir: URL? = nil) {
        self.meetingDirs = [meetingsDir]
        self.dictationDirs = [dictationsDir]
        self.writingDirs = writingDir.map { [$0] } ?? []
    }

    init(meetingDirs: [URL], dictationDirs: [URL], writingDirs: [URL] = []) {
        self.meetingDirs = meetingDirs
        self.dictationDirs = dictationDirs
        self.writingDirs = writingDirs
    }

    static func resolve(
        dataDir: String?,
        meetingsDir: String?,
        dictationsDir: String?,
        writingDir: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> CLIContextDirectories {
        let resolved = CaptureLibraryResolver.resolve(
            dataDir: dataDir,
            meetingsDir: meetingsDir,
            dictationsDir: dictationsDir,
            writingDir: writingDir,
            environment: environment,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
        return CLIContextDirectories(
            meetingDirs: resolved.meetingDirs,
            dictationDirs: resolved.dictationDirs,
            writingDirs: resolved.writingDirs
        )
    }
}

struct CLIContextPathOptions: ParsableArguments {
    @Option(name: .long, help: "Shared context directory containing meetings, dictations, and writing.")
    var dataDir: String?

    @Option(name: .long, help: "Meetings transcript directory.")
    var meetingsDir: String?

    @Option(name: .long, help: "Dictations transcript directory.")
    var dictationsDir: String?

    @Option(name: .long, help: "Writing directory (Writing_<date>.md day files). Required to include writing when --meetings-dir or --dictations-dir is set.")
    var writingDir: String?

    var resolved: CLIContextDirectories {
        CLIContextDirectories.resolve(
            dataDir: dataDir,
            meetingsDir: meetingsDir,
            dictationsDir: dictationsDir,
            writingDir: writingDir
        )
    }
}

enum CLIContextStore {
    static func listDictationDays(in directories: CLIContextDirectories, count: Int, dateFrom: String?, dateTo: String?) -> [CLIDictationDaySummary] {
        let days = loadDictationDays(from: directories.dictationDirs).filter { day in
            if let dateFrom, day.date < dateFrom { return false }
            if let dateTo, day.date > dateTo { return false }
            return true
        }

        return Array(days.sorted { $0.datetime > $1.datetime }.prefix(count).map {
            CLIDictationDaySummary(
                filename: $0.filename,
                date: $0.date,
                datetime: $0.datetime,
                entryCount: $0.entries.count,
                wordCount: $0.wordCount,
                titles: $0.titles,
                sourceApps: $0.sourceApps
            )
        })
    }

    static func listWritingDays(in directories: CLIContextDirectories, count: Int, dateFrom: String?, dateTo: String?) -> [CLIWritingDaySummary] {
        let days = loadWritingDays(from: directories.writingDirs).filter { day in
            matches(date: day.payload.date, dateFrom: dateFrom, dateTo: dateTo)
        }

        return Array(days.sorted { $0.datetime > $1.datetime }.prefix(count).map {
            CLIWritingDaySummary(
                filename: $0.filename,
                date: $0.payload.date,
                datetime: $0.datetime,
                entryCount: $0.payload.entries.count,
                wordCount: $0.payload.wordCount,
                acceptedWordCount: $0.payload.acceptedWordCount,
                titles: $0.payload.entries.map(\.title),
                sourceApps: Array(Set($0.payload.entries.map(\.sourceAppName))).sorted()
            )
        })
    }

    static func recent(in directories: CLIContextDirectories, kind: CLIContextKind, count: Int, dateFrom: String?, dateTo: String?) -> [CLIContextItem] {
        var items: [CLIContextItem] = []

        if kind.includes(.meeting) {
            items.append(contentsOf: loadMeetings(from: directories.meetingDirs).compactMap { meeting in
                guard matches(date: meeting.date, dateFrom: dateFrom, dateTo: dateTo) else { return nil }
                return CLIContextItem(
                    kind: .meeting,
                    title: meeting.title,
                    filename: meeting.filename,
                    entryId: nil,
                    date: meeting.date,
                    datetime: meeting.datetime,
                    preview: recentMeetingPreview(for: meeting),
                    wordCount: meeting.wordCount,
                    speakers: meeting.speakers,
                    sourceAppName: nil,
                    delivery: nil
                )
            })
        }

        if kind.includes(.dictation) {
            items.append(contentsOf: loadDictationDays(from: directories.dictationDirs).flatMap { day in
                day.entries.compactMap { entry in
                    guard matches(date: day.date, dateFrom: dateFrom, dateTo: dateTo) else { return nil }
                    return CLIContextItem(
                        kind: .dictation,
                        title: entry.title,
                        filename: day.filename,
                        entryId: entry.id,
                        date: day.date,
                        datetime: entry.createdAt,
                        preview: String(entry.text.prefix(220)),
                        wordCount: entry.wordCount,
                        speakers: nil,
                        sourceAppName: entry.sourceAppName,
                        delivery: entry.delivery
                    )
                }
            })
        }

        if kind.includes(.writing) {
            items.append(contentsOf: writingItems(in: directories, dateFrom: dateFrom, dateTo: dateTo) { _ in true })
        }

        return Array(items.sorted { $0.datetime > $1.datetime }.prefix(count))
    }

    static func search(query: String, speaker: String?, in directories: CLIContextDirectories, kind: CLIContextKind, count: Int, dateFrom: String?, dateTo: String?) -> [CLIContextItem] {
        let normalizedQuery = query.lowercased()
        var items: [CLIContextItem] = []

        if kind.includes(.meeting) {
            items.append(contentsOf: loadMeetings(from: directories.meetingDirs).compactMap { meeting in
                guard matches(date: meeting.date, dateFrom: dateFrom, dateTo: dateTo) else { return nil }
                if let speaker, !meeting.speakers.contains(where: { $0.localizedCaseInsensitiveContains(speaker) }) {
                    return nil
                }
                let textMatch = meeting.utterances.first { utterance in
                    utterance.text.localizedCaseInsensitiveContains(normalizedQuery)
                        && (speaker == nil || speakerMatches(filter: speaker!, speakerName: utterance.speakerId))
                }
                let metadataMatch = meeting.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || meeting.speakers.contains(where: { $0.localizedCaseInsensitiveContains(normalizedQuery) })
                guard let preview = textMatch.map({ String($0.text.prefix(220)) })
                    ?? (metadataMatch ? recentMeetingPreview(for: meeting, preferredSpeaker: speaker) : nil) else { return nil }
                return CLIContextItem(
                    kind: .meeting,
                    title: meeting.title,
                    filename: meeting.filename,
                    entryId: nil,
                    date: meeting.date,
                    datetime: meeting.datetime,
                    preview: preview,
                    wordCount: meeting.wordCount,
                    speakers: meeting.speakers,
                    sourceAppName: nil,
                    delivery: nil
                )
            })
        }

        if kind.includes(.dictation), speaker == nil {
            items.append(contentsOf: loadDictationDays(from: directories.dictationDirs).flatMap { day in
                day.entries.compactMap { entry in
                    guard matches(date: day.date, dateFrom: dateFrom, dateTo: dateTo) else { return nil }
                    guard entry.title.localizedCaseInsensitiveContains(normalizedQuery)
                            || entry.text.localizedCaseInsensitiveContains(normalizedQuery)
                    else { return nil }

                    return CLIContextItem(
                        kind: .dictation,
                        title: entry.title,
                        filename: day.filename,
                        entryId: entry.id,
                        date: day.date,
                        datetime: entry.createdAt,
                        preview: String(entry.text.prefix(220)),
                        wordCount: entry.wordCount,
                        speakers: nil,
                        sourceAppName: entry.sourceAppName,
                        delivery: entry.delivery
                    )
                }
            })
        }

        // Writing has no speakers, so a speaker filter skips it like dictations.
        if kind.includes(.writing), speaker == nil {
            items.append(contentsOf: writingItems(in: directories, dateFrom: dateFrom, dateTo: dateTo) { entry in
                entry.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || entry.text.localizedCaseInsensitiveContains(normalizedQuery)
            })
        }

        return Array(items.sorted { $0.datetime > $1.datetime }.prefix(count))
    }

    static func readMeeting(filename: String, in directories: CLIContextDirectories) throws -> String {
        let requestedName = filename.hasSuffix(".md") ? filename : filename + ".md"
        var invalidPathRequested = false
        var markdownURL: URL?
        for directory in directories.meetingDirs {
            switch CLIPathSecurity.resolveReadableFile(named: requestedName, in: directory) {
            case .valid(let safeURL):
                markdownURL = safeURL
            case .missing:
                continue
            case .invalid:
                invalidPathRequested = true
            }
            if markdownURL != nil { break }
        }

        if invalidPathRequested && markdownURL == nil {
            throw ValidationError("Invalid meeting filename: \(filename)")
        }

        // Only a meeting reads as a meeting: dictation and writing day files
        // share folders with meetings in the flat shared-folder layout.
        guard let markdownURL,
              let content = CaptureMarkdown.readBoundedContents(of: markdownURL),
              CaptureMarkdown.captureKind(of: markdownURL) == .meeting else {
            throw ValidationError("Meeting not found: \(filename)")
        }

        return content
    }

    struct WritingRead {
        let markdown: String
        let date: String
        let entries: [CLIClientWritingEntry]
    }

    static func readWritingDocument(filename: String, entryId: String?, in directories: CLIContextDirectories) throws -> WritingRead {
        let requestedName = filename.hasSuffix(".md") ? filename : filename + ".md"
        var invalidPathRequested = false
        var markdownURL: URL?
        for directory in directories.writingDirs {
            switch CLIPathSecurity.resolveReadableFile(named: requestedName, in: directory) {
            case .valid(let safeURL):
                markdownURL = safeURL
            case .missing:
                continue
            case .invalid:
                invalidPathRequested = true
            }
            if markdownURL != nil { break }
        }

        if invalidPathRequested && markdownURL == nil {
            throw ValidationError("Invalid writing filename: \(filename)")
        }

        guard let markdownURL,
              CaptureMarkdown.captureKind(of: markdownURL) == .writingDay,
              let (payload, content) = loadWritingDay(at: markdownURL) else {
            throw ValidationError("Writing not found: \(filename)")
        }

        if let entryId {
            guard let entry = payload.entries.first(where: { $0.id == entryId }) else {
                throw ValidationError("Writing entry not found: \(entryId)")
            }

            let markdown = """
            # \(entry.title)

            Captured: \(entry.createdAt)
            Source app: \(entry.sourceAppName)
            Words: \(entry.wordCount)
            Accepted words: \(entry.acceptedWordCount)

            \(entry.text)
            """
            return WritingRead(markdown: markdown, date: payload.date, entries: [entry])
        }

        return WritingRead(markdown: content, date: payload.date, entries: payload.entries)
    }

    struct DictationRead {
        let markdown: String
        let date: String
        let entries: [CLIClientDictationEntry]
    }

    static func readDictation(filename: String, entryId: String?, in directories: CLIContextDirectories) throws -> String {
        try readDictationDocument(filename: filename, entryId: entryId, in: directories).markdown
    }

    static func readDictationDocument(filename: String, entryId: String?, in directories: CLIContextDirectories) throws -> DictationRead {
        let requestedName = filename.hasSuffix(".md") ? filename : filename + ".md"
        var invalidPathRequested = false
        var markdownURL: URL?
        for directory in directories.dictationDirs {
            switch CLIPathSecurity.resolveReadableFile(named: requestedName, in: directory) {
            case .valid(let safeURL):
                markdownURL = safeURL
            case .missing:
                continue
            case .invalid:
                invalidPathRequested = true
            }
            if markdownURL != nil { break }
        }

        if invalidPathRequested && markdownURL == nil {
            throw ValidationError("Invalid dictation filename: \(filename)")
        }

        guard let markdownURL else {
            throw ValidationError("Dictation not found: \(filename)")
        }

        guard let day = loadDictationDay(at: markdownURL) else {
            throw ValidationError("Dictation not found: \(filename)")
        }

        if let entryId {
            guard let entry = day.entries.first(where: { $0.id == entryId }) else {
                throw ValidationError("Dictation entry not found: \(entryId)")
            }

            let markdown = """
            # \(entry.title)

            Captured: \(entry.createdAt)
            Source app: \(entry.sourceAppName)
            Delivery: \(entry.delivery)
            Words: \(entry.wordCount)

            \(entry.text)
            """
            return DictationRead(markdown: markdown, date: day.payload.date, entries: [entry])
        }

        if let content = CaptureMarkdown.readBoundedContents(of: markdownURL) {
            return DictationRead(markdown: content, date: day.payload.date, entries: day.entries)
        }

        let data = try JSONEncoder.contextPretty.encode(day.payload)
        return DictationRead(
            markdown: String(data: data, encoding: .utf8) ?? "{}",
            date: day.payload.date,
            entries: day.entries
        )
    }

    private struct MeetingRecord {
        let filename: String
        let title: String
        let date: String
        let datetime: String
        let wordCount: Int
        let speakers: [String]
        let utterances: [CLIUtterance]
    }

    private struct DictationDayRecord {
        let filename: String
        let date: String
        let datetime: String
        let titles: [String]
        let sourceApps: [String]
        let wordCount: Int
        let entries: [CLIClientDictationEntry]
        let payload: CLIAgentDictationDay
    }

    private struct WritingDayRecord {
        let filename: String
        let datetime: String
        let payload: CLIAgentWritingDay
    }

    private static func loadMeetings(from directories: [URL]) -> [MeetingRecord] {
        deduplicating(directories.flatMap { loadMeetings(from: $0) }, by: \.filename)
    }

    private static func loadMeetings(from directory: URL) -> [MeetingRecord] {
        let files = safeMarkdownFiles(in: directory)
        return files.compactMap { url in
            let filename = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "md",
                  !filename.hasPrefix("Dictations_"),
                  // A writing day file has frontmatter too; in the flat
                  // shared-folder layout it must not surface as a meeting.
                  CaptureMarkdown.captureKind(of: url) != .writingDay,
                  // One read per meeting: the transcript parse and the title
                  // extraction below both work off this same content. Reading
                  // it once here also means the title comes from the
                  // path-security-validated URL rather than a rebuilt one.
                  let content = CaptureMarkdown.readBoundedContents(of: url),
                  let transcript = meetingTranscript(fromMarkdown: content) else { return nil }

            let title = CaptureMarkdown.extractTitle(from: content) ?? filename
            // Speaker ids come from file content, so a hand-edited transcript
            // can repeat one; `uniqueKeysWithValues` traps on a duplicate key.
            let speakerLookup = Dictionary(transcript.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return MeetingRecord(
                filename: filename,
                title: title,
                date: String(transcript.recording.date.prefix(10)),
                datetime: transcript.recording.date,
                wordCount: transcript.speakers.reduce(0) { $0 + $1.wordCount },
                speakers: uniqueSpeakerNames(from: transcript.speakers.map(\.name)),
                utterances: transcript.utterances.map { utterance in
                    CLIUtterance(
                        start: utterance.start,
                        end: utterance.end,
                        speakerId: speakerLookup[utterance.speakerId] ?? utterance.speakerId,
                        text: utterance.text
                    )
                }
            )
        }
    }

    private static func loadDictationDays(from directories: [URL]) -> [DictationDayRecord] {
        deduplicating(directories.flatMap { loadDictationDays(from: $0) }, by: \.filename)
    }

    private static func loadDictationDays(from directory: URL) -> [DictationDayRecord] {
        let files = safeMarkdownFiles(in: directory)
        return files.compactMap { url in
            guard url.pathExtension == "md", url.deletingPathExtension().lastPathComponent.hasPrefix("Dictations_") else { return nil }
            guard let day = loadDictationDay(at: url) else { return nil }

            return DictationDayRecord(
                filename: url.deletingPathExtension().lastPathComponent,
                date: day.payload.date,
                datetime: day.entries.last?.createdAt ?? "\(day.payload.date)T00:00:00+0000",
                titles: day.entries.map(\.title),
                sourceApps: Array(Set(day.entries.map(\.sourceAppName))).sorted(),
                wordCount: day.payload.wordCount,
                entries: day.entries,
                payload: day.payload
            )
        }
    }

    private static func loadWritingDays(from directories: [URL]) -> [WritingDayRecord] {
        deduplicating(directories.flatMap { loadWritingDays(from: $0) }, by: \.filename)
    }

    private static func loadWritingDays(from directory: URL) -> [WritingDayRecord] {
        safeMarkdownFiles(in: directory).compactMap { url in
            guard CaptureMarkdown.captureKind(of: url) == .writingDay,
                  let (payload, _) = loadWritingDay(at: url) else { return nil }
            return WritingDayRecord(
                filename: url.deletingPathExtension().lastPathComponent,
                datetime: payload.entries.last?.createdAt ?? "\(payload.date)T00:00:00+0000",
                payload: payload
            )
        }
    }

    private static func loadWritingDay(at url: URL) -> (payload: CLIAgentWritingDay, content: String)? {
        guard let content = CaptureMarkdown.readBoundedContents(of: url),
              let parsed = CaptureMarkdownParser.parseWritingDay(from: content, markdownURL: url) else { return nil }

        let payload = CLIAgentWritingDay(
            version: "1.0",
            captureType: parsed.captureType,
            date: parsed.date,
            markdownFilename: parsed.markdownFilename,
            entryCount: parsed.entryCount,
            wordCount: parsed.wordCount,
            acceptedWordCount: parsed.acceptedWordCount,
            entries: parsed.entries.map { entry in
                CLIClientWritingEntry(
                    id: entry.id,
                    createdAt: entry.createdAt,
                    title: entry.title,
                    text: entry.text,
                    sourceAppName: entry.sourceAppName,
                    sourceAppBundleId: entry.sourceAppBundleId,
                    wordCount: entry.wordCount,
                    characterCount: entry.characterCount,
                    acceptedWordCount: entry.acceptedWordCount
                )
            }
        )
        return (payload, content)
    }

    /// Writing entries as context items, filtered by day and by `include`.
    private static func writingItems(
        in directories: CLIContextDirectories,
        dateFrom: String?,
        dateTo: String?,
        include: (CLIClientWritingEntry) -> Bool
    ) -> [CLIContextItem] {
        loadWritingDays(from: directories.writingDirs).flatMap { day -> [CLIContextItem] in
            guard matches(date: day.payload.date, dateFrom: dateFrom, dateTo: dateTo) else { return [] }
            return day.payload.entries.filter(include).map { entry in
                CLIContextItem(
                    kind: .writing,
                    title: entry.title,
                    filename: day.filename,
                    entryId: entry.id,
                    date: day.payload.date,
                    datetime: entry.createdAt,
                    preview: String(entry.text.prefix(220)),
                    wordCount: entry.wordCount,
                    speakers: nil,
                    sourceAppName: entry.sourceAppName,
                    delivery: nil
                )
            }
        }
    }

    private static func deduplicating<Record>(
        _ records: [Record],
        by keyPath: KeyPath<Record, String>
    ) -> [Record] {
        var seen: Set<String> = []
        var deduplicated: [Record] = []

        for record in records {
            let key = record[keyPath: keyPath]
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            deduplicated.append(record)
        }

        return deduplicated
    }

    private static func safeMarkdownFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files.compactMap { url in
            guard url.pathExtension == "md" else { return nil }
            switch CLIPathSecurity.validateExistingFile(url, under: directory) {
            case .valid(let safeURL):
                return CaptureMarkdown.looksLikeCaptureMarkdown(safeURL) ? safeURL : nil
            case .missing, .invalid: return nil
            }
        }
    }

    static func meetingTranscript(fromMarkdown content: String) -> CLIAgentTranscript? {
        guard let parsed = CaptureMarkdownParser.parseMeeting(from: content) else { return nil }

        return CLIAgentTranscript(
            version: "2.0",
            recording: CLIAgentRecording(
                date: parsed.datetime,
                durationSeconds: parsed.durationSeconds
            ),
            speakers: parsed.speakers.map { speaker in
                CLIActorSpeaker(
                    id: speaker.id,
                    name: speaker.name,
                    persistentSpeakerId: speaker.persistentSpeakerId,
                    wordCount: speaker.wordCount
                )
            },
            utterances: parsed.utterances.map { utterance in
                CLIUtterance(
                    start: utterance.start,
                    end: utterance.end,
                    speakerId: utterance.speakerId,
                    text: utterance.text
                )
            }
        )
    }

    private static func loadDictationDay(at url: URL) -> (payload: CLIAgentDictationDay, entries: [CLIClientDictationEntry])? {
        guard let content = CaptureMarkdown.readBoundedContents(of: url),
              let parsed = CaptureMarkdownParser.parseDictationDay(from: content, markdownURL: url) else { return nil }

        let entries = parsed.entries.map { entry in
            CLIClientDictationEntry(
                id: entry.id,
                createdAt: entry.createdAt,
                title: entry.title,
                text: entry.text,
                sourceAppName: entry.sourceAppName,
                sourceAppBundleId: entry.sourceAppBundleId,
                delivery: entry.delivery,
                wordCount: entry.wordCount,
                characterCount: entry.characterCount
            )
        }
        let payload = CLIAgentDictationDay(
            version: "2.0",
            captureType: parsed.captureType,
            date: parsed.date,
            markdownFilename: parsed.markdownFilename,
            entryCount: parsed.entryCount,
            wordCount: parsed.wordCount,
            entries: entries
        )

        return (payload, entries)
    }

    private static func recentMeetingPreview(for meeting: MeetingRecord, preferredSpeaker: String? = nil) -> String {
        if let preferredSpeaker,
           let matchingSpeakerUtterance = meeting.utterances.first(where: { utterance in
               speakerMatches(filter: preferredSpeaker, speakerName: utterance.speakerId)
                   && !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            return String(matchingSpeakerUtterance.text.prefix(220))
        }

        if let firstUtterance = meeting.utterances.first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return String(firstUtterance.text.prefix(220))
        }
        let speakers = meeting.speakers.joined(separator: ", ")
        return speakers.isEmpty ? "No transcript captured." : speakers
    }

    private static func matches(date: String, dateFrom: String?, dateTo: String?) -> Bool {
        if let dateFrom, date < dateFrom { return false }
        if let dateTo, date > dateTo { return false }
        return true
    }

    private static func speakerMatches(filter: String, speakerName: String) -> Bool {
        speakerName.localizedCaseInsensitiveContains(filter)
    }

    private static func uniqueSpeakerNames(from names: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for name in names {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(name)
        }

        return ordered
    }
}
