import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// Every test works in its own temporary folder; nothing here touches the
/// real capture library or `~/Library/Application Support/Transcripted/`.
@Suite("Save my writing day files on disk")
struct WritingDayFileStoreTests {
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let start: Int64 = 1_790_350_931_387

    @Test("Appends are owner-only and keep the header once")
    func ownerOnlyAppends() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try WritingDayFileStore.append(
            section: "## 10:42 AM - first", header: "HEADER", fileName: "Writing_2026-09-25.md", in: sandbox.writing
        )
        try WritingDayFileStore.append(
            section: "## 11:05 AM - second", header: "HEADER", fileName: "Writing_2026-09-25.md", in: sandbox.writing
        )
        #expect(try String(contentsOf: url, encoding: .utf8) == "HEADER\n\n## 10:42 AM - first\n\n## 11:05 AM - second")
        #expect(try Self.mode(of: url) == 0o600)
        #expect(try Self.mode(of: sandbox.writing) == 0o700)
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.writing.path) == ["Writing_2026-09-25.md"])
    }

    @Test("An existing day file that can't be read is never overwritten")
    func refusesToClobber() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try FileManager.default.createDirectory(at: sandbox.writing, withIntermediateDirectories: true)
        let target = sandbox.root.appendingPathComponent("elsewhere.md")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: sandbox.writing.appendingPathComponent("Writing_2026-09-25.md"),
            withDestinationURL: target
        )
        #expect(throws: WritingDayFileStore.StoreError.self) {
            try WritingDayFileStore.append(
                section: "## x", header: "H", fileName: "Writing_2026-09-25.md", in: sandbox.writing
            )
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
    }

    @Test("Delete all removes only Writing_*.md directly inside the writing folder")
    func deleteAllValidatesPaths() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fileManager = FileManager.default
        try WritingDayFileStore.append(section: "a", header: "h", fileName: "Writing_2026-09-24.md", in: sandbox.writing)
        try WritingDayFileStore.append(section: "b", header: "h", fileName: "Writing_2026-09-25.md", in: sandbox.writing)
        let stale = sandbox.writing.appendingPathComponent(".writing-append-stale.tmp")
        try Data().write(to: stale)
        let notes = sandbox.writing.appendingPathComponent("notes.md")
        try Data("mine".utf8).write(to: notes)
        let nested = sandbox.writing.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedDay = nested.appendingPathComponent("Writing_2026-01-01.md")
        try Data("older".utf8).write(to: nestedDay)
        let outside = sandbox.root.appendingPathComponent("Writing_2026-09-25.md")
        try Data("outside".utf8).write(to: outside)
        let linkTarget = sandbox.root.appendingPathComponent("target.md")
        try Data("linked".utf8).write(to: linkTarget)
        try fileManager.createSymbolicLink(
            at: sandbox.writing.appendingPathComponent("Writing_2026-09-26.md"),
            withDestinationURL: linkTarget
        )

        // A symlink it would have to follow means not everything could go.
        #expect(!WritingDayFileStore.deleteAll(in: sandbox.writing))
        #expect(!fileManager.fileExists(atPath: sandbox.writing.appendingPathComponent("Writing_2026-09-24.md").path))
        #expect(!fileManager.fileExists(atPath: sandbox.writing.appendingPathComponent("Writing_2026-09-25.md").path))
        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(fileManager.fileExists(atPath: notes.path))
        #expect(fileManager.fileExists(atPath: nestedDay.path))
        #expect(fileManager.fileExists(atPath: outside.path))
        #expect(try String(contentsOf: linkTarget, encoding: .utf8) == "linked")
    }

    @Test("Delete all refuses a folder that isn't the writing folder")
    func deleteAllRefusesOtherFolders() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let dictations = sandbox.root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dictations, withIntermediateDirectories: true)
        let day = dictations.appendingPathComponent("Writing_2026-09-25.md")
        try Data("not ours".utf8).write(to: day)
        #expect(!WritingDayFileStore.deleteAll(in: dictations))
        #expect(FileManager.default.fileExists(atPath: day.path))

        // A `writing` link to another folder is resolved and refused.
        let link = sandbox.root.appendingPathComponent("elsewhere", isDirectory: true)
            .appendingPathComponent("writing", isDirectory: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dictations)
        #expect(!WritingDayFileStore.deleteAll(in: link))
        #expect(FileManager.default.fileExists(atPath: day.path))

        // Nothing there yet is nothing to delete.
        #expect(WritingDayFileStore.deleteAll(in: sandbox.writing))
    }

    @Test("Path validation")
    func pathValidation() {
        let folder = URL(fileURLWithPath: "/Users/someone/Library/Transcripted/writing", isDirectory: true)
        #expect(WritingDayFileStore.isDeletable(folder.appendingPathComponent("Writing_2026-09-25.md"), in: folder))
        #expect(WritingDayFileStore.isDeletable(folder.appendingPathComponent(".writing-append-abc.tmp"), in: folder))
        #expect(!WritingDayFileStore.isDeletable(folder.appendingPathComponent("Dictations_2026-09-25.md"), in: folder))
        #expect(!WritingDayFileStore.isDeletable(folder.appendingPathComponent("Writing_2026-09-25.txt"), in: folder))
        #expect(!WritingDayFileStore.isDeletable(
            folder.appendingPathComponent("sub/Writing_2026-09-25.md"),
            in: folder
        ))
        #expect(!WritingDayFileStore.isDeletable(
            URL(fileURLWithPath: "/Users/someone/Writing_2026-09-25.md"),
            in: folder
        ))
        #expect(!WritingDayFileStore.isDeletable(
            folder.appendingPathComponent("../Writing_2026-09-25.md"),
            in: folder
        ))
        #expect(!WritingDayFileStore.isDayFileName("Writing_.md"))
    }

    @Test("The recorder writes closed entries, flushes at quit and notifies")
    func recorderEndToEnd() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let clock = Clock(Self.start + 3_000)
        let written = Written()
        let recorder = Self.recorder(sandbox: sandbox, clock: clock, written: written)

        await recorder.ingest([
            Self.typed("Pushing teh", at: Self.start),
            Self.deletion(2, session: "chain_1", at: Self.start + 1_000),
            Self.typed("he launch to Thursday", session: "chain_1", at: Self.start + 2_000),
        ])
        #expect(written.urls.isEmpty)
        recorder.closeIdleEntries()
        #expect(written.urls.isEmpty)
        clock.now = Self.start + 3_000 + 120_001
        recorder.closeIdleEntries()
        #expect(written.urls.count == 1)

        await recorder.ingest([Self.typed("Second entry here", session: "other", at: Self.start + 200_000)])
        recorder.flush()
        #expect(written.urls.count == 2)
        let file = try String(contentsOf: try #require(written.urls.last), encoding: .utf8)
        #expect(file.hasPrefix("---\ntitle: \"Writing for September 25, 2026\"\n"))
        #expect(file.components(separatedBy: "\n## ").count == 3)
        #expect(file.contains("## 10:42 AM - Pushing the launch to Thursday\n"))
        #expect(file.contains("Entry ID: `writing-20260925-104211-387-0000abcd`\n"))
        #expect(file.contains("Source app: Slack\nBundle ID: `com.tinyspeck.slackmacgap`\nWords: 5\nCharacters: 30\nAccepted words: 0\n\nPushing the launch to Thursday"))
        #expect(file.hasSuffix("\n\nSecond entry here"))
    }

    @Test("Nothing is written with Save my writing off, after a consent change, or twice for a retry")
    func recorderGates() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let clock = Clock(Self.start)
        let written = Written()
        let gate = GateBox(.init(enabled: false, historyIdentifier: "history", consentIdentifier: "consent"))
        let recorder = Self.recorder(sandbox: sandbox, clock: clock, written: written, gate: gate)

        await recorder.ingest([Self.typed("while off", at: Self.start)])
        recorder.flush()
        #expect(written.urls.isEmpty)

        gate.value.enabled = true
        let batch = [Self.typed("only once please", at: Self.start + 1_000)]
        await recorder.ingest(batch)
        await recorder.ingest(batch)
        // Toggled off and on: the entry typed under the old consent is dropped.
        gate.value.consentIdentifier = "consent-b"
        recorder.flush()
        #expect(written.urls.isEmpty)

        gate.value.consentIdentifier = "consent"
        await recorder.ingest(batch.map { Self.typed($0.text, id: "retry-new", at: $0.timestampMilliseconds) })
        await recorder.ingest(batch.map { Self.typed($0.text, id: "retry-new", at: $0.timestampMilliseconds) })
        recorder.flush()
        let file = try String(contentsOf: try #require(written.urls.first), encoding: .utf8)
        #expect(file.components(separatedBy: "Entry ID:").count == 2)
    }

    @Test("Delete all drops the open entry and every day file")
    func recorderDeleteAll() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let written = Written()
        let recorder = Self.recorder(sandbox: sandbox, clock: Clock(Self.start), written: written)
        await recorder.ingest([Self.typed("first entry", session: "a", at: Self.start)])
        await recorder.ingest([Self.typed("still open", session: "b", at: Self.start + 1_000)])
        #expect(written.urls.count == 1)
        #expect(recorder.deleteAll())
        recorder.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.writing.path).isEmpty)
    }

    @Test("A write failure is kept for the Writing tab, reported once, and cleared by the next good write")
    func recorderReportsWriteFailures() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let clock = Clock(Self.start)
        let written = Written()
        let problems = Problems()
        let recorder = Self.recorder(sandbox: sandbox, clock: clock, written: written, problems: problems)
        #expect(recorder.lastWriteFailure == nil)

        // A file where the folder should be fails the same closed way as a
        // NAS or exFAT library that won't take 0700.
        try Data().write(to: sandbox.writing)
        await recorder.ingest([Self.typed("first entry", session: "a", at: Self.start)])
        recorder.flush()
        let failure = try #require(recorder.lastWriteFailure)
        #expect(failure.error == .folderUnavailable)
        #expect(failure.date == Self.date(Self.start))
        #expect(problems.values == [.folderUnavailable])

        // Still failing: the time moves on, but it's the same problem.
        clock.now = Self.start + 5_000
        await recorder.ingest([Self.typed("second entry", session: "b", at: Self.start + 5_000)])
        recorder.flush()
        #expect(recorder.lastWriteFailure?.date == Self.date(Self.start + 5_000))
        #expect(problems.values == [.folderUnavailable])
        #expect(written.urls.isEmpty)

        // Fixed: the parked entries go out with the new one, and it clears.
        try FileManager.default.removeItem(at: sandbox.writing)
        await recorder.ingest([Self.typed("third entry", session: "c", at: Self.start + 6_000)])
        recorder.flush()
        #expect(recorder.lastWriteFailure == nil)
        #expect(written.urls.count == 3)

        // A failure after a success is a new problem.
        try FileManager.default.removeItem(at: sandbox.writing)
        try Data().write(to: sandbox.writing)
        await recorder.ingest([Self.typed("fourth entry", session: "d", at: Self.start + 7_000)])
        recorder.flush()
        #expect(recorder.lastWriteFailure?.error == .folderUnavailable)
        #expect(problems.values == [.folderUnavailable, .folderUnavailable])
    }

    // MARK: - Helpers

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func recorder(
        sandbox: Sandbox,
        clock: Clock,
        written: Written,
        gate: GateBox = GateBox(.init(enabled: true, historyIdentifier: "history", consentIdentifier: "consent")),
        problems: Problems = Problems()
    ) -> WritingDayFileRecorder {
        let writing = sandbox.writing
        return WritingDayFileRecorder(
            directory: { writing },
            gate: { gate.value },
            appName: { $0 == slack ? "Slack" : nil },
            now: { Self.date(clock.now) },
            timeZone: { TimeZone(identifier: "America/Chicago")! },
            locale: Locale(identifier: "en_US"),
            entryIDSuffix: { "0000abcd" },
            didWrite: { written.append($0) },
            writeProblemStarted: { problems.append($0) }
        )
    }

    private static func typed(
        _ text: String,
        id: String = UUID().uuidString,
        session: String = "chain",
        at timestamp: Int64
    ) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            id: id,
            timestampMilliseconds: timestamp,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: session,
            appBundleIdentifier: slack,
            source: .typed,
            text: text
        )!
    }

    private static func deletion(_ count: Int, session: String, at timestamp: Int64) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            deletionID: UUID().uuidString,
            timestampMilliseconds: timestamp,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: session,
            appBundleIdentifier: slack,
            deletedCharacters: count
        )!
    }

    private static func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// A temporary capture library under the user's own temporary folder.
    private struct Sandbox {
        let root: URL
        var writing: URL { root.appendingPathComponent("writing", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcripted-writing-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ value: Int64) { self.value = value }
        var now: Int64 {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL] = []
        var urls: [URL] { lock.withLock { values } }
        func append(_ url: URL) { lock.withLock { values.append(url) } }
    }

    private final class Problems: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [WritingDayFileStore.StoreError] = []
        var values: [WritingDayFileStore.StoreError] { lock.withLock { errors } }
        func append(_ error: WritingDayFileStore.StoreError) { lock.withLock { errors.append(error) } }
    }

    private final class GateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: WritingDayFileRecorder.Gate
        init(_ gate: WritingDayFileRecorder.Gate) { self.gate = gate }
        var value: WritingDayFileRecorder.Gate {
            get { lock.withLock { gate } }
            set { lock.withLock { gate = newValue } }
        }
    }
}
