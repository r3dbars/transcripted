import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Personal History events")
struct PersonalHistoryEventTests {
    @Test("Events and history batches serialize without losing provenance")
    func serializationRoundTrip() throws {
        let event = makeEvent(text: "hello world", source: .acceptedSuggestion)
        let decoded = try JSONDecoder().decode(
            PersonalHistoryEvent.self,
            from: JSONEncoder().encode(event)
        )
        #expect(decoded == event)

        let request = GhostBrainRequest(personalHistoryEvents: [event])
        let requestRoundTrip = try JSONDecoder().decode(
            GhostBrainRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(requestRoundTrip == request)
        #expect(requestRoundTrip.context.isEmpty)
        #expect(requestRoundTrip.personalHistoryEvents == [event])
    }

    @Test("Raw text and metadata are bounded before crossing the socket")
    func bounds() throws {
        #expect(PersonalHistoryEvent(
            id: "event",
            timestampMilliseconds: 1,
            historyIdentifier: "history",
            sessionIdentifier: "session",
            appBundleIdentifier: "bad bundle id",
            source: .typed,
            text: "x"
        ) == nil)
        #expect(PersonalHistoryEvent(
            id: "event",
            timestampMilliseconds: 1,
            historyIdentifier: String(repeating: "h", count: 65),
            sessionIdentifier: "session",
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: "x"
        ) == nil)
        #expect(PersonalHistoryEvent(
            id: "event",
            timestampMilliseconds: 1,
            historyIdentifier: "history",
            sessionIdentifier: String(repeating: "s", count: 65),
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: "x"
        ) == nil)
        #expect(PersonalHistoryEvent(
            id: "event",
            timestampMilliseconds: 1,
            historyIdentifier: "history",
            sessionIdentifier: "session",
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: String(repeating: "x", count: PersonalHistoryEvent.maximumTextCharacters + 1)
        ) == nil)
        #expect(PersonalHistoryEvent(
            id: "event",
            timestampMilliseconds: 1,
            historyIdentifier: "history",
            sessionIdentifier: "session",
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: "x" + String(repeating: "\u{301}", count: 2_100)
        ) == nil)

        let tooMany = (0...PersonalHistoryEvent.maximumBatchEvents).map {
            makeEvent(id: "event-\($0)", text: "x")
        }
        #expect(!PersonalHistoryEvent.validBatch(tooMany))

        let escapedText = String(repeating: "\u{1}", count: 85)
        let largestBatch = (0..<PersonalHistoryEvent.maximumBatchEvents).map {
            PersonalHistoryEvent(
                id: String(repeating: "i", count: 62) + String(format: "%02d", $0),
                timestampMilliseconds: 1_786_485_600_000,
                historyIdentifier: String(repeating: "h", count: 64),
                sessionIdentifier: String(repeating: "s", count: 64),
                appBundleIdentifier: String(repeating: "a", count: 200),
                source: .typed,
                text: escapedText
            )!
        }
        #expect(PersonalHistoryEvent.validBatch(largestBatch))
        #expect(
            try JSONEncoder().encode(GhostBrainRequest(personalHistoryEvents: largestBatch)).count
                < 16_384
        )

        let sized = [
            makeEvent(id: "a", text: String(repeating: "a", count: 512)),
            makeEvent(id: "b", text: String(repeating: "b", count: 512)),
            makeEvent(id: "c", text: "c"),
        ]
        #expect(PersonalHistoryEvent.boundedBatchPrefix(sized).map(\.id) == ["a", "b"])
        #expect(PersonalHistoryEvent.validBatch(Array(sized.prefix(2))))
        #expect(!PersonalHistoryEvent.validBatch(sized))

        let normalized = PersonalHistoryCapturePolicy.normalizedExcludedApps([
            "com.example.Valid", "bad value", "com.example.Valid", "org.example.Other",
        ])
        #expect(normalized == ["com.example.Valid", "org.example.Other"])
    }

    @Test("Disabled, secure, unknown, and excluded contexts fail closed")
    func capturePolicy() {
        let policy = PersonalHistoryCapturePolicy()
        let app = "com.example.Editor"
        #expect(policy.decision(
            enabled: false,
            secureInput: false,
            appBundleIdentifier: app,
            excludedApps: []
        ) == .blocked(.disabled))
        #expect(policy.decision(
            enabled: true,
            secureInput: true,
            appBundleIdentifier: app,
            excludedApps: []
        ) == .blocked(.secureInput))
        #expect(policy.decision(
            enabled: true,
            secureInput: false,
            appBundleIdentifier: nil,
            excludedApps: []
        ) == .blocked(.missingOrInvalidApp))
        #expect(policy.decision(
            enabled: true,
            secureInput: false,
            appBundleIdentifier: app,
            excludedApps: [app]
        ) == .blocked(.excludedApp))
        #expect(policy.decision(
            enabled: true,
            secureInput: false,
            appBundleIdentifier: app,
            excludedApps: []
        ) == .allowed(appBundleIdentifier: app))
    }

    @Test("Password managers are blocked even with an empty user exclusion list")
    func capturePolicyAlwaysExcludesPasswordManagers() {
        let policy = PersonalHistoryCapturePolicy()
        #expect(policy.decision(
            enabled: true,
            secureInput: false,
            appBundleIdentifier: "com.1password.1password",
            excludedApps: []
        ) == .blocked(.excludedApp))
        #expect(policy.decision(
            enabled: true,
            secureInput: false,
            appBundleIdentifier: "com.apple.keychainaccess",
            excludedApps: []
        ) == .blocked(.excludedApp))
    }

    @Test("Typed chunks can grow only within the event text bound")
    func boundedChunkGrowth() {
        let event = makeEvent(text: String(repeating: "x", count: 500))
        #expect(event.coalescing(with: makeEvent(
            id: "next",
            text: String(repeating: "y", count: 12)
        ))?.text.count == 512)
        #expect(event.coalescing(with: makeEvent(
            id: "too-long",
            text: String(repeating: "y", count: 13)
        )) == nil)
        #expect(event.coalescing(with: makeEvent(
            id: "accepted",
            text: "suggestion",
            source: .acceptedSuggestion
        )) == nil)
    }

    private func makeEvent(
        id: String = "event-1",
        text: String,
        source: PersonalHistoryEventSource = .typed
    ) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            id: id,
            timestampMilliseconds: 1_786_485_600_000,
            historyIdentifier: "history-1",
            sessionIdentifier: "session-1",
            appBundleIdentifier: "com.example.Editor",
            source: source,
            text: text
        )!
    }
}
