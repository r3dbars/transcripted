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

    @Option(name: .shortAndLong, help: "Number of items to return.")
    var count: Int = 10

    @Flag(name: .long, help: "Output JSON instead of text.")
    var json: Bool = false

    func run() throws {
        let items = CLIContextStore.recent(
            in: paths.resolved,
            kind: kind,
            count: max(1, min(count, 50)),
            dateFrom: dateFrom,
            dateTo: dateTo
        )
        try printContextItems(items, asJSON: json)
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

    @Option(name: .shortAndLong, help: "Number of results to return.")
    var count: Int = 10

    @Flag(name: .long, help: "Output JSON instead of text.")
    var json: Bool = false

    func run() throws {
        let items = CLIContextStore.search(
            query: query,
            speaker: speaker,
            in: paths.resolved,
            kind: kind,
            count: max(1, min(count, 50)),
            dateFrom: dateFrom,
            dateTo: dateTo
        )
        try printContextItems(items, asJSON: json)
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

    @Option(name: .shortAndLong, help: "Number of days to return.")
    var count: Int = 10

    @Flag(name: .long, help: "Output JSON instead of text.")
    var json: Bool = false

    func run() throws {
        let days = CLIContextStore.listDictationDays(
            in: paths.resolved,
            count: max(1, min(count, 50)),
            dateFrom: dateFrom,
            dateTo: dateTo
        )

        if json {
            let data = try JSONEncoder.contextPretty.encode(days)
            print(String(data: data, encoding: .utf8) ?? "[]")
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

struct ReadDictation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read-dictation",
        abstract: "Read a dictation day file or one specific dictation entry."
    )

    @Argument(help: "Dictation day filename, with or without .json.")
    var filename: String

    @OptionGroup var paths: CLIContextPathOptions

    @Option(name: .long, help: "Optional entry ID to read a single dictation.")
    var entryId: String?

    func run() throws {
        print(try CLIContextStore.readDictation(filename: filename, entryId: entryId, in: paths.resolved))
    }
}

private func printContextItems(_ items: [CLIContextItem], asJSON: Bool) throws {
    if asJSON {
        let data = try JSONEncoder.contextPretty.encode(items)
        print(String(data: data, encoding: .utf8) ?? "[]")
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
