import XCTest
@testable import transcripted_qa

/// WritingValidator pass/fail fixtures, writing-path resolution, and the
/// transcript validator skipping writing day files in shared folders. All
/// fixtures live under a temp directory.
final class WritingValidatorTests: XCTestCase {
    private var tempRoot: URL!
    private var writingDir: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedQAWritingTests-\(UUID().uuidString)", isDirectory: true)
        writingDir = tempRoot.appendingPathComponent("writing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: writingDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Pass

    func testContractShapedWritingDayPassesEveryCheck() throws {
        try write(Self.validDay, named: "Writing_2026-09-25.md")

        let results = WritingValidator(directory: writingDir).validate()

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.filter { $0.status != .pass }.map(\.check), [], "a contract-shaped day has no warnings or failures")
        for check in [
            "writing/dir-private", "writing/file-private", "writing/yaml-present", "writing/capture-type",
            "writing/date-present", "writing/format-version", "writing/entries-present", "writing/entry-ids",
            "writing/captured-timestamps", "writing/entry-text", "writing/accepted-words",
        ] {
            XCTAssertTrue(results.contains { $0.check == check && $0.status == .pass }, "\(check) should pass")
        }
    }

    func testMissingOrWritingFreeFolderProducesNoResults() throws {
        XCTAssertEqual(WritingValidator(directory: tempRoot.appendingPathComponent("nope")).validate().count, 0)

        try "---\ncapture_type: meeting\ndate: 2026-09-25\n---\n\nbody".write(
            to: writingDir.appendingPathComponent("Call_2026-09-25_10-00-00.md"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(WritingValidator(directory: writingDir).validate().count, 0, "writing is opt-in: no writing files, no checks")
    }

    // MARK: - Fail

    func testBrokenWritingDayFailsTheContractChecks() throws {
        try write("""
        ---
        capture_type: dictation_day
        format_version: one
        ---

        # Writing

        ## 10:42 AM - Something

        Entry ID: `dictation-1`
        Captured: 2026-09-25 10:42
        Source app: Slack
        Words: 1
        Characters: 1
        Accepted words: 4

        x
        """, named: "Writing_2026-09-25.md")

        let results = WritingValidator(directory: writingDir).validate()
        let failed = Set(results.filter { $0.status == .fail }.map(\.check))

        XCTAssertEqual(failed, [
            "writing/capture-type",
            "writing/date-present",
            "writing/format-version",
            "writing/entry-ids",
            "writing/captured-timestamps",
            "writing/entry-text",
        ])
        XCTAssertTrue(results.contains { $0.check == "writing/accepted-words" && $0.status == .warn })
        XCTAssertFalse(
            results.contains { ($0.detail ?? "").contains("Something") || ($0.detail ?? "").contains("Slack") },
            "details never echo what the user wrote"
        )
    }

    func testMissingFrontmatterFailsEarly() throws {
        try write("# Writing\n\n## 10:42 AM - Hi\n\nHello there", named: "Writing_2026-09-25.md")

        let results = WritingValidator(directory: writingDir).validate()

        XCTAssertTrue(results.contains { $0.check == "writing/yaml-present" && $0.status == .fail })
        XCTAssertFalse(results.contains { $0.check == "writing/capture-type" })
    }

    func testLoosePermissionsAndMismatchedFilenameWarn() throws {
        try write(Self.validDay, named: "Writing_2026-09-24.md", mode: 0o644)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: writingDir.path)

        let results = WritingValidator(directory: writingDir).validate()

        XCTAssertTrue(results.contains { $0.check == "writing/file-private" && $0.status == .warn })
        XCTAssertTrue(results.contains { $0.check == "writing/dir-private" && $0.status == .warn })
        XCTAssertTrue(results.contains { $0.check == "writing/filename-date" && $0.status == .warn })
        XCTAssertFalse(results.contains { $0.status == .fail })
    }

    // MARK: - Wiring

    func testValidateWritingAndTranscriptValidatorShareAFlatFolder() throws {
        try write(Self.validDay, named: "Writing_2026-09-25.md")

        XCTAssertFalse(validateWriting(in: [writingDir]).isEmpty)

        let transcriptResults = TranscriptValidator(directory: writingDir).validate()
        XCTAssertFalse(
            transcriptResults.contains { $0.target == "Writing_2026-09-25.md" },
            "a writing day file in a shared folder is not validated as a transcript"
        )
    }

    func testExplicitMeetingsPathInfersSiblingWritingFolder() throws {
        let meetingsDir = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)

        let resolved = QADataDirectories.resolve(meetingsDir: meetingsDir.path, fileManager: .default)

        XCTAssertEqual(resolved.writingDirs.map(\.path), [writingDir.standardizedFileURL.path])
    }

    func testExplicitWritingPathWinsAndMissingSiblingMeansNoWriting() throws {
        let otherRoot = tempRoot.appendingPathComponent("other", isDirectory: true)
        let meetingsDir = otherRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)

        let noWriting = QADataDirectories.resolve(meetingsDir: meetingsDir.path, fileManager: .default)
        XCTAssertEqual(noWriting.writingDirs, [])

        let explicit = QADataDirectories.resolve(
            meetingsDir: meetingsDir.path,
            writingDir: writingDir.path,
            fileManager: .default
        )
        XCTAssertEqual(explicit.writingDirs.map(\.path), [writingDir.standardizedFileURL.path])
    }

    func testDefaultResolutionUsesCaptureLibraryWritingFolder() throws {
        let resolved = QADataDirectories.resolve(
            fileManager: .default,
            homeDirectory: tempRoot,
            environment: [:]
        )

        XCTAssertEqual(resolved.writingDirs.map(\.path), [
            tempRoot.appendingPathComponent("Library/Application Support/Transcripted/captures/writing")
                .standardizedFileURL.path,
        ])
    }

    // MARK: - Helpers

    private func write(_ content: String, named name: String, mode: Int = 0o600) throws {
        let url = writingDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private static let validDay = """
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
}
