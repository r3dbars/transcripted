import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// Keyboard batches go through Save my writing (`WritingHistoryIngest` ->
/// `WritingDayFileRecorder` -> `PersonalHistoryRelay`) before Personal History
/// (the encrypted log and the next-word predictor) sees them. These tests
/// drive that whole path the way the app wires it and check what the log
/// stores and what the predictor would serve.
@Suite("Personal History gets only closed, secret-free writing")
struct PersonalHistorySecretTests {
    private static let start: Int64 = 1_790_350_931_387
    private static let terminal = "com.apple.Terminal"
    private static let slack = "com.tinyspeck.slackmacgap"
    /// Letter runs "Tr", "ub", "dor": a predictor that saw it twice serves
    /// "dor" after "Tr ub".
    private static let password = "Tr0ub4dor&3"
    private static let passwordParts = ["Tr0", "0ub", "ub4", "4dor", "dor&", "&3"]

    // MARK: - Promise 1: a sudo password in Terminal is never stored or predicted

    @Test("A password typed after sudo in Terminal is never stored in the Personal History log and never predicted")
    func terminalSudoPasswordNeverReachesHistory() async throws {
        // Control: fed straight to a controller, this exact typing teaches the
        // predictor the password. Without this the nil checks below prove nothing.
        let control = History()
        #expect(await settledStatus(control.controller).phase == .ready)
        for event in Self.sudoThenPasswordTwice() {
            #expect(await control.controller.ingest([event]))
        }
        #expect(await control.controller.personalNextWordPrediction(
            afterTailWords: ["Tr", "ub"], appBundleIdentifier: Self.terminal
        )?.word == "dor")

        let history = History()
        #expect(await settledStatus(history.controller).phase == .ready)
        let pipeline = try Pipeline(personalHistory: history.controller)
        defer { pipeline.remove() }

        for event in Self.sudoThenPasswordTwice() {
            #expect(await pipeline.send([event]))
        }
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        let stored = await history.store.events.map(\.text)
        for part in Self.passwordParts {
            #expect(!stored.contains { $0.contains(part) }, "stored text holds \(part)")
        }
        // The command itself isn't a secret and still reaches the log.
        #expect(stored.filter { $0 == "sudo apt update" }.count == 2)
        #expect(await history.controller.personalNextWordPrediction(
            afterTailWords: ["Tr", "ub"], appBundleIdentifier: Self.terminal
        ) == nil)
        #expect(await history.controller.personalNextWordPrediction(
            afterTailWords: ["Tr"], appBundleIdentifier: Self.terminal
        ) == nil)
    }

    @Test("A dictionary-word password typed after sudo in Terminal is never stored in the Personal History log")
    func terminalSudoWordPasswordNeverStored() async throws {
        let history = History()
        #expect(await settledStatus(history.controller).phase == .ready)
        let pipeline = try Pipeline(personalHistory: history.controller)
        defer { pipeline.remove() }

        #expect(await pipeline.send([Self.typed("sudo apt update", session: "t-1", app: Self.terminal, at: Self.start)]))
        #expect(await pipeline.send([Self.typed("sunshine", session: "t-2", app: Self.terminal, at: Self.start + 2_000)]))
        #expect(await pipeline.send([Self.typed("ls -la", session: "t-3", app: Self.terminal, at: Self.start + 9_000)]))
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        let stored = await history.store.events.map(\.text)
        #expect(!stored.contains { $0.contains("sunshine") })
        #expect(stored.contains("sudo apt update"))
    }

    // MARK: - Promise 2: ordinary writing is still stored and learned

    @Test("Ordinary writing still reaches the Personal History log and is learned")
    func ordinaryWritingStillLearned() async throws {
        let history = History()
        #expect(await settledStatus(history.controller).phase == .ready)
        let pipeline = try Pipeline(personalHistory: history.controller)
        defer { pipeline.remove() }

        // The space after the last word is what makes it a finished word.
        let phrase = "see you at the standup tomorrow "
        #expect(await pipeline.send([Self.typed(phrase, session: "s-1", at: Self.start)]))
        #expect(await pipeline.send([Self.typed(phrase, session: "s-2", at: Self.start + 30_000)]))
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        #expect(await history.store.events.map(\.text) == [phrase, phrase])
        #expect(await history.controller.personalNextWordPrediction(
            afterTailWords: ["the", "standup"], appBundleIdentifier: Self.slack
        )?.word == "tomorrow")
    }

    // MARK: - Promise 3: a secret removed with Backspace still never goes

    @Test("A secret typed and then removed with Backspace never reaches the Personal History log or the predictor")
    func backspacedSecretNeverReachesHistory() async throws {
        let history = History()
        #expect(await settledStatus(history.controller).phase == .ready)
        let pipeline = try Pipeline(personalHistory: history.controller)
        defer { pipeline.remove() }

        // Typed into the wrong field twice, noticed, erased, then a message.
        for (index, root) in ["wrong-a", "wrong-b"].enumerated() {
            let at = Self.start + Int64(index) * 20_000
            let continued = PersonalHistorySegmentChain.continuation(of: root)
            #expect(await pipeline.send([
                Self.typed(Self.password + " ", session: root, at: at),
                try Self.deletion(Self.password.utf16.count + 1, session: continued, at: at + 1_000),
                Self.typed("see you at lunch", session: continued, at: at + 2_000),
            ]))
        }
        // A clean entry after them shows the path is live in this test.
        #expect(await pipeline.send([Self.typed("sounds good to me", session: "clean", at: Self.start + 60_000)]))
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        // What was left after Backspace was clean and is saved to the day file.
        let saved = try pipeline.dayFileText()
        #expect(saved.contains("see you at lunch"))
        #expect(!saved.contains(Self.password))

        let stored = await history.store.events
        #expect(stored.map(\.text) == ["sounds good to me"])
        #expect(await history.controller.personalNextWordPrediction(
            afterTailWords: ["Tr"], appBundleIdentifier: Self.slack
        ) == nil)
        #expect(await history.controller.personalNextWordPrediction(
            afterTailWords: ["Tr", "ub"], appBundleIdentifier: Self.slack
        ) == nil)
    }

    @Test("A card number erased with Backspace keeps its whole entry out of Personal History while the clean text is saved")
    func backspacedCardKeepsEntryOut() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        #expect(await pipeline.send([
            Self.typed("my card is ", session: "card", at: Self.start),
            Self.typed("4111 ", session: "card", at: Self.start + 500),
            Self.typed("1111 ", session: "card", at: Self.start + 1_000),
            Self.typed("1111 ", session: "card", at: Self.start + 1_500),
            Self.typed("1111", session: "card", at: Self.start + 2_000),
            try Self.deletion(19, session: "card_1", at: Self.start + 3_000),
            Self.typed("on file", session: "card_1", at: Self.start + 4_000),
        ]))
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        #expect(try pipeline.dayFileText().contains("my card is on file"))
        #expect(await spy.events.isEmpty)
    }

    // MARK: - Promise 4: nothing goes while the entry is open

    @Test("Nothing reaches Personal History while its entry is open; the next segment chain closes it and it arrives")
    func openEntryHeldUntilNextChain() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        let first = [
            Self.typed("the launch moves ", session: "a", at: Self.start),
            Self.typed("to Thursday", session: "a", at: Self.start + 1_000),
        ]
        #expect(await pipeline.send(first))
        await pipeline.relay.drain()
        #expect(await spy.events.isEmpty)

        let second = Self.typed("Another message entirely", session: "b", at: Self.start + 5_000)
        #expect(await pipeline.send([second]))
        await pipeline.relay.drain()
        #expect(await spy.events.map(\.id) == first.map(\.id))
    }

    @Test("An entry idle for 2 minutes reaches Personal History at the idle sweep, not before")
    func idleEntryArrivesAtSweep() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        let event = Self.typed("checking in on the draft", session: "a", at: Self.start)
        #expect(await pipeline.send([event]))
        pipeline.clock.now = Self.start + 60_000
        pipeline.recorder.closeIdleEntries()
        await pipeline.relay.drain()
        #expect(await spy.events.isEmpty)

        pipeline.clock.now = Self.start + 200 + 120_001
        pipeline.recorder.closeIdleEntries()
        await pipeline.relay.drain()
        #expect(await spy.events.map(\.id) == [event.id])
    }

    @Test("The open entry reaches Personal History on flush at quit")
    func flushReleasesOpenEntry() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        let event = Self.typed("last words before quitting", session: "a", at: Self.start)
        #expect(await pipeline.send([event]))
        await pipeline.relay.drain()
        #expect(await spy.events.isEmpty)
        pipeline.recorder.flush()
        await pipeline.relay.drain()
        #expect(await spy.events.map(\.id) == [event.id])
    }

    // MARK: - Promise 5: Save my writing off or Delete all drops the open entry

    @Test("Turning Save my writing off while an entry is open means it never reaches Personal History")
    func turningOffDropsOpenEntry() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        #expect(await pipeline.send([Self.typed("typed before turning it off", session: "a", at: Self.start)]))
        pipeline.gate.value.enabled = false
        _ = await pipeline.send([Self.typed("typed while off", session: "b", at: Self.start + 5_000)])
        pipeline.gate.value.enabled = true
        pipeline.recorder.flush()
        await pipeline.relay.drain()
        #expect(await spy.events.isEmpty)
    }

    @Test("Turning Save my writing off and then quitting never sends the open entry to Personal History")
    func turningOffThenFlushDropsOpenEntry() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        #expect(await pipeline.send([Self.typed("typed before turning it off", session: "a", at: Self.start)]))
        pipeline.gate.value.enabled = false
        pipeline.recorder.flush()
        await pipeline.relay.drain()
        #expect(await spy.events.isEmpty)
    }

    @Test("Delete all while an entry is open means it never reaches Personal History")
    func deleteAllDropsOpenEntry() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        #expect(await pipeline.send([Self.typed("typed before delete all", session: "a", at: Self.start)]))
        #expect(pipeline.recorder.deleteAll())
        pipeline.recorder.flush()
        await pipeline.relay.drain()
        #expect(await spy.events.isEmpty)
    }

    // MARK: - Promise 6: a retried batch goes once

    @Test("A batch the keyboard retries reaches Personal History once")
    func retriedBatchArrivesOnce() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        let first = [
            Self.typed("first part of a note ", session: "a", at: Self.start),
            Self.typed("and the rest of it", session: "a", at: Self.start + 500),
        ]
        #expect(await pipeline.send(first))
        #expect(await pipeline.send(first))
        let second = [Self.typed("a second note here", session: "b", at: Self.start + 5_000)]
        #expect(await pipeline.send(second))
        // A retry that lands after its entry already closed.
        #expect(await pipeline.send(first))
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        #expect(await spy.events.map(\.id) == (first + second).map(\.id))
    }

    // MARK: - Promise 7: a long entry all arrives, in order, in valid batches

    @Test("A long entry all reaches Personal History in keyboard order, in batches the controller accepts")
    func longEntryArrivesInValidBatches() async throws {
        let spy = HistorySpy()
        let pipeline = try Pipeline(personalHistory: spy)
        defer { pipeline.remove() }

        let typed = Self.longEntry()
        #expect(typed.count > PersonalHistoryEvent.maximumBatchEvents)
        #expect(typed.map(\.text.count).reduce(0, +) > PersonalHistoryEvent.maximumBatchTextCharacters)
        for batch in Self.keyboardBatches(typed) {
            #expect(await pipeline.send(batch))
        }
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        let batches = await spy.batches
        #expect(batches.count > 1)
        #expect(batches.allSatisfy { PersonalHistoryEvent.validBatch($0) })
        #expect(batches.flatMap { $0 }.map(\.id) == typed.map(\.id))
    }

    @Test("A long entry is stored whole and in keyboard order by the real Personal History controller")
    func longEntryStoredWhole() async throws {
        let history = History()
        #expect(await settledStatus(history.controller).phase == .ready)
        let pipeline = try Pipeline(personalHistory: history.controller)
        defer { pipeline.remove() }

        let typed = Self.longEntry()
        for batch in Self.keyboardBatches(typed) {
            #expect(await pipeline.send(batch))
        }
        pipeline.recorder.flush()
        await pipeline.relay.drain()

        #expect(await history.store.events.map(\.id) == typed.map(\.id))
    }

    // MARK: - Keyboard input

    /// `sudo apt update`, Return, the password about 2 s later, Return; again
    /// two minutes later. (A command typed within a minute of the password
    /// folds into the password's entry and is held back with it.)
    private static func sudoThenPasswordTwice() -> [PersonalHistoryEvent] {
        [
            typed("sudo apt update", session: "term-1", app: terminal, at: start),
            typed(password, session: "term-2", app: terminal, at: start + 2_000),
            typed("sudo apt update", session: "term-3", app: terminal, at: start + 120_000),
            typed(password, session: "term-4", app: terminal, at: start + 122_000),
        ]
    }

    /// 26 events in one segment: some near the 512-character event limit.
    private static func longEntry() -> [PersonalHistoryEvent] {
        let long = String(repeating: "we should ship the report on friday ", count: 14)
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        return (0..<26).map { index in
            let text = index % 5 == 0 ? long : "\(words[index % words.count]) goes next "
            return typed(text, session: "long", at: start + Int64(index) * 1_000)
        }
    }

    /// Splits events the way the keyboard does: the longest valid prefix each time.
    private static func keyboardBatches(_ events: [PersonalHistoryEvent]) -> [[PersonalHistoryEvent]] {
        var batches: [[PersonalHistoryEvent]] = []
        var current: [PersonalHistoryEvent] = []
        for event in events {
            if !current.isEmpty && !PersonalHistoryEvent.validBatch(current + [event]) {
                batches.append(current)
                current = []
            }
            current.append(event)
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private static func typed(
        _ text: String,
        session: String,
        app: String = slack,
        at timestamp: Int64
    ) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            id: UUID().uuidString,
            timestampMilliseconds: timestamp,
            historyIdentifier: History.historyIdentifier,
            consentIdentifier: History.consentIdentifier,
            sessionIdentifier: session,
            appBundleIdentifier: app,
            source: .typed,
            text: text
        )!
    }

    private static func deletion(_ count: Int, session: String, app: String = slack, at timestamp: Int64) throws -> PersonalHistoryEvent {
        try #require(PersonalHistoryEvent(
            deletionID: UUID().uuidString,
            timestampMilliseconds: timestamp,
            historyIdentifier: History.historyIdentifier,
            consentIdentifier: History.consentIdentifier,
            sessionIdentifier: session,
            appBundleIdentifier: app,
            deletedCharacters: count
        ))
    }

    private func settledStatus(
        _ controller: PersonalHistoryController
    ) async -> PersonalNextWordShadowStatus {
        for _ in 0..<100 {
            let status = await controller.nextWordStatus()
            if status.phase == .ready || status.phase == .unavailable { return status }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await controller.nextWordStatus()
    }

    // MARK: - The app's wiring, with a temp folder and a test clock

    /// `WritingDayFileWriter` + `WritingHistoryIngest` as the app builds them.
    private final class Pipeline: @unchecked Sendable {
        let root: URL
        let writing: URL
        let clock: Clock
        let gate: GateBox
        let relay: PersonalHistoryRelay
        let recorder: WritingDayFileRecorder
        let ingest: WritingHistoryIngest

        init(personalHistory: any PersonalHistoryIngesting) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcripted-history-secret-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let writing = root.appendingPathComponent("writing", isDirectory: true)
            self.writing = writing
            let clock = Clock(PersonalHistorySecretTests.start)
            self.clock = clock
            let gate = GateBox(.init(
                enabled: true,
                historyIdentifier: History.historyIdentifier,
                consentIdentifier: History.consentIdentifier
            ))
            self.gate = gate
            let relay = PersonalHistoryRelay(personalHistory: personalHistory)
            self.relay = relay
            recorder = WritingDayFileRecorder(
                directory: { writing },
                gate: { gate.value },
                appName: { _ in "App" },
                now: { Date(timeIntervalSince1970: TimeInterval(clock.now) / 1_000) },
                timeZone: { TimeZone(identifier: "America/Chicago")! },
                locale: Locale(identifier: "en_US"),
                entryIDSuffix: { "0000abcd" },
                releaseToPersonalHistory: { relay.send($0) }
            )
            ingest = WritingHistoryIngest(dayFiles: recorder, appScope: { .all })
        }

        /// One keyboard batch, arriving 200 ms after its last key.
        func send(_ events: [PersonalHistoryEvent]) async -> Bool {
            if let last = events.map(\.timestampMilliseconds).max() {
                clock.now = last + 200
            }
            return await ingest.ingest(events)
        }

        func dayFileText() throws -> String {
            let names = try FileManager.default.contentsOfDirectory(atPath: writing.path).sorted()
            return try names.map {
                try String(contentsOf: writing.appendingPathComponent($0), encoding: .utf8)
            }.joined(separator: "\n")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Records what reaches Personal History and accepts only what the real
    /// controller would: a valid batch.
    private actor HistorySpy: PersonalHistoryIngesting {
        private(set) var batches: [[PersonalHistoryEvent]] = []
        var events: [PersonalHistoryEvent] { batches.flatMap { $0 } }

        func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
            batches.append(events)
            return PersonalHistoryEvent.validBatch(events)
        }
    }

    /// The real controller over an in-memory store, Personal History on.
    private struct History {
        static let historyIdentifier = "history"
        static let consentIdentifier = "consent"

        let store = MemoryStore()
        let controller: PersonalHistoryController

        init() {
            let name = "transcripted.tests.history-secret.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            defaults.set(Self.historyIdentifier, forKey: PersonalHistorySettingsContract.historyIdentifierKey)
            defaults.set(Self.consentIdentifier, forKey: PersonalHistorySettingsContract.consentIdentifierKey)
            defaults.set("experiment", forKey: "PersonalNextWordExperimentIdentifier")
            defaults.set(true, forKey: PersonalHistorySettingsContract.enabledKey)
            defaults.set([String](), forKey: PersonalHistorySettingsContract.excludedAppsKey)
            controller = PersonalHistoryController(
                store: store,
                settings: TildeSettings(keyboard: defaults),
                modelPersistenceInterval: 0
            )
        }
    }

    private actor MemoryStore: PersonalHistoryStore {
        nonisolated let location = URL(fileURLWithPath: "/tmp/transcripted-history-secret-test")
        private var records: [PersonalHistoryRecord] = []
        private var checkpoint: PersonalNextWordStoredCheckpoint?
        private var trainedModel: PersonalNextWordStoredModel?
        var events: [PersonalHistoryEvent] { records.flatMap(\.events) }

        @discardableResult
        func append(
            _ events: [PersonalHistoryEvent],
            checkpoint: PersonalNextWordStoredCheckpoint?
        ) async throws -> Int64 {
            let sequence = Int64(records.count + 1)
            records.append(PersonalHistoryRecord(sequence: sequence, events: events))
            if let checkpoint { self.checkpoint = checkpoint }
            return sequence
        }

        func loadReplay(maximumBytes: Int64) async throws -> PersonalHistoryReplay {
            PersonalHistoryReplay(records: records, checkpoint: checkpoint, trainedModel: trainedModel)
        }

        func saveTrainedModel(_ model: PersonalNextWordStoredModel) async throws {
            trainedModel = model
        }

        func deleteAll() async throws {
            records = []
            checkpoint = nil
            trainedModel = nil
        }

        func summary() async throws -> PersonalHistorySummary {
            PersonalHistorySummary(location: location, approximateBytes: Int64(events.count))
        }
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
