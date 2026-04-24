import ArgumentParser
import Foundation

struct CLIContextDirectories {
    let meetingsDir: URL
    let dictationsDir: URL

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
        let currentTranscriptedCapturesExist = fileManager.fileExists(atPath: defaultMeetings.path)
            || fileManager.fileExists(atPath: defaultDictations.path)

        let legacyDraftCapturesExist = fileManager.fileExists(atPath: legacyDraftMeetings.path)
            || fileManager.fileExists(atPath: legacyDraftDictations.path)

        let useLegacyDraft = meetingsURL == nil
            && dictationsURL == nil
            && !currentTranscriptedCapturesExist
            && legacyDraftCapturesExist
        let useLegacyShared = meetingsURL == nil
            && dictationsURL == nil
            && !currentTranscriptedCapturesExist
            && !legacyDraftCapturesExist
            && fileManager.fileExists(atPath: legacyShared.path)

        return CLIContextDirectories(
            meetingsDir: meetingsURL ?? (useLegacyDraft ? legacyDraftMeetings : (useLegacyShared ? legacyShared : defaultMeetings)),
            dictationsDir: dictationsURL ?? (useLegacyDraft ? legacyDraftDictations : (useLegacyShared ? legacyShared : defaultDictations))
        )
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
        let days = loadDictationDays(from: directories.dictationsDir).filter { day in
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
            items.append(contentsOf: loadMeetings(from: directories.meetingsDir).compactMap { meeting in
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
            items.append(contentsOf: loadDictationDays(from: directories.dictationsDir).flatMap { day in
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
            items.append(contentsOf: loadMeetings(from: directories.meetingsDir).compactMap { meeting in
                guard matches(date: meeting.date, dateFrom: dateFrom, dateTo: dateTo) else { return nil }
                if let speaker, !meeting.speakers.contains(where: { $0.localizedCaseInsensitiveContains(speaker) }) {
                    return nil
                }
                let matches = meeting.utterances.filter { utterance in
                    utterance.text.localizedCaseInsensitiveContains(normalizedQuery)
                        && (speaker == nil || speakerMatches(filter: speaker!, speakerName: utterance.speakerId))
                }
                guard let firstMatch = matches.first else { return nil }
                return CLIContextItem(
                    kind: .meeting,
                    title: meeting.title,
                    filename: meeting.filename,
                    entryId: nil,
                    date: meeting.date,
                    datetime: meeting.datetime,
                    preview: String(firstMatch.text.prefix(220)),
                    wordCount: meeting.wordCount,
                    speakers: meeting.speakers,
                    sourceAppName: nil,
                    delivery: nil
                )
            })
        }

        if kind != .meeting, speaker == nil {
            items.append(contentsOf: loadDictationDays(from: directories.dictationsDir).flatMap { day in
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

    static func readDictation(filename: String, entryId: String?, in directories: CLIContextDirectories) throws -> String {
        let markdownURL = directories.dictationsDir.appendingPathComponent(filename.hasSuffix(".md") ? filename : filename + ".md")
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

    private static func loadMeetings(from directory: URL) -> [MeetingRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "md",
                  let transcript = loadMeeting(at: url) else { return nil }

            let filename = url.deletingPathExtension().lastPathComponent
            let title = readMeetingTitle(filename: filename, from: directory)
            let speakerLookup = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.name) })
            return MeetingRecord(
                filename: filename,
                title: title,
                date: String(transcript.recording.date.prefix(10)),
                datetime: transcript.recording.date,
                wordCount: transcript.speakers.reduce(0) { $0 + $1.wordCount },
                speakers: transcript.speakers.map(\.name),
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

    private static func loadDictationDays(from directory: URL) -> [DictationDayRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
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

    private static func loadDictationDay(at url: URL) -> (payload: CLIAgentDictationDay, entries: [CLIClientDictationEntry])? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let frontmatter = parseFrontmatter(from: content) else { return nil }

        let entries = parseDictationEntries(from: frontmatter.body)
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

    private static func recentMeetingPreview(for meeting: MeetingRecord) -> String {
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

    private struct ParsedFrontmatter {
        let values: [String: String]
        let body: String
    }

    private struct ParsedTranscriptEntry {
        let timestamp: String
        let startSeconds: Double
        let source: String
        let label: String
        let text: String
    }

    private struct ParsedFrontmatterSpeaker {
        let rawId: String
        let name: String
        let persistentSpeakerId: String?
    }

    private static func loadMeeting(at url: URL) -> CLIAgentTranscript? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let frontmatter = parseFrontmatter(from: content) else { return nil }

        let entries = parseTranscriptEntries(from: frontmatter.body)
        let speakerMetadata = parseFrontmatterSpeakers(from: content)
        let speakerMetadataByName = Dictionary(uniqueKeysWithValues: speakerMetadata.map {
            (normalizeSpeakerLabel($0.name), $0)
        })

        var generatedIDsByLabel: [String: String] = [:]
        var nextMicId = 0
        var nextSystemId = 0
        var utterances: [CLIUtterance] = []

        for index in entries.indices {
            let entry = entries[index]
            let normalizedLabel = normalizeSpeakerLabel(entry.label)
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
                end: estimatedEndSeconds(for: entry, next: nextEntry),
                speakerId: speakerId,
                text: entry.text
            ))
        }

        let grouped = Dictionary(grouping: zip(entries, utterances), by: { $0.1.speakerId })
        let speakers = grouped.keys.sorted().map { speakerId in
            let groupedUtterances = grouped[speakerId] ?? []
            let displayName = groupedUtterances.first?.0.label ?? speakerId
            let metadata = speakerMetadata.first(where: {
                "system_\($0.rawId)" == speakerId || normalizeSpeakerLabel($0.name) == normalizeSpeakerLabel(displayName)
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
                durationSeconds: parseDurationSeconds(frontmatter.values["duration"])
            ),
            speakers: speakers,
            utterances: utterances
        )
    }

    private static func parseFrontmatter(from content: String) -> ParsedFrontmatter? {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return nil
        }

        let frontmatterText = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        var values: [String: String] = [:]

        for line in frontmatterText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("- "),
                  let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            values[key] = value
        }

        return ParsedFrontmatter(values: values, body: String(content[endRange.upperBound...]))
    }

    private static func parseFrontmatterSpeakers(from content: String) -> [ParsedFrontmatterSpeaker] {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return []
        }

        let frontmatter = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        guard let sectionRange = frontmatter.range(of: "speakers:\n") else { return [] }
        let speakerLines = String(frontmatter[sectionRange.upperBound...]).components(separatedBy: "\n")

        var speakers: [ParsedFrontmatterSpeaker] = []
        var currentId: String?
        var currentName: String?
        var currentPersistentSpeakerId: String?

        func flush() {
            if let currentId, let currentName {
                speakers.append(ParsedFrontmatterSpeaker(
                    rawId: currentId,
                    name: currentName,
                    persistentSpeakerId: currentPersistentSpeakerId
                ))
            }
            currentId = nil
            currentName = nil
            currentPersistentSpeakerId = nil
        }

        for rawLine in speakerLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- id:") {
                flush()
                currentId = trimmed
                    .replacingOccurrences(of: "- id:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("name:") {
                currentName = trimmed
                    .replacingOccurrences(of: "name:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("db_id:") {
                currentPersistentSpeakerId = trimmed
                    .replacingOccurrences(of: "db_id:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if !trimmed.hasPrefix("-"), !trimmed.hasPrefix("name:"), !trimmed.hasPrefix("db_id:"), !trimmed.hasPrefix("confidence:"), !trimmed.hasPrefix("source:"), !trimmed.isEmpty {
                break
            }
        }
        flush()

        return speakers
    }

    private static func parseTranscriptEntries(from body: String) -> [ParsedTranscriptEntry] {
        if let range = body.range(of: "## Transcript\n\n") {
            let transcriptBody = String(body[range.upperBound...])
            let chunks = transcriptBody
                .components(separatedBy: "\n\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let entries = chunks.compactMap(parseStyledTranscriptEntry)
            if !entries.isEmpty { return entries }
        }

        if let range = body.range(of: "## Full Transcript\n\n") {
            let transcriptBody = String(body[range.upperBound...])
            return transcriptBody.components(separatedBy: "\n").compactMap(parseLegacyTranscriptLine)
        }

        return body.components(separatedBy: "\n").compactMap(parseLegacyTranscriptLine)
    }

    private static func parseLegacyTranscriptLine(_ line: String) -> ParsedTranscriptEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let timestampEnd = trimmed.firstIndex(of: "]") else { return nil }
        let timestamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<timestampEnd])
        let sourceStart = trimmed.index(timestampEnd, offsetBy: 3)
        guard let labelEnd = trimmed.range(of: "] ", range: sourceStart..<trimmed.endIndex) else { return nil }
        let sourceLabel = trimmed[sourceStart..<labelEnd.lowerBound]
        guard let separator = sourceLabel.firstIndex(of: "/") else { return nil }

        let source = String(sourceLabel[..<separator])
        let label = unwrapSpeakerLabel(String(sourceLabel[sourceLabel.index(after: separator)...]))
        return ParsedTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: String(trimmed[labelEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseStyledTranscriptEntry(_ chunk: String) -> ParsedTranscriptEntry? {
        let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let header = lines.first else { return nil }
        let normalizedHeader = header.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^([0-9:]+)\s+\[(.+?)\]$"#) else { return nil }
        let nsHeader = normalizedHeader as NSString
        let range = NSRange(location: 0, length: nsHeader.length)
        guard let match = regex.firstMatch(in: normalizedHeader, range: range),
              match.numberOfRanges >= 3 else { return nil }
        let timestamp = nsHeader.substring(with: match.range(at: 1))
        let sourceLabel = nsHeader.substring(with: match.range(at: 2))
        guard let separator = sourceLabel.firstIndex(of: "/") else { return nil }

        let source = String(sourceLabel[..<separator])
        let label = unwrapSpeakerLabel(String(sourceLabel[sourceLabel.index(after: separator)...]))
        return ParsedTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseDictationEntries(from body: String) -> [CLIClientDictationEntry] {
        let lines = body.components(separatedBy: "\n")
        var sections: [String] = []
        var currentSection: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if !currentSection.isEmpty {
                    sections.append(currentSection.joined(separator: "\n"))
                }
                currentSection = [line]
            } else if !currentSection.isEmpty {
                currentSection.append(line)
            }
        }

        if !currentSection.isEmpty {
            sections.append(currentSection.joined(separator: "\n"))
        }

        return sections.compactMap { section in
            let lines = section.components(separatedBy: "\n")
            guard let heading = lines.first, heading.hasPrefix("## ") else { return nil }
            let title = heading.replacingOccurrences(of: "## ", with: "")
                .components(separatedBy: " - ")
                .dropFirst()
                .joined(separator: " - ")

            var entryId = ""
            var createdAt = ""
            var sourceAppName = "Unknown"
            var sourceAppBundleId: String?
            var delivery = "failed"
            var wordCount = 0
            var characterCount = 0
            var bodyLines: [String] = []
            var inBody = false
            var sawMetadata = false

            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if !inBody, sawMetadata {
                        inBody = true
                    } else if inBody {
                        bodyLines.append("")
                    }
                    continue
                }

                if inBody {
                    bodyLines.append(line)
                    continue
                }

                if trimmed.hasPrefix("Entry ID:") {
                    sawMetadata = true
                    entryId = trimmed.replacingOccurrences(of: "Entry ID:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                } else if trimmed.hasPrefix("Captured:") {
                    sawMetadata = true
                    createdAt = trimmed.replacingOccurrences(of: "Captured:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("Source app:") {
                    sawMetadata = true
                    sourceAppName = trimmed.replacingOccurrences(of: "Source app:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("Bundle ID:") {
                    sawMetadata = true
                    sourceAppBundleId = trimmed.replacingOccurrences(of: "Bundle ID:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                } else if trimmed.hasPrefix("Delivery:") {
                    sawMetadata = true
                    delivery = trimmed.replacingOccurrences(of: "Delivery:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("Words:") {
                    sawMetadata = true
                    wordCount = Int(trimmed.replacingOccurrences(of: "Words:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                } else if trimmed.hasPrefix("Characters:") {
                    sawMetadata = true
                    characterCount = Int(trimmed.replacingOccurrences(of: "Characters:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                } else if trimmed.hasPrefix("Timestamp:") {
                    sawMetadata = true
                    createdAt = trimmed.replacingOccurrences(of: "Timestamp:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !sawMetadata {
                    inBody = true
                    bodyLines.append(line)
                }
            }

            let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return CLIClientDictationEntry(
                id: entryId.isEmpty ? "dictation-\(UUID().uuidString)" : entryId,
                createdAt: createdAt.isEmpty ? "1970-01-01T00:00:00Z" : createdAt,
                title: title.isEmpty ? heading.replacingOccurrences(of: "## ", with: "") : title,
                text: text,
                sourceAppName: sourceAppName,
                sourceAppBundleId: sourceAppBundleId,
                delivery: delivery,
                wordCount: wordCount == 0 ? text.split(whereSeparator: \.isWhitespace).count : wordCount,
                characterCount: characterCount == 0 ? text.count : characterCount
            )
        }
    }

    private static func estimatedEndSeconds(for entry: ParsedTranscriptEntry, next: ParsedTranscriptEntry?) -> Double {
        if let next, next.startSeconds > entry.startSeconds {
            return next.startSeconds
        }
        let estimatedDuration = max(1.0, min(20.0, Double(entry.text.split(whereSeparator: \.isWhitespace).count) / 2.5))
        return entry.startSeconds + estimatedDuration
    }

    private static func parseDurationSeconds(_ rawDuration: String?) -> Int {
        let components = (rawDuration ?? "").split(separator: ":").compactMap { Int($0) }
        switch components.count {
        case 2:
            return components[0] * 60 + components[1]
        case 3:
            return components[0] * 3600 + components[1] * 60 + components[2]
        default:
            return 0
        }
    }

    private static func parseTimestampSeconds(_ timestamp: String) -> Double {
        let components = timestamp.split(separator: ":").compactMap { Double($0) }
        switch components.count {
        case 2:
            return components[0] * 60 + components[1]
        case 3:
            return components[0] * 3600 + components[1] * 60 + components[2]
        default:
            return 0
        }
    }

    private static func unwrapSpeakerLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        return trimmed
    }

    private static func normalizeSpeakerLabel(_ label: String) -> String {
        unwrapSpeakerLabel(label).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
