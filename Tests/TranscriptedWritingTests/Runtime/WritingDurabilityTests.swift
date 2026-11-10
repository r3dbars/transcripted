import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime
@testable import TranscriptedKeyboard

@Suite("Closed writing has a durable owner")
struct WritingDurabilityTests {
    private static let start: Int64 = 1_790_350_931_387

    @Test("More than 32 closed entries survive a blocked library and a fresh recorder")
    func outageAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.writing)
        var recorder: WritingDayFileRecorder? = fixture.recorder()
        var last: PersonalHistoryEvent!
        for index in 0..<40 {
            last = Self.event(index)
            #expect(await recorder!.ingest([last]))
            #expect(recorder!.flush())
        }
        #expect(recorder!.lastWriteFailure?.error == .folderUnavailable)
        #expect(try WritingPendingEntryStore.load(in: fixture.pending).entries.count == 40)
        recorder = nil // No flush on destruction: recovery reads only durable state.
        try FileManager.default.removeItem(at: fixture.writing)
        let restarted = fixture.recorder()
        #expect(restarted.flush())
        #expect(restarted.lastWriteFailure == nil)
        #expect(try WritingPendingEntryStore.load(in: fixture.pending).entries.isEmpty)
        #expect(await restarted.ingest([last])) // Lost ACK / resend after restart.
        #expect(restarted.flush())
        let text = try fixture.savedText()
        #expect(text.components(separatedBy: "\nEntry ID:").count - 1 == 40)
        for index in 0..<40 { #expect(text.contains("ordinary writing number \(index)")) }
    }

    @Test("A good day-file save cannot hide an older unresolved failure")
    func partialSuccessKeepsFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.writing, withIntermediateDirectories: true)
        let unreadable = fixture.writing.appendingPathComponent("Writing_2026-09-25.md")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        let recorder = fixture.recorder()
        #expect(await recorder.ingest([Self.event(0)]))
        #expect(recorder.flush())
        #expect(await recorder.ingest([Self.event(1, dayOffset: 1)]))
        #expect(recorder.flush())
        #expect(recorder.lastWriteFailure?.error == .unreadableDayFile)
        #expect(try WritingPendingEntryStore.load(in: fixture.pending).entries.count == 1)
        let goodDay = try WritingDayFileStore.contents(ofDayFile: "Writing_2026-09-26.md", in: fixture.writing)
        #expect(String(decoding: try #require(goodDay), as: UTF8.self).contains("ordinary writing number 1"))
        try FileManager.default.removeItem(at: unreadable)
        #expect(recorder.flush())
        #expect(recorder.lastWriteFailure == nil)
        #expect(try fixture.savedText().contains("ordinary writing number 0"))
    }

    @Test("Refused durable admission leaves the batch retryable and refuses Quit")
    func refusedBatchAndTermination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.pending)
        let recorder = fixture.recorder()
        let ingest = WritingHistoryIngest(dayFiles: recorder, appScope: { .all })
        // Even the ownership store cannot be inspected: do not claim acceptance.
        #expect(!(await ingest.ingest([Self.event(0)])))
        #expect(!recorder.flush(sealForTermination: true))
        try FileManager.default.removeItem(at: fixture.pending)
        #expect(await ingest.ingest([Self.event(0)]))
        // Break the journal AFTER the open entry was accepted in memory.
        try Data().write(to: fixture.pending)
        #expect(!(await ingest.ingest([Self.event(1)])))
        #expect(!recorder.flush(sealForTermination: true))
        try FileManager.default.removeItem(at: fixture.pending)
        #expect(await ingest.ingest([Self.event(1)]))
        #expect(recorder.flush(sealForTermination: true))
        #expect(!(await ingest.ingest([Self.event(2)])))
        #expect(try fixture.savedText().components(separatedBy: "\nEntry ID:").count - 1 == 2)
    }

    @Test("Capacity refusal never silently truncates pending entries")
    func boundedBackpressure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.writing)
        let recorder = fixture.recorder()
        for index in 0..<WritingPendingEntryStore.maximumEntries {
            #expect(await recorder.ingest([Self.event(index)]))
            #expect(recorder.flush())
        }
        #expect(await recorder.ingest([Self.event(256)]))
        #expect(!recorder.flush(sealForTermination: true))
        #expect(!(await recorder.ingest([Self.event(257)])))
        #expect(recorder.lastWriteFailure?.error == .pendingStoreFull)
        #expect(try WritingPendingEntryStore.load(in: fixture.pending).entries.count == 256)
        try FileManager.default.removeItem(at: fixture.writing)
        #expect(recorder.flush())
        #expect(await recorder.ingest([Self.event(257)]))
        #expect(recorder.flush())
        #expect(try fixture.savedText().components(separatedBy: "\nEntry ID:").count - 1 == 258)
    }

    @Test("Replay is idempotent if publication succeeded but journal retirement did not")
    func publicationReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.writing)
        let recorder = fixture.recorder()
        #expect(await recorder.ingest([Self.event(0)]))
        #expect(recorder.flush())
        let snapshot = try WritingPendingEntryStore.load(in: fixture.pending)
        try FileManager.default.removeItem(at: fixture.writing)
        #expect(recorder.flush())
        // Simulate the durable pre-retirement journal left by process death.
        try WritingPendingEntryStore.save(snapshot, in: fixture.pending)
        #expect(fixture.recorder().flush())
        #expect(try fixture.savedText().components(separatedBy: "\nEntry ID:").count - 1 == 1)
    }

    @Test("Published ownership followed by a reported sync failure cannot lose later same-session text")
    func uncertainPublicationKeepsSuffix() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fail = FailOnce()
        let recorder = fixture.recorder(savePending: { snapshot, directory in
            try WritingPendingEntryStore.save(snapshot, in: directory)
            if fail.take() { throw WritingDayFileStore.StoreError.pendingStoreUnavailable }
        })
        let first = try #require(PersonalHistoryEvent(id: "first", timestampMilliseconds: Self.start,
            historyIdentifier: "history", consentIdentifier: "consent", sessionIdentifier: "same-session",
            appBundleIdentifier: "com.example.editor", source: .typed, text: "original text"))
        let suffix = try #require(PersonalHistoryEvent(id: "suffix", timestampMilliseconds: Self.start + 3_000,
            historyIdentifier: "history", consentIdentifier: "consent", sessionIdentifier: "same-session",
            appBundleIdentifier: "com.example.editor", source: .typed, text: "later suffix"))
        #expect(await recorder.ingest([first]))
        #expect(!recorder.flush()) // Real atomic publication happened before the injected failure.
        #expect(try WritingPendingEntryStore.load(in: fixture.pending).entries.count == 1)
        #expect(await recorder.ingest([suffix]))
        #expect(recorder.flush())
        let saved = try fixture.savedText()
        #expect(saved.components(separatedBy: "\nEntry ID:").count - 1 == 2)
        #expect(saved.components(separatedBy: "original text").count - 1 == 2) // Heading + body once.
        #expect(saved.contains("later suffix"))
    }

    @Test("Uncertain publication completes the close without losing split-secret scrubber context")
    func uncertainPublicationPreservesSecretContext() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fail = FailOnce()
        let recorder = fixture.recorder(savePending: { snapshot, directory in
            try WritingPendingEntryStore.save(snapshot, in: directory)
            if fail.take() { throw WritingDayFileStore.StoreError.pendingStoreUnavailable }
        })
        func event(_ id: String, _ text: String, _ offset: Int64) throws -> PersonalHistoryEvent {
            try #require(PersonalHistoryEvent(id: id, timestampMilliseconds: Self.start + offset,
                historyIdentifier: "history", consentIdentifier: "consent", sessionIdentifier: id,
                appBundleIdentifier: "com.apple.Terminal", source: .typed, text: text))
        }
        let command = try event("command", "sudo apt update", 0)
        let password = try event("password", "sunshine", 2_000)
        #expect(await recorder.ingest([command]))
        #expect(!(await recorder.ingest([password])))
        #expect(await recorder.ingest([password]))
        #expect(recorder.flush())
        let saved = try fixture.savedText()
        #expect(saved.contains("sudo apt update"))
        #expect(!saved.contains("sunshine"))
        #expect(saved.contains("redacted"))
    }

    @Test("Consent, scope, opt-out and Delete all cannot replay private pending writing")
    func privacyErase() async throws {
        for change in 0..<4 {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try Data().write(to: fixture.writing)
            let recorder = fixture.recorder()
            #expect(await recorder.ingest([Self.event(0)]))
            #expect(recorder.flush())
            switch change {
            case 0: fixture.gate.value.consentIdentifier = "new-consent"
            case 1: fixture.gate.value.appScope = .picked(["com.example.other"])
            case 2: fixture.gate.value.enabled = false
            default:
                // The library is unavailable, so Delete all reports incomplete,
                // but still erases its separately reachable pending ownership.
                #expect(!recorder.deleteAll())
            }
            if change != 3 { #expect(recorder.reconcilePrivacy()) }
            try FileManager.default.removeItem(at: fixture.writing)
            #expect(fixture.recorder().flush())
            #expect(try fixture.savedText().isEmpty)
        }
    }

    @Test("Open raw text never reaches the journal; closed entries are scrubbed and owner-only")
    func privateScrubbedJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.writing)
        let recorder = fixture.recorder()
        #expect(await recorder.ingest([Self.event(0, text: "the wifi password is sunshine")]))
        #expect(!FileManager.default.fileExists(atPath: fixture.pending.appendingPathComponent(WritingPendingEntryStore.fileName).path))
        #expect(recorder.flush())
        let file = fixture.pending.appendingPathComponent(WritingPendingEntryStore.fileName)
        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(!json.contains("sunshine"))
        #expect(json.contains("redacted"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: fixture.pending.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("Retryable storage rejection survives more than 12 keyboard attempts and then saves once")
    func producerBackpressure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.pending)
        let recorder = fixture.recorder()
        let ingest = WritingHistoryIngest(dayFiles: recorder, appScope: { .all })
        let suite = "writing-durability-producer-\(UUID().uuidString)"
        let defaults = WritingTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PersonalHistorySettingsContract.enabledKey)
        defaults.set("history", forKey: PersonalHistorySettingsContract.historyIdentifierKey)
        defaults.set("consent", forKey: PersonalHistorySettingsContract.consentIdentifierKey)
        let attempts = Attempts()
        let capture = PersonalHistoryCapture(defaults: defaults,
            flushScheduler: .neverOnItsOwn,
            sender: { events in
                let response = await GhostBrainServerHost.personalHistoryResponse(events, ingest: ingest)
                await attempts.record(events.map(\.id), response: response)
                return response
            })
        let permit = try #require(capture.permit(appBundleIdentifier: "com.example.editor", secureInput: false))
        capture.record(text: "ordinary producer writing", source: .typed, sessionIdentifier: "producer", permit: permit)
        for _ in 0..<PersonalHistoryCapture.maximumRefusedAttempts + 2 { await capture.flushAndWait() }
        let rejected = await attempts.responses
        #expect(rejected.count == PersonalHistoryCapture.maximumRefusedAttempts + 2)
        #expect(rejected.allSatisfy { $0 == .unavailable })
        try FileManager.default.removeItem(at: fixture.pending)
        await capture.flushAndWait()
        #expect(await attempts.responses.last == .recorded)
        #expect(recorder.flush())
        #expect(try fixture.savedText().components(separatedBy: "ordinary producer writing").count - 1 == 2)
        let count = await attempts.responses.count
        await capture.flushAndWait()
        #expect(await attempts.responses.count == count)
    }

    @Test("An opt-out queued without a runtime erases old recovery before a quick re-enable")
    func stoppedPrivacyOrdering() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.writing)
        var recorder: WritingDayFileRecorder? = fixture.recorder()
        #expect(await recorder!.ingest([Self.event(0)]))
        #expect(recorder!.flush())
        recorder = nil
        // Interrupted writes are private recovery too; unrelated files stay.
        let stale = fixture.pending.appendingPathComponent(".pending-writing-interrupted.tmp")
        let handle = try #require(SecureLocalStorage.openFileForAppending(at: stale))
        try handle.write(contentsOf: Data("scrubbed old snapshot".utf8))
        try handle.close()
        let unrelated = fixture.pending.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        var off = fixture.gate.value
        off.enabled = false
        WritingDayFileRecorder.reconcileStoredPrivacy(in: fixture.pending, gate: off)
        let fresh = fixture.recorder()
        #expect(await fresh.ingest([Self.event(1)]))
        #expect(fresh.flush())
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        try FileManager.default.removeItem(at: fixture.writing)
        #expect(fixture.recorder().flush())
        let saved = try fixture.savedText()
        #expect(!saved.contains("ordinary writing number 0"))
        #expect(saved.contains("ordinary writing number 1"))
        #expect(await WritingDayFileRecorder.deleteStoredWriting(in: fixture.writing, pendingDirectory: fixture.pending))
        #expect(fixture.recorder().flush())
        #expect(try fixture.savedText().isEmpty)
        // Privacy erase must work when only an interrupted snapshot exists.
        let orphan = try #require(SecureLocalStorage.openFileForAppending(at: stale))
        try orphan.write(contentsOf: Data("old snapshot without final journal".utf8))
        try orphan.close()
        WritingDayFileRecorder.reconcileStoredPrivacy(in: fixture.pending, gate: off)
        #expect(await fixture.recorder().ingest([Self.event(2)])) // Shared owner queue barrier.
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Recovery refuses symlinks and corrupt journals without overwriting them")
    func refusesUntrustedStore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.pending, withDestinationURL: outside)
        #expect(!(await fixture.recorder().ingest([Self.event(0)])))
        #expect(!WritingPendingEntryStore.delete(in: fixture.pending))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: fixture.pending)
        #expect(SecureLocalStorage.ensureOwnerOnlyDirectory(at: fixture.pending))
        let file = fixture.pending.appendingPathComponent(WritingPendingEntryStore.fileName)
        let handle = try #require(SecureLocalStorage.openFileForAppending(at: file))
        try handle.write(contentsOf: Data("not valid JSON".utf8))
        try handle.close()
        #expect(!(await fixture.recorder().ingest([Self.event(0)])))
        #expect(try String(contentsOf: file, encoding: .utf8) == "not valid JSON")
    }

    private actor Attempts {
        private(set) var responses: [GhostBrainResponse] = []
        func record(_ ids: [String], response: GhostBrainResponse) { responses.append(response) }
    }

    private static func event(_ index: Int, dayOffset: Int64 = 0, text: String? = nil) -> PersonalHistoryEvent {
        PersonalHistoryEvent(id: "event-\(index)", timestampMilliseconds: start + Int64(index) * 3_000 + dayOffset * 86_400_000,
            historyIdentifier: "history", consentIdentifier: "consent", sessionIdentifier: "segment-\(index)",
            appBundleIdentifier: "com.example.editor", source: .typed, text: text ?? "ordinary writing number \(index)")!
    }

    private struct Fixture {
        let root: URL
        let gate = GateBox()
        var writing: URL { root.appendingPathComponent("writing") }
        var pending: URL { root.appendingPathComponent("pending") }
        init() throws {
            root = WritingDayFileStore.resolved(FileManager.default.temporaryDirectory)
                .appendingPathComponent("writing-durability-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func recorder(savePending: @escaping @Sendable (WritingPendingEntryStore.Snapshot, URL) throws -> Void = {
            try WritingPendingEntryStore.save($0, in: $1)
        }) -> WritingDayFileRecorder {
            let writing = writing, pending = pending, gate = gate
            return WritingDayFileRecorder(directory: { writing }, pendingDirectory: { pending }, savePending: savePending, gate: { gate.value },
                appName: { _ in "Editor" }, now: { Date(timeIntervalSince1970: Double(WritingDurabilityTests.start) / 1_000) },
                timeZone: { TimeZone(identifier: "America/Chicago")! }, entryIDSuffix: { "0000abcd" })
        }
        func savedText() throws -> String {
            try WritingDayFileStore.dayFileNames(in: writing).map {
                String(decoding: try WritingDayFileStore.contents(ofDayFile: $0, in: writing) ?? Data(), as: UTF8.self)
            }.joined(separator: "\n")
        }
    }

    private final class FailOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var available = true
        func take() -> Bool { lock.withLock { defer { available = false }; return available } }
    }

    private final class GateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = WritingDayFileRecorder.Gate(enabled: true, historyIdentifier: "history", consentIdentifier: "consent")
        var value: WritingDayFileRecorder.Gate {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}

private extension PersonalHistoryCapture.FlushScheduler {
    /// Only `flushAndWait()` sends, so the test counts exactly the attempts
    /// it asked for. The real 5 s retry timer fired between flushes on a
    /// loaded CI runner and added attempts.
    static let neverOnItsOwn = Self { _, _, _ in }
}
