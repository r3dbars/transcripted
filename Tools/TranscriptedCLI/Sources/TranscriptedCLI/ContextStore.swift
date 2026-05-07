import ArgumentParser
import Foundation
import TranscriptedCaptureParsing

private typealias CaptureParser = TranscriptedCaptureMarkdownParser

struct CLIContextDirectories {
    let meetingDirs: [URL]
    let dictationDirs: [URL]

    var meetingsDir: URL {
        meetingDirs[0]
    }

    var dictationsDir: URL {
        dictationDirs[0]
    }

    init(meetingsDir: URL, dictationsDir: URL) {
        self.meetingDirs = [meetingsDir]
        self.dictationDirs = [dictationsDir]
    }

    init(meetingDirs: [URL], dictationDirs: [URL]) {
        self.meetingDirs = meetingDirs
        self.dictationDirs = dictationDirs
    }

    static func resolve(
        dataDir: String?,
        meetingsDir: String?,
        dictationsDir: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> CLIContextDirectories {
        if let dataDir, !dataDir.isEmpty {
            let shared = URL(fileURLWithPath: dataDir)
            if fileManager.fileExists(atPath: shared.appendingPathComponent("meetings", isDirectory: true).path)
                || fileManager.fileExists(atPath: shared.appendingPathComponent("dictations", isDirectory: true).path) {
                return CLIContextDirectories(
                    meetingsDir: shared.appendingPathComponent("meetings", isDirectory: true),
                    dictationsDir: shared.appendingPathComponent("dictations", isDirectory: true)
                )
            }
            return CLIContextDirectories(meetingsDir: shared, dictationsDir: shared)
        }

        if let shared = environment["TRANSCRIPTED_DATA_DIR"], !shared.isEmpty {
            let sharedURL = URL(fileURLWithPath: shared)
            if fileManager.fileExists(atPath: sharedURL.appendingPathComponent("meetings", isDirectory: true).path)
                || fileManager.fileExists(atPath: sharedURL.appendingPathComponent("dictations", isDirectory: true).path) {
                return CLIContextDirectories(
                    meetingsDir: sharedURL.appendingPathComponent("meetings", isDirectory: true),
                    dictationsDir: sharedURL.appendingPathComponent("dictations", isDirectory: true)
                )
            }
            return CLIContextDirectories(meetingsDir: sharedURL, dictationsDir: sharedURL)
        }

        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let transcriptedRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        let defaultCaptures = transcriptedRoot.appendingPathComponent("captures", isDirectory: true)
        let defaultMeetings = defaultCaptures.appendingPathComponent("meetings", isDirectory: true)
        let defaultDictations = defaultCaptures.appendingPathComponent("dictations", isDirectory: true)

        let draftRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
        let legacyDraftMeetings = draftRoot
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let legacyDraftDictations = draftRoot
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let legacyShared = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)

        let meetingsURL = meetingsDir.map(URL.init(fileURLWithPath:))
            ?? environment["TRANSCRIPTED_MEETINGS_DIR"].map(URL.init(fileURLWithPath:))
        let dictationsURL = dictationsDir.map(URL.init(fileURLWithPath:))
            ?? environment["TRANSCRIPTED_DICTATIONS_DIR"].map(URL.init(fileURLWithPath:))
        let meetingDirs = meetingsURL.map { [$0] }
            ?? captureDirectories(
                primary: defaultMeetings,
                legacyCandidates: [legacyDraftMeetings, legacyShared],
                fileManager: fileManager
            )
        let dictationDirs = dictationsURL.map { [$0] }
            ?? captureDirectories(
                primary: defaultDictations,
                legacyCandidates: [legacyDraftDictations, legacyShared],
                fileManager: fileManager
            )

        return CLIContextDirectories(
            meetingDirs: meetingDirs,
            dictationDirs: dictationDirs
        )
    }

    private static func captureDirectories(primary: URL, legacyCandidates: [URL], fileManager: FileManager) -> [URL] {
        var directories = [primary]
        var seen = Set([primary.standardizedFileURL.path])

        for candidate in legacyCandidates where directoryHasCaptureMarkdownFiles(candidate, fileManager: fileManager) {
            let path = candidate.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(candidate)
        }

        return directories
    }

