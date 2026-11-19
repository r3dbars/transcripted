import Foundation

/// Where a title's evidence comes from at save time, relabeling after
/// speaker names change, and the edges around the job: CRLF files, model
/// removal racing a download, and the helper's port.
@MainActor
func testMeetingTitlesRelabel() async {
    await runSuite("Each save route decides the title the right way") {
        let fixture = ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        controller.setEnabled(true)
        await controller.waitUntilIdle()

        let imported = fixture.meeting("import.md", title: "Voice memo 42", extra: ["imported_at: 2026-03-04T10:00:00Z"])
        let notImport = fixture.meeting("not-import.md", title: "Voice memo 43")
        let calendar = fixture.meeting("calendar.md", title: "Meeting with Priya and Marcus")
        let generated = fixture.meeting("generated.md", title: "Meeting at 9:00 AM")
        controller.noteSavedMeeting(at: imported, title: "Voice memo 42", origin: .importedFile)
        controller.noteSavedMeeting(at: notImport, title: "Voice memo 43", origin: .importedFile)
        // A recording that kept its calendar title, even one that reads like the rule's.
        controller.noteSavedMeeting(at: calendar, title: "Meeting with Priya and Marcus", origin: .recording)
        controller.noteSavedMeeting(at: generated, title: "Meeting at 9:00 AM", titleWasGenerated: true, origin: .recording)
        await controller.waitUntilIdle()

        assertEqual(fixture.values(imported)["ai_title"], "Vendor contract renewal", "an import's own name is the app's")
        assertNil(fixture.values(notImport)["ai_title"], "only a file that is an import counts as one")
        assertNil(fixture.values(calendar)["ai_title"], "a recording's own title is kept")
        assertNotNil(fixture.values(calendar)["ai_summary"])
        assertEqual(fixture.values(generated)["ai_title"], "Vendor contract renewal")
    }

    await runSuite("Speaker names changing after the label relabels once, keeping title ownership") {
        let fixture = ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        controller.setEnabled(true)
        let ruleTitled = fixture.meeting("rule.md", title: "Meeting at 10:05 AM", turns: unnamedTurns)
        let renamed = fixture.meeting("renamed.md", title: "Board prep", extra: ["title_set_by_user: true"], turns: unnamedTurns)
        let kept = fixture.meeting("kept.md", title: "Meeting at 10:05 AM", turns: unnamedTurns)
        controller.noteSavedMeeting(at: ruleTitled, title: "Meeting at 10:05 AM", titleWasGenerated: true, origin: .recording)
        controller.noteSavedMeeting(at: renamed, title: "Board prep", origin: .other)
        controller.noteSavedMeeting(at: kept, title: "Meeting at 10:05 AM", origin: .recording)
        await controller.waitUntilIdle()
        assertEqual(fixture.host.engine.chatBodies.count, 3)
        let firstSpeakers = fixture.values(ruleTitled)["ai_summary_speakers"]
        assertNotNil(firstSpeakers)
        assertEqual(fixture.values(ruleTitled)["ai_title"], "Vendor contract renewal")
        assertNil(fixture.values(kept)["ai_title"], "kept: the recording brought its title")

        // The review is answered: the speaker gets a name in every file.
        for url in [ruleTitled, renamed, kept] {
            let named = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .replacingOccurrences(of: "System/Speaker 1", with: "System/Dana")
            try? named.write(to: url, atomically: true, encoding: .utf8)
        }
        fixture.host.engine.reply = #"{"title": "Support contract decision", "line": "Dana confirmed the renewal.", "summary": "Dana compared the bids. The renewal goes ahead."}"#
        controller.libraryChanged(ids: [ruleTitled, renamed, kept].map { $0.standardizedFileURL.path })
        await controller.waitUntilIdle()

        assertEqual(fixture.host.engine.chatBodies.count, 6, "each meeting is labeled once more")
        assertTrue(fixture.host.engine.sentTranscripts.suffix(3).allSatisfy { $0.contains("Dana:") })
        assertFalse(fixture.values(ruleTitled)["ai_summary_speakers"] == firstSpeakers, "the new names are recorded")
        assertEqual(fixture.values(ruleTitled)["ai_title"], "Support contract decision", "the model's own earlier title may be replaced")
        assertEqual(fixture.values(ruleTitled)["ai_title_replaces"], "Meeting at 10:05 AM")
        assertEqual(fixture.values(ruleTitled)["ai_summary"], "Dana compared the bids. The renewal goes ahead.")
        assertNil(fixture.values(renamed)["ai_title"], "a rename still wins")
        assertNil(fixture.values(kept)["ai_title"], "a title kept before is kept again")
        assertEqual(fixture.values(kept)["ai_summary"], "Dana compared the bids. The renewal goes ahead.")

        // And it settles: nothing changed, nothing runs.
        controller.libraryChanged(ids: [ruleTitled, renamed, kept].map { $0.standardizedFileURL.path })
        await controller.waitUntilIdle()
        assertEqual(fixture.host.engine.chatBodies.count, 6, "no loop")
    }

    runSuite("The rescan reads past the frontmatter only for files changed since their label") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let label = MeetingTitlesLabel(title: "Vendor contract renewal", line: nil, summary: "Two bids were compared.")
        let speakers = MeetingTitlesSpeakers.fingerprint(of: MeetingTitlesTranscript.turns(
            fromMeetingMarkdown: MeetingTitlesFixtures.meetingMarkdown(turns: unnamedTurns)
        ))
        func labeled(_ name: String, stamp: Date) -> URL {
            let raw = MeetingTitlesFrontmatterWriter.markdown(
                byApplying: label, replaceableTitle: "Meeting with Priya", speakers: speakers,
                to: MeetingTitlesFixtures.meetingMarkdown(turns: unnamedTurns), generatedAt: stamp
            ) ?? ""
            let named = raw.replacingOccurrences(of: "System/Speaker 1", with: "System/Dana")
            return MeetingTitlesFixtures.writeMeeting(named, named: name, in: directory)
        }
        // Labeled long ago, names changed since (the file is newer): relabel.
        labeled("stale.md", stamp: Date(timeIntervalSince1970: 1_700_000_000))
        // Labeled "just now" by this write: the frontmatter alone says done.
        labeled("fresh.md", stamp: Date().addingTimeInterval(60))
        let names = MeetingTitlesController.backfillJobs(in: directory).map { $0.transcriptURL.lastPathComponent }
        assertEqual(names, ["stale.md"])
        assertTrue(MeetingTitlesController.changedSinceLabeled(values: [:], modifiedAt: Date()), "no stamp: check")
    }

    await runSuite("A CRLF file is not read as a meeting and is left byte for byte") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crlf = MeetingTitlesFixtures.meetingMarkdown().replacingOccurrences(of: "\n", with: "\r\n")
        let url = MeetingTitlesFixtures.writeMeeting(crlf, named: "crlf.md", in: directory)
        let host = FakeTitlesHost()
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        var results: [MeetingTitlesJobResult] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .fromFile))
        await queue.waitUntilIdle()
        assertEqual(results, [.unreadable])
        assertEqual(host.startCount, 0)
        assertEqual(try? Data(contentsOf: url), Data(crlf.utf8))
        assertTrue(MeetingTitlesController.backfillJobs(in: directory).isEmpty)
    }

    runSuite("A repeated title: reads as the last one, as everywhere in the app") {
        let raw = MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya", extraFrontmatter: ["title: \"Board prep\""])
        let values = TranscriptFrontmatter.values(in: raw) ?? [:]
        assertEqual(values["title"], "Board prep")
        assertEqual(MeetingTitlesTitleOwnership.decide(values: values, rule: .appMade("Meeting with Priya")), .keep)
    }

    await runSuite("Free up space and turning the feature on don't race") {
        let fixture = ControllerFixture(installed: true)
        defer { fixture.tearDown() }
        let controller = fixture.controller
        let gate = RemovalGate()
        let modelDirectory = fixture.store.modelDirectory
        let log = fixture.log
        fixture.removal.set {
            gate.waitUntilReleased()
            try? FileManager.default.removeItem(at: modelDirectory)
            log.append("removed")
            return ModelCacheCleanupResult(removedBytes: 8, removedNames: ["meeting titles model"])
        }
        let removal = Task { @MainActor in try await controller.removeModelWhileOff() }
        while !controller.isRemovingModel { await Task.yield() }
        controller.setEnabled(true)
        assertEqual(fixture.log.entries, [], "the download waits for the removal")
        assertFalse({ if case .downloading = controller.modelStatus { return true }; return false }())
        gate.release()
        let result = try? await removal.value
        assertEqual(result?.removedNames, ["meeting titles model"])
        for _ in 0..<10_000 where fixture.log.entries.count < 2 { await Task.yield() }
        assertEqual(fixture.log.entries, ["removed", "fetch"], "the new download starts only after the removal")
    }

    runSuite("The helper takes the first free port in its range") {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(descriptor, 1)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let taken = Int(UInt16(bigEndian: bound.sin_port))
        assertFalse(MeetingTitlesLlamaServer.portIsFree(taken), "a port another process listens on is skipped")
        assertEqual(MeetingTitlesLlamaServer.defaultPorts.lowerBound, 17_893)
        assertFalse(MeetingTitlesLlamaServer.defaultPorts.contains(17_891), "never Writing's port")
        assertFalse(MeetingTitlesLlamaServer.defaultPorts.contains(17_875), "never Writing preview's port")
    }
}

