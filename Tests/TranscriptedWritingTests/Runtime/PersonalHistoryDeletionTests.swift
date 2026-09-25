import Foundation
import Testing
@testable import TranscriptedKeyboard
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// Transcripted phase 3: Backspace tracking for Save my writing. The wire
/// event, the keyboard's tracker and segment chain, and the rule that
/// Tilde's learning and encrypted log never see a deletion.
@Suite("Personal History deletions")
struct PersonalHistoryDeletionTests {
    @Test("A deletion travels as a text-free version 2 event")
    func deletionWireEvent() throws {
        let deletion = try #require(Self.deletion(3))
        #expect(deletion.v == PersonalHistoryEvent.deletionVersion)
        #expect(deletion.source == .deletion)
        #expect(deletion.text.isEmpty)
        #expect(deletion.deletedCharacters == 3)

        let data = try JSONEncoder().encode(deletion)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 2)
        #expect(object["source"] as? String == "deletion")
        #expect(object["text"] as? String == "")
        #expect(object["deletedCharacters"] as? Int == 3)
        #expect(try JSONDecoder().decode(PersonalHistoryEvent.self, from: data) == deletion)

        let request = GhostBrainRequest(personalHistoryEvents: [Self.typed("teh"), deletion])
        let decoded = try JSONDecoder().decode(GhostBrainRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.personalHistoryEvents == [Self.typed("teh"), deletion])
        #expect(PersonalHistoryEvent.validBatch([Self.typed("teh"), deletion]))
    }

    @Test("Typed and accepted text keep Tilde's version 1 wire shape")
    func typedEventsUnchanged() throws {
        let typed = Self.typed("hello")
        #expect(typed.v == 1)
        #expect(typed.deletedCharacters == nil)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as? [String: Any]
        )
        #expect(object["deletedCharacters"] == nil)
        #expect(Set(object.keys) == [
            "v", "id", "timestampMilliseconds", "historyIdentifier", "consentIdentifier",
            "sessionIdentifier", "appBundleIdentifier", "source", "text",
        ])
    }

    @Test("Malformed deletions fail closed")
    func malformedDeletions() throws {
        #expect(Self.deletion(0) == nil)
        #expect(Self.deletion(PersonalHistoryEvent.maximumDeletedCharacters + 1) == nil)
        #expect(PersonalHistoryEvent(
            id: "event",
            timestampMilliseconds: 1,
            historyIdentifier: "history",
            sessionIdentifier: "segment",
            appBundleIdentifier: "com.example.Editor",
            source: .deletion,
            text: "x"
        ) == nil)

        let valid = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try #require(Self.deletion(2)))
        ) as? [String: Any] ?? [:]
        func decodes(_ changes: [String: Any?]) -> Bool {
            var object = valid
            for (key, value) in changes { object[key] = value }
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            return (try? JSONDecoder().decode(PersonalHistoryEvent.self, from: data)) != nil
        }
        #expect(decodes([:]))
        #expect(!decodes(["v": 1]))
        #expect(!decodes(["source": "typed"]))
        #expect(!decodes(["text": "secret"]))
        #expect(!decodes(["deletedCharacters": nil]))
        #expect(!decodes(["deletedCharacters": 0]))
        #expect(!decodes(["v": 3]))
    }

    @Test("Queued deletions in one segment coalesce into one count")
    func deletionsCoalesce() throws {
        let first = try #require(Self.deletion(1, id: "first"))
        let second = try #require(Self.deletion(2, id: "second"))
        let combined = try #require(first.coalescingDeletion(with: second))
        #expect(combined.id == "first")
        #expect(combined.deletedCharacters == 3)
        #expect(first.coalescingDeletion(with: try #require(Self.deletion(1, session: "other"))) == nil)
        #expect(first.coalescingDeletion(with: Self.typed("x")) == nil)
        #expect(Self.typed("x").coalescing(with: first) == nil)
    }

    @Test("The keyboard queues typing and deletions in order, merging repeats")
    func keyboardQueuesDeletions() async throws {
        let fixture = CaptureFixture()
        let permit = try #require(fixture.capture.permit(appBundleIdentifier: "com.example.Editor", secureInput: false))
        fixture.capture.record(text: "teh", source: .typed, sessionIdentifier: "chain", permit: permit)
        fixture.capture.recordDeletion(characters: 1, sessionIdentifier: "chain_1", permit: permit)
        fixture.capture.recordDeletion(characters: 1, sessionIdentifier: "chain_1", permit: permit)
        fixture.capture.record(text: "he", source: .typed, sessionIdentifier: "chain_1", permit: permit)
        await fixture.capture.flushAndWait()

        let events = await fixture.sink.events
        #expect(events.map(\.source) == [.typed, .deletion, .typed])
        #expect(events.map(\.text) == ["teh", "", "he"])
        #expect(events[1].deletedCharacters == 2)
        #expect(events[1].sessionIdentifier == "chain_1")
    }

    @Test("Segment chains: a new segment for the predictor, the same chain for the day file")
    func segmentChain() {
        let root = UUID().uuidString
        let next = PersonalHistorySegmentChain.continuation(of: root)
        #expect(next == root + "_1")
        #expect(PersonalHistorySegmentChain.continuation(of: next) == root + "_2")
        #expect(PersonalHistorySegmentChain.root(of: next) == Substring(root))
        #expect(PersonalHistorySegmentChain.sameChain(root, next))
        #expect(!PersonalHistorySegmentChain.sameChain(root, UUID().uuidString))
        #expect(PersonalHistoryEvent.validIdentifier(next))
    }

    @Test("The tracker reports only the keyboard's own text, one character per Backspace")
    func tracker() throws {
        var tracker = PersonalHistoryDeletionTracker()
        // Swift Testing's macros can't call a mutating method, so each
        // Backspace lands in a local first.
        var result = tracker.backspace()
        #expect(result == nil)

        tracker.inserted("hi👋")
        result = tracker.backspace()
        let emoji = try #require(result)
        #expect(emoji.utf16Length == 2)
        // The segment had text, so the predictor gets a new one here.
        #expect(emoji.rotatesSegment)
        result = tracker.backspace()
        let letter = try #require(result)
        #expect(letter.utf16Length == 1)
        // Consecutive Backspaces stay in the segment the first one opened.
        #expect(!letter.rotatesSegment)
        tracker.inserted("x")
        result = tracker.backspace()
        #expect(result?.rotatesSegment == true)
        result = tracker.backspace()
        #expect(result != nil)
        result = tracker.backspace()
        #expect(result == nil)

        tracker.inserted("abc")
        tracker.reset()
        #expect(!tracker.hasTrackedText)
        result = tracker.backspace()
        #expect(result == nil)

        tracker.inserted(String(repeating: "a", count: PersonalHistoryDeletionTracker.maximumTrackedCharacters + 10))
        var reported = 0
        while tracker.backspace() != nil { reported += 1 }
        #expect(reported == PersonalHistoryDeletionTracker.maximumTrackedCharacters)
    }

    @Test("The personal predictor ignores deletions")
    func predictorIgnoresDeletions() throws {
        let start = PersonalNextWordShadow.evaluationStartMilliseconds + 1_000
        let typing = [
            Self.typed(" alpha beta alpha beta alpha beta ", session: "chain", at: start),
            Self.typed(" alpha beta alpha beta ", session: "chain_1", at: start + 1_000),
        ]
        let withDeletion = [
            typing[0],
            try #require(Self.deletion(1, session: "chain_1", at: start + 500)),
            typing[1],
        ]
        var plain = PersonalNextWordShadow()
        plain.consume(typing)
        var deleting = PersonalNextWordShadow()
        deleting.consume(withDeletion)
        #expect(deleting.snapshot == plain.snapshot)
        #expect(deleting.trainedModel == plain.trainedModel)
    }

    @Test("The encrypted log never stores a deletion")
    func controllerDropsDeletions() async throws {
        let store = MemoryStore()
        let suite = "transcripted.tests.deletions.\(UUID().uuidString)"
        let keyboard = try #require(UserDefaults(suiteName: suite + ".keyboard"))
        let app = try #require(UserDefaults(suiteName: suite + ".app"))
        defer {
            keyboard.removePersistentDomain(forName: suite + ".keyboard")
            app.removePersistentDomain(forName: suite + ".app")
        }
        let settings = TildeSettings(keyboard: keyboard, app: app)
        let controller = PersonalHistoryController(store: store, settings: settings)
        controller.isEnabled = true
        let history = try #require(settings.personalHistoryIdentifier)
        let consent = try #require(settings.personalHistoryConsentIdentifier)

        let typed = try #require(PersonalHistoryEvent(
            id: "typed",
            timestampMilliseconds: 1_786_600_000_000,
            historyIdentifier: history,
            consentIdentifier: consent,
            sessionIdentifier: "chain",
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: "teh"
        ))
        let deletion = try #require(PersonalHistoryEvent(
            deletionID: "deletion",
            timestampMilliseconds: 1_786_600_000_100,
            historyIdentifier: history,
            consentIdentifier: consent,
            sessionIdentifier: "chain_1",
            appBundleIdentifier: "com.example.Editor",
            deletedCharacters: 1
        ))
        #expect(await controller.ingest([typed, deletion]))
        #expect(await controller.ingest([deletion]))
        #expect(await store.events == [typed])
    }

    // MARK: - Helpers

    static func typed(
        _ text: String,
        session: String = "chain",
        at timestamp: Int64 = 1_786_600_000_000
    ) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            id: "typed-\(text.count)-\(timestamp)",
            timestampMilliseconds: timestamp,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: session,
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: text
        )!
    }

    static func deletion(
        _ count: Int,
        id: String = "deletion",
        session: String = "chain_1",
        at timestamp: Int64 = 1_786_600_000_100
    ) -> PersonalHistoryEvent? {
        PersonalHistoryEvent(
            deletionID: id,
            timestampMilliseconds: timestamp,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: session,
            appBundleIdentifier: "com.example.Editor",
            deletedCharacters: count
        )
    }

    private actor Sink {
        private(set) var events: [PersonalHistoryEvent] = []

        func record(_ batch: [PersonalHistoryEvent]) -> GhostBrainResponse {
            events.append(contentsOf: batch)
            return .recorded
        }
    }

    private struct CaptureFixture {
        let defaults: UserDefaults
        let sink = Sink()
        let capture: PersonalHistoryCapture

        init() {
            let suite = "transcripted.tests.deletion-capture.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(true, forKey: PersonalHistorySettingsContract.enabledKey)
            defaults.set("history", forKey: PersonalHistorySettingsContract.historyIdentifierKey)
            defaults.set("consent", forKey: PersonalHistorySettingsContract.consentIdentifierKey)
            let sink = self.sink
            capture = PersonalHistoryCapture(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: 1_786_600_000) },
                sender: { await sink.record($0) }
            )
        }
    }

    private actor MemoryStore: PersonalHistoryStore {
        nonisolated let location = URL(fileURLWithPath: "/nonexistent/transcripted-deletion-test")
        private(set) var events: [PersonalHistoryEvent] = []
        private var sequence: Int64 = 0

        func append(
            _ events: [PersonalHistoryEvent],
            checkpoint: PersonalNextWordStoredCheckpoint?
        ) async throws -> Int64 {
            self.events.append(contentsOf: events)
            sequence += 1
            return sequence
        }

        func loadReplay(maximumBytes: Int64) async throws -> PersonalHistoryReplay {
            PersonalHistoryReplay(records: [], checkpoint: nil)
        }

        func saveTrainedModel(_ model: PersonalNextWordStoredModel) async throws {}
        func deleteAll() async throws { events.removeAll() }

        func summary() async throws -> PersonalHistorySummary {
            PersonalHistorySummary(location: location, approximateBytes: 0)
        }
    }
}
