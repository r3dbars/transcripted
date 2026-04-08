import ArgumentParser
import Foundation

struct CLIContextDirectories {
    let meetingsDir: URL
    let dictationsDir: URL

    static func resolve(dataDir: String?, meetingsDir: String?, dictationsDir: String?) -> CLIContextDirectories {
        if let dataDir, !dataDir.isEmpty {
            let shared = URL(fileURLWithPath: dataDir)
            return CLIContextDirectories(meetingsDir: shared, dictationsDir: shared)
        }

        let env = ProcessInfo.processInfo.environment
        if let shared = env["TRANSCRIPTED_DATA_DIR"], !shared.isEmpty {
            let sharedURL = URL(fileURLWithPath: shared)
            return CLIContextDirectories(meetingsDir: sharedURL, dictationsDir: sharedURL)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let draftRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
        let defaultMeetings = draftRoot
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let defaultDictations = draftRoot
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let legacyShared = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)

        let meetingsURL = meetingsDir.map(URL.init(fileURLWithPath:))
            ?? env["TRANSCRIPTED_MEETINGS_DIR"].map(URL.init(fileURLWithPath:))
        let dictationsURL = dictationsDir.map(URL.init(fileURLWithPath:))
            ?? env["TRANSCRIPTED_DICTATIONS_DIR"].map(URL.init(fileURLWithPath:))

        let useLegacy = meetingsURL == nil
            && dictationsURL == nil
            && !FileManager.default.fileExists(atPath: defaultMeetings.path)
            && FileManager.default.fileExists(atPath: legacyShared.path)

        return CLIContextDirectories(
            meetingsDir: meetingsURL ?? (useLegacy ? legacyShared : defaultMeetings),
            dictationsDir: dictationsURL ?? (useLegacy ? legacyShared : defaultDictations)
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
                    preview: meeting.speakers.joined(separator: ", "),
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
        let sidecarURL = directories.dictationsDir.appendingPathComponent(filename.hasSuffix(".json") ? filename : filename + ".json")
        guard let day = loadDictationDay(at: sidecarURL) else {
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

        let markdownURL = directories.dictationsDir.appendingPathComponent(day.payload.markdownFilename)
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
            guard url.pathExtension == "json", url.deletingPathExtension().lastPathComponent.hasPrefix("Call_") else { return nil }
            guard
                let data = try? Data(contentsOf: url),
                let transcript = try? JSONDecoder().decode(CLIAgentTranscript.self, from: data)
            else { return nil }

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
            guard url.pathExtension == "json", url.deletingPathExtension().lastPathComponent.hasPrefix("Dictations_") else { return nil }
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
        guard
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(CLIAgentDictationDay.self, from: data)
        else { return nil }

        let entries = payload.entries.sorted { $0.createdAt < $1.createdAt }
        return (payload, entries)
    }

    private static func readMeetingTitle(filename: String, from directory: URL) -> String {
        let mdURL = directory.appendingPathComponent(filename + ".md")
        guard let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
            return filename
        }
        return extractTitle(from: content) ?? filename
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
}
