import XCTest
import Darwin
@testable import transcripted_cli

/// Writing day files through the CLI context store and commands: writing
/// shows up wherever dictations do, never as a meeting, and only when a
/// writing folder is resolved. Every fixture lives under a temp directory.
final class WritingContextTests: XCTestCase {
    private var root: URL!
    private var meetingsDir: URL!
    private var dictationsDir: URL!
    private var writingDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        writingDir = root.appendingPathComponent("writing", isDirectory: true)
        for dir in [meetingsDir!, dictationsDir!, writingDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try writingDay.write(to: writingDir.appendingPathComponent("Writing_2026-09-25.md"), atomically: true, encoding: .utf8)
        try dictationDay.write(to: dictationsDir.appendingPathComponent("Dictations_2026-09-24.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var directories: CLIContextDirectories {
        CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir, writingDir: writingDir)
    }

    // MARK: - Store

    func testRecentAllIncludesWritingNextToDictations() {
        let items = CLIContextStore.recent(in: directories, kind: .all, count: 10, dateFrom: nil, dateTo: nil)

        XCTAssertEqual(items.map(\.kind), [.writing, .writing, .dictation], "newest first across kinds")
        XCTAssertEqual(items.first?.entryId, "writing-20260925-160501-002-0b1c2d3e")
        XCTAssertEqual(items.first?.filename, "Writing_2026-09-25")
        XCTAssertEqual(items.first?.sourceAppName, "Notes")
        XCTAssertNil(items.first?.delivery)
    }

    func testRecentKindFiltersIncludeOrExcludeWriting() {
        let writingOnly = CLIContextStore.recent(in: directories, kind: .writing, count: 10, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(Set(writingOnly.map(\.kind)), [.writing])
        XCTAssertEqual(writingOnly.count, 2)

        let dictationOnly = CLIContextStore.recent(in: directories, kind: .dictation, count: 10, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(dictationOnly.map(\.kind), [.dictation])

        let outOfRange = CLIContextStore.recent(in: directories, kind: .writing, count: 10, dateFrom: "2026-09-26", dateTo: nil)
        XCTAssertTrue(outOfRange.isEmpty)
    }

    func testSearchFindsWritingTextAndSpeakerFilterSkipsIt() {
        let hits = CLIContextStore.search(query: "airpods", speaker: nil, in: directories, kind: .all, count: 10, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(hits.map(\.kind), [.writing])
        XCTAssertEqual(hits.first?.entryId, "writing-20260925-104211-387-4f2a9c1e")

        let withSpeaker = CLIContextStore.search(query: "airpods", speaker: "You", in: directories, kind: .all, count: 10, dateFrom: nil, dateTo: nil)
        XCTAssertTrue(withSpeaker.isEmpty)
    }

    func testListWritingDaysSummarizesEachDay() {
        let days = CLIContextStore.listWritingDays(in: directories, count: 10, dateFrom: nil, dateTo: nil)

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.filename, "Writing_2026-09-25")
        XCTAssertEqual(days.first?.entryCount, 2)
        XCTAssertEqual(days.first?.acceptedWordCount, 3)
        XCTAssertEqual(days.first?.sourceApps, ["Notes", "Slack"])
    }

    func testReadWritingReturnsRawMarkdownOrOneEntry() throws {
        let day = try CLIContextStore.readWritingDocument(filename: "Writing_2026-09-25", entryId: nil, in: directories)
        XCTAssertEqual(day.markdown, writingDay)
        XCTAssertEqual(day.entries.count, 2)

        let entry = try CLIContextStore.readWritingDocument(
            filename: "Writing_2026-09-25.md",
            entryId: "writing-20260925-104211-387-4f2a9c1e",
            in: directories
        )
        XCTAssertTrue(entry.markdown.contains("Accepted words: 3"))
        XCTAssertTrue(entry.markdown.hasSuffix("Pushing the launch to Thursday so QA can finish the AirPods pass."))
        XCTAssertEqual(entry.entries.map(\.sourceAppBundleId), ["com.tinyspeck.slackmacgap"])

        XCTAssertThrowsError(try CLIContextStore.readWritingDocument(filename: "../meetings/x", entryId: nil, in: directories))
        XCTAssertThrowsError(try CLIContextStore.readWritingDocument(filename: "Writing_2020-01-01", entryId: nil, in: directories))
    }

    // MARK: - Flat shared folder

    func testFlatSharedDataDirNeverTreatsWritingAsMeeting() throws {
        let flat = root.appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try writingDay.write(to: flat.appendingPathComponent("Writing_2026-09-25.md"), atomically: true, encoding: .utf8)
        try """
        ---
        capture_type: meeting
        date: 2026-09-20
        time: 09:15:00
        ---

        ## Full Transcript

        [00:03] [Mic/You] Planning the launch.
        """.write(to: flat.appendingPathComponent("Call_2026-09-20_09-15-00.md"), atomically: true, encoding: .utf8)

        let resolved = CLIContextDirectories.resolve(dataDir: flat.path, meetingsDir: nil, dictationsDir: nil, environment: [:], homeDirectory: root)

        let meetings = CLIContextStore.recent(in: resolved, kind: .meeting, count: 10, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(meetings.map(\.filename), ["Call_2026-09-20_09-15-00"])
        XCTAssertThrowsError(try CLIContextStore.readMeeting(filename: "Writing_2026-09-25", in: resolved))

        let writing = CLIContextStore.recent(in: resolved, kind: .writing, count: 10, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(writing.count, 2)
        XCTAssertThrowsError(
            try CLIContextStore.readWritingDocument(filename: "Call_2026-09-20_09-15-00", entryId: nil, in: resolved),
            "a meeting sharing the folder is not readable as writing"
        )
    }

    func testPerKindOverridesWithoutWritingDirReadNoWriting() {
        let resolved = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: meetingsDir.path,
            dictationsDir: dictationsDir.path,
            environment: [:],
            homeDirectory: root
        )
        XCTAssertEqual(resolved.writingDirs, [])
        XCTAssertFalse(CLIContextStore.recent(in: resolved, kind: .all, count: 10, dateFrom: nil, dateTo: nil).contains { $0.kind == .writing })

        let withWriting = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: meetingsDir.path,
            dictationsDir: dictationsDir.path,
            writingDir: writingDir.path,
            environment: [:],
            homeDirectory: root
        )
        XCTAssertEqual(withWriting.writingDirs.map(\.standardizedFileURL.path), [writingDir.standardizedFileURL.path])
    }

    // MARK: - Commands

    func testListWritingCommandJSON() throws {
        let command = try ListWriting.parse(pathArguments + ["--json"])
        let output = try captureStandardOutput { try command.run() }
        let days = try JSONDecoder().decode([CLIWritingDaySummary].self, from: Data(output.utf8))
        XCTAssertEqual(days.map(\.filename), ["Writing_2026-09-25"])
    }

    func testListWritingCommandEmptyJSONNamesTheWritingFolder() throws {
        let emptyWriting = root.appendingPathComponent("empty-writing", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyWriting, withIntermediateDirectories: true)
        let command = try ListWriting.parse([
            "--meetings-dir", meetingsDir.path,
            "--dictations-dir", dictationsDir.path,
            "--writing-dir", emptyWriting.path,
            "--json",
        ])
        let output = try captureStandardOutput { try command.run() }
        let document = try JSONDecoder().decode(CLIContextResultsDocument.self, from: Data(output.utf8))
        XCTAssertEqual(document.searchedDirectories, [emptyWriting.path])
        XCTAssertTrue(document.hint?.contains("--writing-dir") == true)
    }

    func testReadWritingCommandJSONSelectsEntry() throws {
        let command = try ReadWriting.parse([
            "Writing_2026-09-25",
            "--entry-id", "writing-20260925-160501-002-0b1c2d3e",
            "--json",
        ] + pathArguments)
        let output = try captureStandardOutput { try command.run() }
        let document = try JSONDecoder().decode(CLIReadWritingDocument.self, from: Data(output.utf8))
        XCTAssertEqual(document.kind, .writing)
        XCTAssertEqual(document.filename, "Writing_2026-09-25")
        XCTAssertEqual(document.date, "2026-09-25")
        XCTAssertEqual(document.entries.map(\.id), ["writing-20260925-160501-002-0b1c2d3e"])
        XCTAssertNil(document.entries.first?.sourceAppBundleId)
        XCTAssertTrue(output.contains("\"accepted_word_count\" : 0"))
    }

    func testContextRecentCommandKindWriting() throws {
        let command = try ContextRecent.parse(["--kind", "writing", "--json"] + pathArguments)
        let output = try captureStandardOutput { try command.run() }
        let items = try JSONDecoder().decode([CLIContextItem].self, from: Data(output.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(output.contains("\"kind\" : \"writing\""))
    }

    func testContextSearchSpeakerNoteMentionsWritingWhenItWasSkipped() throws {
        let command = try ContextSearch.parse(["airpods", "--speaker", "You", "--json"] + pathArguments)
        let output = try captureStandardOutput { try command.run() }
        let document = try JSONDecoder().decode(CLIContextResultsDocument.self, from: Data(output.utf8))
        XCTAssertEqual(document.notes, ["Note: --speaker only matches meetings; dictations and writing skipped."])
    }

    // MARK: - Helpers

    private var pathArguments: [String] {
        ["--meetings-dir", meetingsDir.path, "--dictations-dir", dictationsDir.path, "--writing-dir", writingDir.path]
    }

    private let writingDay = """
    ---
    title: "Writing for September 25, 2026"
    date: 2026-09-25
    capture_type: writing_day
    format_version: 1
    ---

    # Writing for September 25, 2026

    ## 10:42 AM - Pushing the launch to Thursday so QA

    Entry ID: `writing-20260925-104211-387-4f2a9c1e`
    Captured: 2026-09-25T15:42:11.387Z
    Source app: Slack
    Bundle ID: `com.tinyspeck.slackmacgap`
    Words: 14
    Characters: 71
    Accepted words: 3

    Pushing the launch to Thursday so QA can finish the AirPods pass.

    ## 11:05 AM - Draft the pricing note for Friday

    Entry ID: `writing-20260925-160501-002-0b1c2d3e`
    Captured: 2026-09-25T16:05:01.002Z
    Source app: Notes
    Words: 7
    Characters: 40
    Accepted words: 0

    Draft the pricing note for Friday review

    """

    private let dictationDay = """
    ---
    title: "Dictations for 2026-09-24"
    date: 2026-09-24
    capture_type: dictation_day
    ---

    # Dictations for 2026-09-24

    ## 9:15 AM - Morning note

    Entry ID: `dictation-20260924-091500-000`
    Captured: 2026-09-24T14:15:00.000Z
    Source app: Slack
    Delivery: pasted
    Words: 3

    Morning note text
    """

    private func captureStandardOutput(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(originalStdout, 0)

        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try body()
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
    }
}
