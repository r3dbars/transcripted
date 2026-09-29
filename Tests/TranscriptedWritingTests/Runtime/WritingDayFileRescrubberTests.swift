import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// Promises for re-scrubbing day files already on disk. Fixtures are built
/// with `WritingDayFileFormatter`, so they look exactly like files the app
/// wrote. Disk tests use their own temporary `writing` folder, never the real
/// capture library.
@Suite("Save my writing re-scrubs existing day files")
struct WritingDayFileRescrubberTests {
    private static let start: Int64 = 1_790_350_931_387
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let mail = "com.apple.mail"
    private static let terminal = "com.apple.Terminal"
    private static let timeZone = TimeZone(identifier: "America/Chicago")!
    private static let locale = Locale(identifier: "en_US")
    private static let redactedPassword = "\u{27E8}redacted:password\u{27E9}"

    @Test("A file with nothing to scrub isn't rewritten")
    func cleanFileUnchanged() {
        let file = Self.file([
            Self.section("Pushing the launch to Thursday", app: Self.slack, at: Self.start),
            Self.section("cd ~/code\ngit status", app: Self.terminal, at: Self.start + 30_000),
            Self.section("Thanks for the notes, see you at 10:30", app: Self.mail, at: Self.start + 90_000),
        ])
        #expect(WritingDayFileRescrubber.rescrubbed(file, timeZone: Self.timeZone, locale: Self.locale) == nil)
    }

    @Test("A secret is redacted, the heading and counts follow the clean text, and every other byte is kept")
    func secretRedactedTitleAndCountsRecomputed() throws {
        let before = Self.section("Pushing the launch to Thursday", app: Self.slack, at: Self.start)
        let after = Self.section("Thanks for the notes, see you at 10:30", app: Self.mail, at: Self.start + 300_000)
        let dirty = Self.file([
            before,
            Self.section("the wifi password is sunshine", app: Self.slack, at: Self.start + 60_000),
            after,
        ])
        let result = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        let expected = Self.file([
            before,
            // Same entry ID, time and app; title, Words and Characters from the clean text.
            Self.section("the wifi password is \(Self.redactedPassword)", app: Self.slack, at: Self.start + 60_000),
            after,
        ])
        #expect(result == expected)
        #expect(!result.contains("sunshine"))
    }

