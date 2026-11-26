import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Ghost brain wire")
struct GhostBrainWireTests {
    @Test("Capture batch requests round-trip with version and events")
    func captureBatchRoundTrips() throws {
        let event = try #require(PersonalHistoryEvent(
            id: UUID().uuidString,
            timestampMilliseconds: 1_790_350_931_387,
            historyIdentifier: "history-1",
            consentIdentifier: "consent-1",
            sessionIdentifier: "session-1",
            appBundleIdentifier: "com.apple.TextEdit",
            source: .typed,
            text: "hello "
        ))
        let request = GhostBrainRequest(personalHistoryEvents: [event])
        let decoded = try JSONDecoder().decode(
            GhostBrainRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decoded == request)
        #expect(decoded.v == GhostBrainRequest.version)
        #expect(decoded.personalHistoryEvents == [event])
    }

    @Test("Capture responses round-trip distinctly, including unsupported event IDs")
    func outcomesAreDistinct() throws {
        let outcomes: [GhostBrainResponse] = [
            .recorded,
            .unavailable,
            .error,
            .timeout,
            .invalidRequest,
            .unsupported(rejectedEventIDs: ["ev-1", "ev-2"]),
        ]
        for outcome in outcomes {
            let decoded = try JSONDecoder().decode(
                GhostBrainResponse.self,
                from: JSONEncoder().encode(outcome)
            )
            #expect(decoded == outcome)
        }
        #expect(GhostBrainResponse.recorded != .unavailable)
        #expect(GhostBrainResponse.decode(Data("not-json".utf8)) == .error)
    }
}
