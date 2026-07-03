import ArgumentParser
import Foundation

struct ContextRecent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context-recent",
        abstract: "List recent meetings and dictations from saved local context."
    )

    @OptionGroup var paths: CLIContextPathOptions

    @Option(name: .long, help: "Which context to return: all, meeting, or dictation.")
    var kind: CLIContextKind = .all

    @Option(name: .long, help: "Start date filter (YYYY-MM-DD).")
    var dateFrom: String?

    @Option(name: .long, help: "End date filter (YYYY-MM-DD).")
    var dateTo: String?

    @Option(name: .shortAndLong, help: "Number of items to return (valid range 1-50; values outside are clamped).")
    var count: Int = 10

    @Flag(name: .long, help: "Output JSON instead of text.")
    var json: Bool = false

    func run() throws {
        let directories = paths.resolved
        let items = CLIContextStore.recent(
            in: directories,
            kind: kind,
            count: max(1, min(count, 50)),
            dateFrom: dateFrom,
            dateTo: dateTo
        )
        try printContextItems(
            items,
            asJSON: json,
            searchedDirectories: searchedDirectoryPaths(in: directories, kind: kind)
        )
    }
}

struct ContextSearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context-search",
        abstract: "Search across saved meetings and dictations."
    )

    @Argument(help: "Search query.")
    var query: String

    @OptionGroup var paths: CLIContextPathOptions

    @Option(name: .long, help: "Which context to search: all, meeting, or dictation.")
    var kind: CLIContextKind = .all

    @Option(name: .long, help: "Optional speaker filter for meetings.")
    var speaker: String?

    @Option(name: .long, help: "Start date filter (YYYY-MM-DD).")
    var dateFrom: String?

    @Option(name: .long, help: "End date filter (YYYY-MM-DD).")
    var dateTo: String?

    @Option(name: .shortAndLong, help: "Number of results to return (valid range 1-50; values outside are clamped).")
    var count: Int = 10

    @Flag(name: .long, help: "Output JSON instead of text.")
    var json: Bool = false

    func run() throws {
        let directories = paths.resolved
        var notes: [String] = []
        if speaker != nil, kind != .meeting {
            notes.append("Note: --speaker only matches meetings; dictations skipped.")
        }
        let items = CLIContextStore.search(
            query: query,
            speaker: speaker,
            in: directories,
            kind: kind,
            count: max(1, min(count, 50)),
            dateFrom: dateFrom,
            dateTo: dateTo
        )
        try printContextItems(
            items,
            asJSON: json,
            searchedDirectories: searchedDirectoryPaths(in: directories, kind: kind),
            notes: notes
        )
    }
}

struct ListDictations: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-dictations",
        abstract: "List saved dictation day files."
    )

    @OptionGroup var paths: CLIContextPathOptions

    @Option(name: .long, help: "Start date filter (YYYY-MM-DD).")
    var dateFrom: String?

    @Option(name: .long, help: "End date filter (YYYY-MM-DD).")
    var dateTo: String?

    @Option(name: .shortAndLong, help: "Number of days to return (valid range 1-50; values outside are clamped).")
    var count: Int = 10

    @Flag(name: .long, help: "Output JSON instead of text.")
    var json: Bool = false

    func run() throws {
        let directories = paths.resolved
        let days = CLIContextStore.listDictationDays(
            in: directories,
            count: max(1, min(count, 50)),
            dateFrom: dateFrom,
            dateTo: dateTo
        )
        let searchedDirectories = searchedDirectoryPaths(in: directories, kind: .dictation)

        if json {
            if days.isEmpty {
                try printEmptyResultsJSON(searchedDirectories: searchedDirectories, notes: [])
                return
            }
            let data = try JSONEncoder.contextPretty.encode(days)
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        if days.isEmpty {
            printEmptyResultsToStandardError(searchedDirectories: searchedDirectories)
            return
        }

        for day in days {
            let titles = day.titles.prefix(3).joined(separator: " | ")
            print("[\(day.date)] \(day.filename)  \(day.entryCount) entries  \(day.sourceApps.joined(separator: ", "))")
            if !titles.isEmpty {
                print("  \(titles)")
            }
        }
    }
}