    @Test("A section left with only redactions keeps its heading with just the token, and its neighbours are kept")
    func onlyRedactionsSectionKeptAsToken() throws {
        let first = Self.section("Pushing the launch to Thursday", app: Self.slack, at: Self.start)
        let last = Self.section("Thanks for the notes, see you at 10:30", app: Self.mail, at: Self.start + 300_000)
        let dirty = Self.file([
            first,
            Self.section("Tr0ub4dor&3", app: Self.slack, at: Self.start + 60_000),
            last,
        ])
        let result = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        #expect(result == Self.file([
            first,
            Self.section(Self.redactedPassword, app: Self.slack, at: Self.start + 60_000),
            last,
        ]))
        #expect(!result.contains("Tr0ub4dor"))
    }

    @Test("Each section is scrubbed as its own app: a sudo password counts in Terminal, not in Slack")
    func sectionUsesItsBundleID() throws {
        let terminalFile = Self.file([Self.section("sudo -v\nsunshine", app: Self.terminal, at: Self.start)])
        let result = try #require(
            WritingDayFileRescrubber.rescrubbed(terminalFile, timeZone: Self.timeZone, locale: Self.locale)
        )
        #expect(result == Self.file([
            Self.section("sudo -v\n\(Self.redactedPassword)", app: Self.terminal, at: Self.start),
        ]))

        let slackFile = Self.file([Self.section("sudo -v\nsunshine", app: Self.slack, at: Self.start)])
        #expect(WritingDayFileRescrubber.rescrubbed(slackFile, timeZone: Self.timeZone, locale: Self.locale) == nil)
    }

    @Test("A password section right after a same-app sudo section is redacted")
    func previousSectionIsContext() throws {
        let sudo = Self.section("sudo apt update", app: Self.terminal, at: Self.start)
        let later = Self.section("Back to the release notes now", app: Self.slack, at: Self.start + 60_000)
        let dirty = Self.file([
            sudo,
            Self.section("sunshine", app: Self.terminal, at: Self.start + 5_000),
            later,
        ])
        let result = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        #expect(result == Self.file([
            sudo,
            Self.section(Self.redactedPassword, app: Self.terminal, at: Self.start + 5_000),
            later,
        ]))
    }

    @Test("Rescrubbing is idempotent: tools run after a sudo password aren't eaten one pass at a time")
    func sudoThenToolsIdempotent() throws {
        let lines = ["sudo -v", "hunter2", "pytest", "ruff", "black", "mypy"]
        let dirty = Self.file(lines.enumerated().map { offset, line in
            Self.section(line, app: Self.terminal, at: Self.start + Int64(offset) * 20_000)
        })
        let once = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        #expect(once == Self.file(lines.enumerated().map { offset, line in
            Self.section(
                line == "hunter2" ? Self.redactedPassword : line,
                app: Self.terminal,
                at: Self.start + Int64(offset) * 20_000
            )
        }))
        // Passes 2 and 3 find nothing: the same file as pass 1.
        let twice = WritingDayFileRescrubber.rescrubbed(once, timeZone: Self.timeZone, locale: Self.locale) ?? once
        let thrice = WritingDayFileRescrubber.rescrubbed(twice, timeZone: Self.timeZone, locale: Self.locale) ?? twice
        #expect(twice == once)
        #expect(thrice == once)
    }

    @Test("Rescrubbing is idempotent for a letters-only sudo password followed by commands the rules can't tell apart")
    func lettersOnlyPasswordThenCommandsIdempotent() throws {
        // `deploybox` and `buildall` look like a first answer to the prompt;
        // only the first line after sudo may be one.
        let lines = ["sudo -v", "sunshine", "deploybox", "buildall"]
        let dirty = Self.file(lines.enumerated().map { offset, line in
            Self.section(line, app: Self.terminal, at: Self.start + Int64(offset) * 20_000)
        })
        let once = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        #expect(!once.contains("sunshine"))
        #expect(once.contains("deploybox"))
        #expect(once.contains("buildall"))
        #expect(WritingDayFileRescrubber.rescrubbed(once, timeZone: Self.timeZone, locale: Self.locale) == nil)
    }

    @Test("A rewritten section's accepted-word count is never more than its word count")
    func acceptedWordsCapped() throws {
        let passphrase = "ssh-keygen -t ed25519\ncorrect horse battery staple"
        let dirty = Self.file([Self.section(passphrase, app: Self.terminal, at: Self.start, accepted: 6)])
        let result = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        let clean = "ssh-keygen -t ed25519\n\(Self.redactedPassword)"
        #expect(result == Self.file([Self.section(clean, app: Self.terminal, at: Self.start, accepted: 4)]))
        #expect(result.contains("Accepted words: 4"))
    }

    @Test("The previous section isn't context ten minutes later or from another app")
    func previousSectionContextLimits() {
        let tenMinutes = Self.file([
            Self.section("sudo apt update", app: Self.terminal, at: Self.start),
            Self.section("sunshine", app: Self.terminal, at: Self.start + 600_000),
        ])
        #expect(WritingDayFileRescrubber.rescrubbed(tenMinutes, timeZone: Self.timeZone, locale: Self.locale) == nil)

        let otherApp = Self.file([
            Self.section("sudo apt update", app: Self.slack, at: Self.start),
            Self.section("sunshine", app: Self.terminal, at: Self.start + 5_000),
        ])
        #expect(WritingDayFileRescrubber.rescrubbed(otherApp, timeZone: Self.timeZone, locale: Self.locale) == nil)
    }

    @Test("Re-scrubbing a re-scrubbed file changes nothing")
    func idempotent() throws {
        let dirty = Self.file([
            Self.section("Pushing the launch to Thursday", app: Self.slack, at: Self.start),
            Self.section("the wifi password is sunshine", app: Self.slack, at: Self.start + 60_000),
            Self.section("sudo apt update", app: Self.terminal, at: Self.start + 120_000),
            Self.section("sunshine", app: Self.terminal, at: Self.start + 125_000),
            Self.section("export OPENAI_API_KEY=abc123", app: Self.terminal, at: Self.start + 130_000),
            Self.section("Thanks for the notes, see you at 10:30", app: Self.mail, at: Self.start + 300_000),
        ])
        let once = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        #expect(!once.contains("sunshine"))
        #expect(!once.contains("abc123"))
        #expect(once.contains("Pushing the launch to Thursday"))
        #expect(once.contains("sudo apt update"))
        #expect(WritingDayFileRescrubber.rescrubbed(once, timeZone: Self.timeZone, locale: Self.locale) == nil)
    }

    @Test("Rescrub all rewrites only Writing_*.md directly in the folder, owner-only, and leaves clean files alone")
    func rescrubAllTouchesOnlyDayFiles() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sandbox.writing, withIntermediateDirectories: true)

        let dirty = Self.file([
            Self.section("Pushing the launch to Thursday", app: Self.slack, at: Self.start),
            Self.section("the wifi password is sunshine", app: Self.slack, at: Self.start + 60_000),
        ])
        let clean = Self.file([Self.section("Pushing the launch to Thursday", app: Self.slack, at: Self.start)])

        let dirtyDay = sandbox.writing.appendingPathComponent("Writing_2026-09-25.md")
        let cleanDay = sandbox.writing.appendingPathComponent("Writing_2026-09-24.md")
        let notes = sandbox.writing.appendingPathComponent("notes.md")
        let wrongExtension = sandbox.writing.appendingPathComponent("Writing_2026-09-23.txt")
        let nested = sandbox.writing.appendingPathComponent("archive", isDirectory: true)
        let nestedDay = nested.appendingPathComponent("Writing_2026-01-01.md")
        let outside = sandbox.root.appendingPathComponent("Writing_2026-09-25.md")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        for url in [dirtyDay, notes, wrongExtension, nestedDay, outside] {
            try Data(dirty.utf8).write(to: url)
        }
        try Data(clean.utf8).write(to: cleanDay)
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: cleanDay.path)

        let outcome = WritingDayFileRescrubber.rescrubAll(in: sandbox.writing, timeZone: Self.timeZone, locale: Self.locale)
        #expect(outcome == WritingDayFileRescrubber.Outcome(filesScanned: 2, filesChanged: 1, failures: 0))

        let rewritten = try String(contentsOf: dirtyDay, encoding: .utf8)
        #expect(rewritten == Self.file([
            Self.section("Pushing the launch to Thursday", app: Self.slack, at: Self.start),
            Self.section("the wifi password is \(Self.redactedPassword)", app: Self.slack, at: Self.start + 60_000),
        ]))
        #expect(try Self.mode(of: dirtyDay) == 0o600)

        // Nothing to scrub: not rewritten at all.
        #expect(try String(contentsOf: cleanDay, encoding: .utf8) == clean)
        let cleanModified = try fileManager.attributesOfItem(atPath: cleanDay.path)[.modificationDate] as? Date
        #expect(cleanModified == oldDate)

        for untouched in [notes, wrongExtension, nestedDay, outside] {
            #expect(try String(contentsOf: untouched, encoding: .utf8) == dirty, "\(untouched.lastPathComponent) changed")
        }
        // No temporary file is left behind.
        #expect(Set(try fileManager.contentsOfDirectory(atPath: sandbox.writing.path)) == [
            "Writing_2026-09-25.md", "Writing_2026-09-24.md", "notes.md", "Writing_2026-09-23.txt", "archive",
        ])
    }

    @Test("A rewrite is refused when the file changed since it was read")
    func replaceRefusesChangedFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try FileManager.default.createDirectory(at: sandbox.writing, withIntermediateDirectories: true)
        let day = sandbox.writing.appendingPathComponent("Writing_2026-09-25.md")
        let read = Data(Self.file([Self.section("the wifi password is sunshine", app: Self.slack, at: Self.start)]).utf8)
        let appended = read + Data("\n\nmore".utf8)
        try appended.write(to: day)

        #expect(throws: WritingDayFileStore.StoreError.self) {
            try WritingDayFileStore.replace(dayFile: day.lastPathComponent, in: sandbox.writing, expected: read, with: Data("x".utf8))
        }
        #expect(try Data(contentsOf: day) == appended)
    }

    @Test("The recorder's rescrub announces each rewritten file and stops when asked")
    func recorderRescrubAnnouncesAndStops() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try FileManager.default.createDirectory(at: sandbox.writing, withIntermediateDirectories: true)
        let dirty = Self.file([Self.section("the wifi password is sunshine", app: Self.slack, at: Self.start)])
        for day in ["Writing_2026-09-24.md", "Writing_2026-09-25.md"] {
            try Data(dirty.utf8).write(to: sandbox.writing.appendingPathComponent(day))
        }
        let written = Announcements()
        let folder = sandbox.writing
        let recorder = WritingDayFileRecorder(
            directory: { folder },
            gate: { .init(enabled: true, historyIdentifier: "history", consentIdentifier: "consent") },
            appName: { _ in nil },
            timeZone: { Self.timeZone },
            locale: Self.locale,
            didWrite: { written.add($0.lastPathComponent) }
        )

        let stopped = recorder.rescrubExistingDayFiles(shouldContinue: { false })
        #expect(stopped.filesChanged == 0)
        #expect(stopped.failures == 1)
        #expect(written.names.isEmpty)

        let outcome = recorder.rescrubExistingDayFiles()
        #expect(outcome == WritingDayFileRescrubber.Outcome(filesScanned: 2, filesChanged: 2, failures: 0))
        #expect(written.names == ["Writing_2026-09-24.md", "Writing_2026-09-25.md"])
        #expect(!(try String(contentsOf: folder.appendingPathComponent("Writing_2026-09-25.md"), encoding: .utf8)).contains("sunshine"))
    }

    @Test("Terminal context in old files survives a section from another app in between")
    func rescrubContextPerApp() throws {
        let dirty = Self.file([
            Self.section("sudo apt update", app: Self.terminal, at: Self.start),
            Self.section("brb one sec", app: Self.slack, at: Self.start + 3_000),
            Self.section("sunshine", app: Self.terminal, at: Self.start + 70_000),
        ])
        let result = try #require(WritingDayFileRescrubber.rescrubbed(dirty, timeZone: Self.timeZone, locale: Self.locale))
        #expect(result == Self.file([
            Self.section("sudo apt update", app: Self.terminal, at: Self.start),
            Self.section("brb one sec", app: Self.slack, at: Self.start + 3_000),
            Self.section(Self.redactedPassword, app: Self.terminal, at: Self.start + 70_000),
        ]))
    }

    @Test("A day file that can never be read is skipped, not a failure, so it doesn't make every launch retry")
    func unreadableFilesSkipped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sandbox.writing, withIntermediateDirectories: true)
        let dirty = Self.file([Self.section("the wifi password is sunshine", app: Self.slack, at: Self.start)])

        let good = sandbox.writing.appendingPathComponent("Writing_2026-09-25.md")
        try Data(dirty.utf8).write(to: good)
        // A symlink named like a day file, pointing outside the folder.
        let target = sandbox.root.appendingPathComponent("elsewhere.md")
        try Data(dirty.utf8).write(to: target)
        let link = sandbox.writing.appendingPathComponent("Writing_2026-09-24.md")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        // Not UTF-8.
        let binary = sandbox.writing.appendingPathComponent("Writing_2026-09-23.md")
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: binary)

        let outcome = WritingDayFileRescrubber.rescrubAll(in: sandbox.writing, timeZone: Self.timeZone, locale: Self.locale)
        #expect(outcome == WritingDayFileRescrubber.Outcome(filesScanned: 3, filesChanged: 1, failures: 0, skipped: 2))
        // The symlink's target is never touched.
        #expect(try String(contentsOf: target, encoding: .utf8) == dirty)
        #expect(!(try String(contentsOf: good, encoding: .utf8)).contains("sunshine"))
    }

    // MARK: - Helpers

    private static func section(_ text: String, app: String, at milliseconds: Int64, accepted: Int = 0) -> String {
        let names = [slack: "Slack", mail: "Mail", terminal: "Terminal"]
        return WritingDayFileFormatter.section(
            .init(
                entryID: WritingDayFileFormatter.entryID(
                    forMilliseconds: milliseconds, hexSuffix: "0000abcd", timeZone: timeZone
                ),
                capturedAtMilliseconds: milliseconds,
                sourceAppName: names[app] ?? app,
                bundleIdentifier: app,
                wordCount: text.split(whereSeparator: \.isWhitespace).count,
                characterCount: text.count,
                acceptedWordCount: accepted,
                text: text
            ),
            timeZone: timeZone,
            locale: locale
        )
    }

    /// The header plus each section, appended the same way the store appends.
    private static func file(_ sections: [String]) -> String {
        let header = WritingDayFileFormatter.dayHeader(forMilliseconds: start, timeZone: timeZone, locale: locale)
        var data: Data?
        for section in sections {
            data = WritingDayFileFormatter.contents(appending: section, to: data, header: header)
        }
        return String(decoding: data ?? Data(header.utf8), as: UTF8.self)
    }

    private static func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private final class Announcements: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var names: [String] { lock.withLock { stored } }
        func add(_ name: String) { lock.withLock { stored.append(name) } }
    }

    /// `<tmp>/<UUID>/writing`, removed afterwards.
    private struct Sandbox {
        let root: URL
        var writing: URL { root.appendingPathComponent("writing", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