private let unnamedTurns: [(String, String, String)] = [
    ("00:01", "Mic/You", "Thanks for joining. I wanted to go over the two vendor bids before the contract runs out next month."),
    ("00:09", "System/Speaker 1", "Sure. The current vendor came back about ten percent cheaper over a full year than the new one."),
    ("00:21", "Mic/You", "Support response times were slow last quarter though, so that is the one risk I would flag."),
    ("00:33", "System/Speaker 1", "Okay, so we renew with the current vendor for one year and watch support closely."),
]

/// A controller over temp folders with a fake engine and a fetcher that
/// only logs. Nothing touches real app state.
@MainActor
private final class ControllerFixture {
    let directory = MeetingTitlesFixtures.temporaryDirectory()
    let suite = "meeting-titles-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: MeetingTitlesModelStore
    let host = FakeTitlesHost()
    let log = EventLog()
    let meetings: URL
    let controller: MeetingTitlesController
    /// What Free up space does in the test, set before `removeModelWhileOff`.
    let removal: RemovalBox

    init(installed: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        let models = directory.appendingPathComponent("models", isDirectory: true)
        store = MeetingTitlesModelStore(
            asset: tinyAsset, rootDirectory: models, fetcher: LoggingFetcher(log: log), retryDelays: []
        )
        if installed {
            try? FileManager.default.createDirectory(at: store.modelDirectory, withIntermediateDirectories: true)
            try? Data("GGUF1234".utf8).write(to: store.modelURL)
        }
        meetings = directory.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let meetingsFolder = meetings
        let removal = RemovalBox()
        self.removal = removal
        controller = MeetingTitlesController(
            store: store, host: host, defaults: defaults, meetingsDirectory: { meetingsFolder },
            notificationCenter: NotificationCenter(),
            removeModelFiles: { try removal.run() }
        )
    }

