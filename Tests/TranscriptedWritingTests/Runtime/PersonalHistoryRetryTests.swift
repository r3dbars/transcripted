import Foundation
import Testing
@testable import TranscriptedKeyboard
@testable import TranscriptedWritingCore

/// Transcripted phase 3 review: a keyboard newer than the app must not block
/// its history queue. The app answers events of a version it can't read with
/// `unsupported` and their IDs; the keyboard drops only those, and drops any
/// event the app refuses 12 times. Not reaching the app still retries as long
/// as Tilde's did.
@Suite("Personal History retries against an older app")
struct PersonalHistoryRetryTests {
    @Test("An app names the events whose version it can't read, and only those")
    func unsupportedVersionProbe() throws {
        let typed = try Self.object(Self.typed("hello", id: "typed-1"))
        let deletion = try Self.object(try #require(PersonalHistoryEvent(
            deletionID: "deletion-1",
            timestampMilliseconds: 1_786_600_000_100,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: "chain_1",
            appBundleIdentifier: "com.example.Editor",
            deletedCharacters: 1
        )))
        var future = typed
        future["v"] = 3
        future["id"] = "future-1"

        let mixed = try Self.line([typed, future])
        // The full decode fails, which is when the server asks the probe.
        #expect((try? JSONDecoder().decode(GhostBrainRequest.self, from: mixed)) == nil)
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(in: mixed) == ["future-1"])

        // Everything this build reads, or anything that isn't a well-formed
        // version-1 history batch, stays out of it.
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(in: try Self.line([typed, deletion])) == nil)
        var emptyText = typed
        emptyText["text"] = ""
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(in: try Self.line([emptyText])) == nil)
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(in: try Self.line([future], version: 2)) == nil)
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(
            in: try Self.line(Array(repeating: future, count: PersonalHistoryEvent.maximumBatchEvents + 1))
        ) == nil)
        var unsafeID = future
        unsafeID["id"] = "not/an-id"
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(in: try Self.line([unsafeID])) == nil)
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(
            in: try JSONEncoder().encode(GhostBrainRequest(context: "hello ", app: "com.example.Editor"))
        ) == nil)
        #expect(GhostBrainRequest.unsupportedPersonalHistoryEventIDs(in: Data("not-json".utf8)) == nil)
    }

    @Test("The unsupported answer carries event IDs only, and other lines keep their shape")
    func unsupportedResponseWire() throws {
        let unsupported = GhostBrainResponse.unsupported(rejectedEventIDs: ["future-1"])
        let data = try JSONEncoder().encode(unsupported)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["outcome"] as? String == "unsupported")
        #expect(object["final"] as? Bool == true)
        #expect(object["rejectedEventIDs"] as? [String] == ["future-1"])
        #expect(object["suggestion"] == nil)
        #expect(GhostBrainResponse.decode(data) == unsupported)

        let recorded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(GhostBrainResponse.recorded)) as? [String: Any]
        )
        #expect(Set(recorded.keys) == ["outcome", "final"])

        // A list this keyboard can't read is no list, never a lost line.
        let garbled = GhostBrainResponse.decode(Data(#"{"outcome":"unsupported","rejectedEventIDs":7}"#.utf8))
        #expect(garbled.outcome == .unsupported)
        #expect(garbled.rejectedEventIDs == nil)
    }

    @Test("The keyboard drops only the events the app can't read")
    func dropsOnlyUnsupportedEvents() async throws {
        let app = ScriptedApp { batch, _ in
            let deletions = batch.filter { $0.source == .deletion }.map(\.id)
            return deletions.isEmpty ? .recorded : .unsupported(rejectedEventIDs: deletions)
        }
        let capture = Self.capture(app)
        let permit = try #require(capture.permit(appBundleIdentifier: "com.example.Editor", secureInput: false))
        capture.record(text: "teh", source: .typed, sessionIdentifier: "chain", permit: permit)
        capture.recordDeletion(characters: 1, sessionIdentifier: "chain_1", permit: permit)
        capture.record(text: "he", source: .typed, sessionIdentifier: "chain_1", permit: permit)

        await capture.flushAndWait()
        await capture.flushAndWait()
        #expect(await app.batches.map { $0.map(\.source) } == [[.typed, .deletion, .typed], [.typed, .typed]])
        #expect(await app.recorded.map(\.text) == ["teh", "he"])
    }

    @Test("An event the app refuses 12 times is dropped, and the text behind it still goes")
    func capsRefusedEvents() async throws {
        // An app from before version-2 events answers any batch holding one
        // with `invalid_request`.
        let app = ScriptedApp { batch, _ in
            batch.contains { $0.source == .deletion } ? .invalidRequest : .recorded
        }
        let capture = Self.capture(app)
        let permit = try #require(capture.permit(appBundleIdentifier: "com.example.Editor", secureInput: false))
        capture.recordDeletion(characters: 1, sessionIdentifier: "chain_1", permit: permit)
        for _ in 1..<PersonalHistoryCapture.maximumRefusedAttempts {
            await capture.flushAndWait()
        }
        #expect(await app.batches.count == PersonalHistoryCapture.maximumRefusedAttempts - 1)
        #expect(await app.recorded.isEmpty)

        // Joins the refused batch once; the deletion's 12th refusal drops it
        // alone, and the text goes on its own.
        capture.record(text: "text behind it", source: .typed, sessionIdentifier: "other", permit: permit)
        await capture.flushAndWait()
        await capture.flushAndWait()
        let batches = await app.batches
        #expect(batches.count == PersonalHistoryCapture.maximumRefusedAttempts + 1)
        #expect(batches.last?.map(\.source) == [.typed])
        #expect(await app.recorded.map(\.text) == ["text behind it"])
    }

    @Test("Not reaching the app retries past the cap, as in Tilde")
    func transportFailuresKeepRetrying() async throws {
        let failures = PersonalHistoryCapture.maximumRefusedAttempts * 2
        let app = ScriptedApp { _, attempt in
            guard attempt <= failures else { return .recorded }
            return attempt.isMultiple(of: 2) ? .unavailable : .timeout
        }
        let capture = Self.capture(app)
        let permit = try #require(capture.permit(appBundleIdentifier: "com.example.Editor", secureInput: false))
        capture.record(text: "still here", source: .typed, sessionIdentifier: "chain", permit: permit)
        for _ in 0...failures {
            await capture.flushAndWait()
        }
        #expect(await app.batches.count == failures + 1)
        #expect(await app.recorded.map(\.text) == ["still here"])
    }

    // MARK: - Helpers

    /// Answers each batch the way the script says, and remembers every batch
    /// it was sent and every event it recorded.
    private actor ScriptedApp {
        private let answer: @Sendable ([PersonalHistoryEvent], Int) -> GhostBrainResponse
        private(set) var batches: [[PersonalHistoryEvent]] = []
        private(set) var recorded: [PersonalHistoryEvent] = []

        init(_ answer: @escaping @Sendable (_ batch: [PersonalHistoryEvent], _ attempt: Int) -> GhostBrainResponse) {
            self.answer = answer
        }

        func receive(_ batch: [PersonalHistoryEvent]) -> GhostBrainResponse {
            batches.append(batch)
            let response = answer(batch, batches.count)
            if response == .recorded { recorded.append(contentsOf: batch) }
            return response
        }
    }

    private static func capture(_ app: ScriptedApp) -> PersonalHistoryCapture {
        let suite = "transcripted.tests.history-retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: PersonalHistorySettingsContract.enabledKey)
        defaults.set("history", forKey: PersonalHistorySettingsContract.historyIdentifierKey)
        defaults.set("consent", forKey: PersonalHistorySettingsContract.consentIdentifierKey)
        return PersonalHistoryCapture(
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_786_600_000) },
            sender: { await app.receive($0) }
        )
    }

    private static func typed(_ text: String, id: String) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            id: id,
            timestampMilliseconds: 1_786_600_000_000,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: "chain",
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: text
        )!
    }

    private static func object(_ event: PersonalHistoryEvent) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    }

    /// One history request line as a keyboard would send it.
    private static func line(_ events: [[String: Any]], version: Int = GhostBrainRequest.version) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": version,
            "context": "",
            "personalHistoryEvents": events,
        ])
    }
}