    private static func directoryHasCaptureMarkdownFiles(_ directory: URL, fileManager: FileManager) -> Bool {
        CaptureParser.directoryHasCaptureMarkdownFiles(directory, fileManager: fileManager)
    }
}

struct CLIContextPathOptions: ParsableArguments {
    @Option(name: .long, help: "Shared context directory containing both meetings and dictations.")
    var dataDir: String?

    @Option(name: .long, help: "Meetings transcript directory.")
    var meetingsDir: String?

    @Option(name: .long, help: "Dictations transcript directory.")
    var dictationsDir: String?

    var resolved: CLIContextDirectories {
        CLIContextDirectories.resolve(dataDir: dataDir, meetingsDir: meetingsDir, dictationsDir: dictationsDir)
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

    static func recent(in directories: CLIContextDirectories, kind: CLIContextKind, count: Int, dateFrom: String?, dateTo: String?) -> [CLIContextItem] {
        var items: [CLIContextItem] = []

        if kind != .dictation {
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

        if kind != .meeting {
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

        return Array(items.sorted { $0.datetime > $1.datetime }.prefix(count))
    }

    static func search(query: String, speaker: String?, in directories: CLIContextDirectories, kind: CLIContextKind, count: Int, dateFrom: String?, dateTo: String?) -> [CLIContextItem] {
        let normalizedQuery = query.lowercased()
        var items: [CLIContextItem] = []

        if kind != .dictation {
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

        if kind != .meeting, speaker == nil {
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

        guard let markdownURL,
              let content = try? String(contentsOf: markdownURL, encoding: .utf8),
              CaptureParser.looksLikeCaptureMarkdown(markdownURL),
              !markdownURL.deletingPathExtension().lastPathComponent.hasPrefix("Dictations_") else {
            throw ValidationError("Meeting not found: \(filename)")
        }

        return content
    }

    static func readDictation(filename: String, entryId: String?, in directories: CLIContextDirectories) throws -> String {
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

            return """
            # \(entry.title)

            Captured: \(entry.createdAt)
            Source app: \(entry.sourceAppName)
            Delivery: \(entry.delivery)
            Words: \(entry.wordCount)

            \(entry.text)
            """
        }

        if let content = try? String(contentsOf: markdownURL, encoding: .utf8) {
            return content
        }

        let data = try JSONEncoder.contextPretty.encode(day.payload)
        return String(data: data, encoding: .utf8) ?? "{}"
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

    private static func loadMeetings(from directories: [URL]) -> [MeetingRecord] {
        deduplicating(directories.flatMap { loadMeetings(from: $0) }, by: \.filename)
    }

    private static func loadMeetings(from directory: URL) -> [MeetingRecord] {
        let files = safeMarkdownFiles(in: directory)
        return files.compactMap { url in
            let filename = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "md",
                  !filename.hasPrefix("Dictations_"),
                  let transcript = loadMeeting(at: url) else { return nil }

            let title = readMeetingTitle(filename: filename, from: directory)
            let speakerLookup = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.name) })
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
                return CaptureParser.looksLikeCaptureMarkdown(safeURL) ? safeURL : nil
            case .missing, .invalid: return nil
            }
        }
    }

    private static func loadDictationDay(at url: URL) -> (payload: CLIAgentDictationDay, entries: [CLIClientDictationEntry])? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let frontmatter = CaptureParser.parseFrontmatter(from: content) else { return nil }

        let entries = CaptureParser.parseDictationEntries(from: frontmatter.body)
            .map(CLIClientDictationEntry.init(parsed:))
        let payload = CLIAgentDictationDay(
            version: "2.0",
            captureType: frontmatter.values["capture_type"] ?? "dictation_day",
            date: frontmatter.values["date"] ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Dictations_", with: ""),
            markdownFilename: url.lastPathComponent,
            entryCount: entries.count,
            wordCount: entries.reduce(0) { $0 + $1.wordCount },
            entries: entries.sorted { $0.createdAt < $1.createdAt }
        )

        return (payload, payload.entries)
    }