    func meeting(
        _ name: String,
        title: String,
        extra: [String] = [],
        turns: [(String, String, String)] = MeetingTitlesFixtures.defaultTurns
    ) -> URL {
        MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: title, extraFrontmatter: extra, turns: turns), named: name, in: meetings
        )
    }

    func values(_ url: URL) -> [String: String] {
        TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "") ?? [:]
    }

    func tearDown() {
        controller.setEnabled(false)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RemovalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () throws -> ModelCacheCleanupResult)?

    func set(_ action: @escaping @Sendable () throws -> ModelCacheCleanupResult) { lock.withLock { self.action = action } }

    func run() throws -> ModelCacheCleanupResult {
        guard let action = lock.withLock({ action }) else { return .empty }
        return try action()
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var entries: [String] { lock.withLock { items } }
    func append(_ entry: String) { lock.withLock { items.append(entry) } }
}

private final class RemovalGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func waitUntilReleased() { semaphore.wait() }
    func release() { semaphore.signal() }
}

private let tinyAsset = MeetingTitlesModelAsset(
    identifier: "tiny", repository: "example/tiny", revision: "abc", fileName: "tiny.gguf",
    expectedBytes: 8, sha256: String(repeating: "0", count: 64)
)

/// Logs each fetch and fails it, so a started download is visible.
private struct LoggingFetcher: MeetingTitlesModelFetching {
    let log: EventLog

    func fetch(
        _ request: URLRequest,
        onResponse: @escaping @Sendable (Int, [String: String]) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        log.append("fetch")
        throw MeetingTitlesModelFailure.offline
    }
}
