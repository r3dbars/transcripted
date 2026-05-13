import XCTest
import Darwin
@testable import transcripted_cli

final class ContextStoreTests: XCTestCase {
    func testRecentMeetingUsesFirstUtteranceAsPreview() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        ---

        # Product review

        ## Full Transcript

        [00:03] [Mic/You] We should test the onboarding changes before touching pricing.

        [00:08] [System/Speaker 2] Agreed.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Product review.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.recent(
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.preview, "We should test the onboarding changes before touching pricing.")
    }

    func testRecentMeetingWithNoTranscriptUsesExplicitPreview() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        date: 2026-04-16
        time: 09:15:00
        duration: "0:02"
        total_word_count: 0
        ---

        # Quick notes

        ## Transcript

        _No transcript captured._
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Quick notes.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.recent(
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.preview, "No transcript captured.")
    }

    func testSearchSpeakerFilterUsesMatchingSpeakerUtterance() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        ---

        # Product review

        ## Full Transcript

        [00:03] [System/Speaker 2] The product plan needs review.
        [00:08] [Mic/You] I agree, and the product plan still needs a test pass.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Product review.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.search(
            query: "product",
            speaker: "You",
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.preview, "I agree, and the product plan still needs a test pass.")
    }

    func testSearchMatchesMeetingTitleWhenTranscriptDoesNotContainQuery() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        title: Strategy sync
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        ---

        # Strategy sync

        ## Full Transcript

        [00:03] [Mic/You] We should test the onboarding changes before touching pricing.
        [00:08] [System/Jenny Wen] Agreed.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Strategy sync.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.search(
            query: "strategy",
            speaker: nil,
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Strategy sync")
    }

    func testSearchMatchesMeetingSpeakerNameWhenTranscriptDoesNotContainQuery() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        title: Hardware chat
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        speakers:
          - id: "0"
            name: Linus
            db_id: "80FB272B-6061-4FC4-8408-3F7A974C59DB"
        ---

        # Hardware chat

        ## Full Transcript

        [00:03] [System/Linus] Yellow.
        [00:08] [System/Linus] Touch screen finally shipped.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Hardware chat.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.search(
            query: "Linus",
            speaker: nil,
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Hardware chat")
    }

    func testSearchSpeakerMetadataMatchUsesFilteredSpeakerPreview() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        title: Hardware chat
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        speakers:
          - id: "0"
            name: Speaker 1
            db_id: "system-1"
          - id: "1"
            name: Linus
            db_id: "linus-1"
        ---

        # Hardware chat

        ## Full Transcript

        [00:03] [System/Speaker 1] Touch screen finally shipped.
        [00:08] [Mic/Linus] Yellow.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Hardware chat.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.search(
            query: "Linus",
            speaker: "Linus",
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.preview, "Yellow.")
    }

    func testRecentIncludesLegacyMeetingDirectories() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let currentMeetingsDir = root.appendingPathComponent("current-meetings", isDirectory: true)
        let legacyMeetingsDir = root.appendingPathComponent("legacy-meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: currentMeetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyMeetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        try makeMeetingMarkdown(title: "Current meeting", date: "2026-04-18", body: "[00:03] [Mic/You] Current note.")
            .write(to: currentMeetingsDir.appendingPathComponent("Call_current.md"), atomically: true, encoding: .utf8)
        try makeMeetingMarkdown(title: "Legacy meeting", date: "2026-04-17", body: "[00:03] [Mic/You] Legacy note.")
            .write(to: legacyMeetingsDir.appendingPathComponent("Call_legacy.md"), atomically: true, encoding: .utf8)

        let items = CLIContextStore.recent(
            in: CLIContextDirectories(
                meetingDirs: [currentMeetingsDir, legacyMeetingsDir],
                dictationDirs: [dictationsDir]
            ),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.map(\.title), ["Current meeting", "Legacy meeting"])
    }

    func testRecentSkipsNonCaptureMarkdownInMeetingsDirectory() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        try "# Notes".write(
            to: meetingsDir.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )
        try makeMeetingMarkdown(title: "Current meeting", date: "2026-04-18", body: "[00:03] [Mic/You] Current note.")
            .write(to: meetingsDir.appendingPathComponent("Call_current.md"), atomically: true, encoding: .utf8)

        let items = CLIContextStore.recent(
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.map(\.title), ["Current meeting"])
    }

    func testRecentMeetingWithDuplicateSpeakerNamesDoesNotCrash() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        title: Duplicate names
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        speakers:
          - id: "0"
            name: Alex
            db_id: "80FB272B-6061-4FC4-8408-3F7A974C59DB"
          - id: "1"
            name: Alex
            db_id: "4F57C98D-B6B7-449F-95B9-3521FA99D7DA"
        ---

        # Duplicate names

        ## Full Transcript

        [00:03] [System/Alex] First shared name.
        [00:08] [System/Alex] Second shared name.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Duplicate names.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.recent(
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Duplicate names")
        XCTAssertEqual(items.first?.speakers, ["Alex"])
    }

    func testReadDictationRejectsParentTraversal() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try makeDictationMarkdown(text: "escaped content")
            .write(to: outsideDir.appendingPathComponent("Dictations_2026-04-07.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CLIContextStore.readDictation(
            filename: "../outside/Dictations_2026-04-07.md",
            entryId: nil,
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir)
        ))
    }

    func testReadMeetingReturnsMarkdownFromAllowedMeetingDirectory() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let markdown = makeMeetingMarkdown(title: "Product review", date: "2026-04-18", body: "[00:03] [Mic/You] Ship the agent path.")
        try markdown.write(
            to: meetingsDir.appendingPathComponent("Product review.md"),
            atomically: true,
            encoding: .utf8
        )

        let content = try CLIContextStore.readMeeting(
            filename: "Product review",
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir)
        )

        XCTAssertEqual(content, markdown)
    }

    func testReadMeetingCommandAcceptsJSONFlag() throws {
        let command = try ReadMeeting.parse([
            "Product review",
            "--meetings-dir", "/tmp/meetings",
            "--dictations-dir", "/tmp/dictations",
            "--json",
        ])

        XCTAssertTrue(command.json)
        XCTAssertEqual(command.filename, "Product review")
    }

    func testReadDictationCommandAcceptsJSONFlag() throws {
        let command = try ReadDictation.parse([
            "Dictations_2026-04-07",
            "--dictations-dir", "/tmp/dictations",
            "--entry-id", "dictation-20260407-091500-000",
            "--json",
        ])

        XCTAssertTrue(command.json)
        XCTAssertEqual(command.filename, "Dictations_2026-04-07")
        XCTAssertEqual(command.entryId, "dictation-20260407-091500-000")
    }

    func testReadMarkdownDocumentEncodesStableJSONKeys() throws {
        let document = CLIReadMarkdownDocument(
            kind: .dictation,
            filename: "Dictations_2026-04-07",
            entryId: "dictation-20260407-091500-000",
            markdown: "# Morning note\n\nShip the agent path."
        )

        let data = try JSONEncoder.contextPretty.encode(document)
        let json = String(data: data, encoding: .utf8)

        XCTAssertTrue(json?.contains("\"kind\" : \"dictation\"") == true)
        XCTAssertTrue(json?.contains("\"entry_id\" : \"dictation-20260407-091500-000\"") == true)
        XCTAssertTrue(json?.contains("\"markdown\" :") == true)
    }

    func testReadMeetingCommandJSONOutputsReadableDocument() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (meetingsDir, dictationsDir) = try makeContextDirs(in: root)
        let markdown = makeMeetingMarkdown(title: "Fixture capture", date: "2026-04-18", body: "Fixture markdown.")
        try markdown.write(
            to: meetingsDir.appendingPathComponent("Fixture capture.md"),
            atomically: true,
            encoding: .utf8
        )

        let command = try ReadMeeting.parse([
            "Fixture capture",
            "--meetings-dir", meetingsDir.path,
            "--dictations-dir", dictationsDir.path,
            "--json",
        ])
        let output = try captureStandardOutput {
            try command.run()
        }
        let document = try JSONDecoder().decode(CLIReadMarkdownDocument.self, from: XCTUnwrap(output.data(using: .utf8)))

        XCTAssertEqual(document.kind, .meeting)
        XCTAssertEqual(document.filename, "Fixture capture")
        XCTAssertNil(document.entryId)
        XCTAssertEqual(document.markdown, markdown)
    }

    func testReadDictationCommandJSONOutputsSelectedEntry() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (meetingsDir, dictationsDir) = try makeContextDirs(in: root)
        try makeDictationMarkdown(text: "Fixture dictation.")
            .write(
                to: dictationsDir.appendingPathComponent("Dictations_2026-04-07.md"),
                atomically: true,
                encoding: .utf8
            )

        let command = try ReadDictation.parse([
            "Dictations_2026-04-07",
            "--meetings-dir", meetingsDir.path,
            "--dictations-dir", dictationsDir.path,
            "--entry-id", "dictation-20260407-091500-000",
            "--json",
        ])
        let output = try captureStandardOutput {
            try command.run()
        }
        let document = try JSONDecoder().decode(CLIReadMarkdownDocument.self, from: XCTUnwrap(output.data(using: .utf8)))

        XCTAssertEqual(document.kind, .dictation)
        XCTAssertEqual(document.filename, "Dictations_2026-04-07")
        XCTAssertEqual(document.entryId, "dictation-20260407-091500-000")
        XCTAssertTrue(document.markdown.contains("# Morning note"))
        XCTAssertTrue(document.markdown.contains("Fixture dictation."))
    }

    func testReadMeetingCommandJSONNormalizesMarkdownSuffix() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (meetingsDir, dictationsDir) = try makeContextDirs(in: root)
        try makeMeetingMarkdown(title: "Suffix fixture", date: "2026-04-18", body: "Fixture markdown.")
            .write(
                to: meetingsDir.appendingPathComponent("Suffix fixture.md"),
                atomically: true,
                encoding: .utf8
            )

        let command = try ReadMeeting.parse([
            "Suffix fixture.md",
            "--meetings-dir", meetingsDir.path,
            "--dictations-dir", dictationsDir.path,
            "--json",
        ])
        let output = try captureStandardOutput {
            try command.run()
        }
        let document = try JSONDecoder().decode(CLIReadMarkdownDocument.self, from: XCTUnwrap(output.data(using: .utf8)))

        XCTAssertEqual(document.filename, "Suffix fixture")
    }

    func testReadMeetingCommandWithoutJSONKeepsRawMarkdownOutput() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (meetingsDir, dictationsDir) = try makeContextDirs(in: root)
        let markdown = makeMeetingMarkdown(title: "Raw fixture", date: "2026-04-18", body: "Fixture markdown.")
        try markdown.write(
            to: meetingsDir.appendingPathComponent("Raw fixture.md"),
            atomically: true,
            encoding: .utf8
        )

        let command = try ReadMeeting.parse([
            "Raw fixture",
            "--meetings-dir", meetingsDir.path,
            "--dictations-dir", dictationsDir.path,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        XCTAssertEqual(output, markdown + "\n")
        XCTAssertThrowsError(try JSONDecoder().decode(CLIReadMarkdownDocument.self, from: XCTUnwrap(output.data(using: .utf8))))
    }

    func testReadMeetingCommandJSONRejectsPathTraversal() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (meetingsDir, dictationsDir) = try makeContextDirs(in: root)
        let outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try makeMeetingMarkdown(title: "Outside fixture", date: "2026-04-18", body: "Fixture markdown.")
            .write(
                to: outsideDir.appendingPathComponent("Outside fixture.md"),
                atomically: true,
                encoding: .utf8
            )

        let command = try ReadMeeting.parse([
            "../outside/Outside fixture",
            "--meetings-dir", meetingsDir.path,
            "--dictations-dir", dictationsDir.path,
            "--json",
        ])

        XCTAssertThrowsError(try captureStandardOutput {
            try command.run()
        }) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid meeting filename"))
        }
    }

    func testReadMeetingRejectsParentTraversal() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)
        try makeMeetingMarkdown(title: "Escaped", date: "2026-04-18", body: "[00:03] [Mic/You] escaped content")
            .write(to: outsideDir.appendingPathComponent("Escaped.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CLIContextStore.readMeeting(
            filename: "../outside/Escaped.md",
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir)
        ))
    }

    func testReadDictationRejectsSymlinkEscape() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)

        let outsideFile = outsideDir.appendingPathComponent("Dictations_2026-04-07.md")
        try makeDictationMarkdown(text: "escaped content")
            .write(to: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dictationsDir.appendingPathComponent("Dictations_2026-04-07.md"),
            withDestinationURL: outsideFile
        )

        XCTAssertThrowsError(try CLIContextStore.readDictation(
            filename: "Dictations_2026-04-07.md",
            entryId: nil,
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir)
        ))
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeContextDirs(in root: URL) throws -> (meetings: URL, dictations: URL) {
        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)
        return (meetingsDir, dictationsDir)
    }

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

    private func makeMeetingMarkdown(title: String, date: String, body: String) -> String {
        """
        ---
        capture_type: meeting
        title: \(title)
        date: \(date)
        time: 09:15:00
        duration: "0:18"
        ---

        # \(title)

        ## Full Transcript

        \(body)
        """
    }

    private func makeDictationMarkdown(text: String) -> String {
        """
        ---
        title: "Dictations for 2026-04-07"
        date: 2026-04-07
        capture_type: dictation_day
        ---

        # Dictations for 2026-04-07

        ## 9:15 AM - Morning note

        Entry ID: `dictation-20260407-091500-000`
        Captured: 2026-04-07T09:15:00-0500
        Source app: Slack
        Delivery: copied
        Words: 2
        Characters: \(text.count)

        \(text)
        """
    }
}