struct ReadMeeting: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read-meeting",
        abstract: "Read a saved meeting transcript."
    )

    @Argument(help: "Meeting filename, with or without .md.")
    var filename: String

    @OptionGroup var paths: CLIContextPathOptions

    @Flag(name: .long, help: "Output JSON instead of raw Markdown.")
    var json: Bool = false

    func run() throws {
        let markdown = try CLIContextStore.readMeeting(filename: filename, in: paths.resolved)
        let transcript = json ? CLIContextStore.meetingTranscript(fromMarkdown: markdown) : nil
        let document = CLIReadMarkdownDocument(
            kind: .meeting,
            filename: normalizedMarkdownFilename(filename),
            entryId: nil,
            markdown: markdown,
            recording: transcript?.recording,
            speakers: transcript?.speakers,
            utterances: transcript?.utterances
        )
        try printReadDocument(document, asJSON: json)
    }
}

struct ReadDictation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read-dictation",
        abstract: "Read a dictation day file or one specific dictation entry."
    )

    @Argument(help: "Dictation day filename, with or without .md.")
    var filename: String

    @OptionGroup var paths: CLIContextPathOptions

    @Option(name: .long, help: "Optional entry ID to read a single dictation.")
    var entryId: String?

    @Flag(name: .long, help: "Output JSON instead of raw Markdown.")
    var json: Bool = false

    func run() throws {
        let read = try CLIContextStore.readDictationDocument(filename: filename, entryId: entryId, in: paths.resolved)
        let document = CLIReadMarkdownDocument(
            kind: .dictation,
            filename: normalizedMarkdownFilename(filename),
            entryId: entryId,
            markdown: read.markdown,
            date: read.date,
            entries: read.entries
        )
        try printReadDocument(document, asJSON: json)
    }
}

private let emptyResultsHint = "No captures matched. Check the searched directories or pass --data-dir, --meetings-dir, or --dictations-dir."

private func printContextItems(
    _ items: [CLIContextItem],
    asJSON: Bool,
    searchedDirectories: [String],
    notes: [String] = []
) throws {
    if asJSON {
        if items.isEmpty {
            try printEmptyResultsJSON(searchedDirectories: searchedDirectories, notes: notes)
            return
        }
        if !notes.isEmpty {
            let document = CLIContextResultsDocument(
                results: items,
                searchedDirectories: nil,
                hint: nil,
                notes: notes
            )
            let data = try JSONEncoder.contextPretty.encode(document)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        let data = try JSONEncoder.contextPretty.encode(items)
        print(String(data: data, encoding: .utf8) ?? "[]")
        return
    }

    for note in notes {
        printToStandardError(note)
    }

    if items.isEmpty {
        printEmptyResultsToStandardError(searchedDirectories: searchedDirectories)
        return
    }

    for item in items {
        let scope = item.kind.rawValue.uppercased()
        print("[\(scope)] \(item.date) \(item.title)")
        print("  file: \(item.filename)\(item.entryId.map { " (\($0))" } ?? "")")
        if let sourceAppName = item.sourceAppName {
            print("  source: \(sourceAppName)\(item.delivery.map { " • \($0)" } ?? "")")
        } else if let speakers = item.speakers, !speakers.isEmpty {
            print("  speakers: \(speakers.joined(separator: ", "))")
        }
        print("  \(item.preview)")
    }
}

private func printReadDocument(_ document: CLIReadMarkdownDocument, asJSON: Bool) throws {
    guard asJSON else {
        print(document.markdown)
        return
    }

    let data = try JSONEncoder.contextPretty.encode(document)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

private func printEmptyResultsJSON(searchedDirectories: [String], notes: [String]) throws {
    let document = CLIContextResultsDocument(
        results: [],
        searchedDirectories: searchedDirectories,
        hint: emptyResultsHint,
        notes: notes.isEmpty ? nil : notes
    )
    let data = try JSONEncoder.contextPretty.encode(document)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

private func printEmptyResultsToStandardError(searchedDirectories: [String]) {
    printToStandardError("No results. Searched: \(searchedDirectories.joined(separator: ", "))")
}

private func printToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func searchedDirectoryPaths(in directories: CLIContextDirectories, kind: CLIContextKind) -> [String] {
    var urls: [URL] = []
    if kind != .dictation {
        urls.append(contentsOf: directories.meetingDirs)
    }
    if kind != .meeting {
        urls.append(contentsOf: directories.dictationDirs)
    }

    var seen: Set<String> = []
    return urls.compactMap { url in
        seen.insert(url.path).inserted ? url.path : nil
    }
}

private func normalizedMarkdownFilename(_ filename: String) -> String {
    if filename.hasSuffix(".md") {
        return String(filename.dropLast(3))
    }
    return filename
}
