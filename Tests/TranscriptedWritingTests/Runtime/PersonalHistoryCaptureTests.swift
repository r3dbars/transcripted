import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedKeyboard

@Suite("Personal History keyboard capture")
struct PersonalHistoryCaptureTests {
    @Test("Consent, exclusions, and secure input fail closed before enqueue")
    func permitPolicy() {
        let fixture = Fixture()
        #expect(fixture.capture.permit(
            appBundleIdentifier: "com.example.Editor",
            secureInput: false
        ) == nil)

        fixture.enable()
        fixture.defaults.set(
            ["com.example.Editor"],
            forKey: PersonalHistorySettingsContract.excludedAppsKey
        )
        #expect(fixture.capture.permit(
            appBundleIdentifier: "com.example.Editor",
            secureInput: false
        ) == nil)
        #expect(fixture.capture.permit(
            appBundleIdentifier: "com.example.Other",
            secureInput: true
        ) == nil)
    }

    @Test("A permitted event is delivered with its captured generation and timestamp")
    func recordsPermittedEvent() async {
        let fixture = Fixture()
        fixture.enable()
        let permit = fixture.capture.permit(
            appBundleIdentifier: "com.example.Editor",
            secureInput: false
        )!
        fixture.capture.record(
            text: "PRIVATE_SENTINEL",
            source: .acceptedSuggestion,
            sessionIdentifier: "segment",
            permit: permit
        )
        fixture.capture.flush()

        let events = await eventuallyRecorded(fixture.sink)
        #expect(events.count == 1)
        let typed = events.first
        #expect(typed?.historyIdentifier == "history-a")
        #expect(typed?.consentIdentifier == "consent-a")
        #expect(typed?.timestampMilliseconds == 1_786_485_600_000)
        #expect(typed?.sessionIdentifier == "segment")
        #expect(typed?.appBundleIdentifier == "com.example.Editor")
        #expect(typed?.source == .acceptedSuggestion)
        #expect(typed?.text == "PRIVATE_SENTINEL")
    }

    @Test("Generation and exclusion changes purge queued text before delivery")
    func rechecksPolicyBeforeSend() async {
        let fixture = Fixture()
        fixture.enable()
        let oldPermit = fixture.capture.permit(
            appBundleIdentifier: "com.example.Editor",
            secureInput: false
        )!
        fixture.capture.record(
            text: "PRIVATE_SENTINEL",
            source: .typed,
            sessionIdentifier: "segment",
            permit: oldPermit
        )
        fixture.defaults.set(
            "history-b",
            forKey: PersonalHistorySettingsContract.historyIdentifierKey
        )
        await fixture.capture.flushAndWait()
        #expect(await fixture.sink.events.isEmpty)

        let currentPermit = fixture.capture.permit(
            appBundleIdentifier: "com.example.Editor",
            secureInput: false
        )!
        fixture.capture.record(
            text: "PRIVATE_SENTINEL",
            source: .typed,
            sessionIdentifier: "segment",
            permit: currentPermit
        )
        fixture.defaults.set(
            ["com.example.Editor"],
            forKey: PersonalHistorySettingsContract.excludedAppsKey
        )
        await fixture.capture.flushAndWait()
        #expect(await fixture.sink.events.isEmpty)

        fixture.defaults.set(
            [],
            forKey: PersonalHistorySettingsContract.excludedAppsKey
        )
        fixture.defaults.set(
            "consent-b",
            forKey: PersonalHistorySettingsContract.consentIdentifierKey
        )
        fixture.capture.record(
            text: "PRIVATE_SENTINEL",
            source: .typed,
            sessionIdentifier: "segment",
            permit: currentPermit
        )
        await fixture.capture.flushAndWait()
        #expect(await fixture.sink.events.isEmpty)
    }

    @Test("Overflow discards the affected writing stream until a new boundary")
    func overflowPreservesDiscontinuity() async {
        let fixture = Fixture(maximumBufferedEvents: 2)
        fixture.enable()
        let permit = fixture.capture.permit(
            appBundleIdentifier: "com.example.Editor",
            secureInput: false
        )!
        for session in ["discarded", "kept-a", "kept-b", "discarded"] {
            fixture.capture.record(
                text: "private",
                source: .typed,
                sessionIdentifier: session,
                permit: permit
            )
        }
        fixture.capture.flush()

        let events = await eventuallyRecorded(fixture.sink)
        #expect(events.map(\.sessionIdentifier).sorted() == ["kept-a", "kept-b"])
    }

    private actor Sink {
        private(set) var events: [PersonalHistoryEvent] = []

        func record(_ batch: [PersonalHistoryEvent]) -> GhostBrainResponse {
            events.append(contentsOf: batch)
            return .recorded
        }
    }

    private struct Fixture {
        let defaults: UserDefaults
        let sink = Sink()
        let capture: PersonalHistoryCapture

        init(maximumBufferedEvents: Int = 192) {
            let suite = "tilde.tests.personal-history-capture.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let sink = self.sink
            capture = PersonalHistoryCapture(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: 1_786_485_600) },
                maximumBufferedEvents: maximumBufferedEvents,
                sender: { await sink.record($0) }
            )
        }

        func enable() {
            defaults.set(true, forKey: PersonalHistorySettingsContract.enabledKey)
            defaults.set(
                "history-a",
                forKey: PersonalHistorySettingsContract.historyIdentifierKey
            )
            defaults.set(
                "consent-a",
                forKey: PersonalHistorySettingsContract.consentIdentifierKey
            )
        }
    }

    private func eventuallyRecorded(_ sink: Sink) async -> [PersonalHistoryEvent] {
        for _ in 0..<100 {
            let events = await sink.events
            if !events.isEmpty { return events }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await sink.events
    }
}