    private static func readMeetingTitle(filename: String, from directory: URL) -> String {
        let mdURL = directory.appendingPathComponent(filename + ".md")
        guard let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
            return filename
        }
        return extractTitle(from: content) ?? filename
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

    private static func extractTitle(from content: String) -> String? {
        guard content.count >= 8, content.hasPrefix("---"),
              let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) else { return nil }
        let yaml = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("title:") {
                let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                return title.isEmpty ? nil : title
            }
        }
        return nil
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

    private static func loadMeeting(at url: URL) -> CLIAgentTranscript? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let frontmatter = CaptureParser.parseFrontmatter(from: content) else { return nil }

        let entries = CaptureParser.parseTranscriptEntries(from: frontmatter.body)
        let speakerMetadata = CaptureParser.parseSpeakerMetadata(from: content)
        let speakerMetadataByName = CaptureParser.uniqueSpeakerMetadataByNormalizedName(speakerMetadata)

        var generatedIDsByLabel: [String: String] = [:]
        var nextMicId = 0
        var nextSystemId = 0
        var utterances: [CLIUtterance] = []

        for index in entries.indices {
            let entry = entries[index]
            let normalizedLabel = CaptureParser.normalizeSpeakerLabel(entry.label)
            let speakerId: String

            if entry.source == "Mic" {
                if let existing = generatedIDsByLabel["mic:\(normalizedLabel)"] {
                    speakerId = existing
                } else {
                    speakerId = "mic_\(nextMicId)"
                    generatedIDsByLabel["mic:\(normalizedLabel)"] = speakerId
                    nextMicId += 1
                }
            } else if let metadata = speakerMetadataByName[normalizedLabel] {
                speakerId = "system_\(metadata.rawId)"
            } else if let existing = generatedIDsByLabel["system:\(normalizedLabel)"] {
                speakerId = existing
            } else {
                speakerId = "system_\(nextSystemId)"
                generatedIDsByLabel["system:\(normalizedLabel)"] = speakerId
                nextSystemId += 1
            }

            let nextEntry = index + 1 < entries.count ? entries[index + 1] : nil
            utterances.append(CLIUtterance(
                start: entry.startSeconds,
                end: CaptureParser.estimatedEndSeconds(for: entry, next: nextEntry),
                speakerId: speakerId,
                text: entry.text
            ))
        }

        let grouped = Dictionary(grouping: zip(entries, utterances), by: { $0.1.speakerId })
        let speakers = grouped.keys.sorted().map { speakerId in
            let groupedUtterances = grouped[speakerId] ?? []
            let displayName = groupedUtterances.first?.0.label ?? speakerId
            let metadata = speakerMetadata.first(where: {
                "system_\($0.rawId)" == speakerId
                    || CaptureParser.normalizeSpeakerLabel($0.name) == CaptureParser.normalizeSpeakerLabel(displayName)
            })
            let wordCount = groupedUtterances.reduce(0) { $0 + $1.0.text.split(whereSeparator: \.isWhitespace).count }
            return CLIActorSpeaker(
                id: speakerId,
                name: displayName,
                persistentSpeakerId: metadata?.persistentSpeakerId,
                wordCount: wordCount
            )
        }

        let date = frontmatter.values["date"] ?? "1970-01-01"
        let time = frontmatter.values["time"] ?? "00:00:00"
        return CLIAgentTranscript(
            version: "2.0",
            recording: CLIAgentRecording(
                date: "\(date)T\(time)",
                durationSeconds: CaptureParser.parseDurationSeconds(frontmatter.values["duration"])
            ),
            speakers: speakers,
            utterances: utterances
        )
    }
}

private extension CLIClientDictationEntry {
    init(parsed: ParsedCaptureDictationEntry) {
        self.init(
            id: parsed.id,
            createdAt: parsed.createdAt,
            title: parsed.title,
            text: parsed.text,
            sourceAppName: parsed.sourceAppName,
            sourceAppBundleId: parsed.sourceAppBundleId,
            delivery: parsed.delivery,
            wordCount: parsed.wordCount,
            characterCount: parsed.characterCount
        )
    }
}
