import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Suggestion decision reasons and silent opportunities")
struct SuggestionDecisionReasonTests {
    @Test("Every scene gate and cleaner rejection maps to one fixed word")
    func gatesMapToReasons() {
        #expect(SuggestionDecisionReason(scene: .nonActionableScene) == .nonActionableScene)
        #expect(SuggestionDecisionReason(scene: .completeSentence).rawValue == "complete-sentence-scene")
        #expect(SuggestionDecisionReason(cleaner: .emptyOutput) == .emptyOutput)
        #expect(SuggestionDecisionReason(cleaner: .replaysContext) == .contextReplay)
        #expect(SuggestionDecisionReason(cleaner: .promptInstructionEcho) == .promptLeak)
        #expect(SuggestionDecisionReason(cleaner: .repeatsItself) == .selfRepetition)
    }

    @Test("Unavailable reasons are not policy; policy reasons are hidden; host-state reasons are neither")
    func reasonClasses() {
        for reason in [SuggestionDecisionReason.runtimeUnavailable, .timeout, .protocolError] {
            #expect(reason.isUnavailable)
            #expect(!reason.isPolicyHidden)
            #expect(reason.silentOutcome == "unavailable")
        }
        for reason in [SuggestionDecisionReason.sensitiveScene, .nonActionableScene, .sceneEcho, .emptyOutput, .suggestionsPaused] {
            #expect(reason.isPolicyHidden)
            #expect(reason.silentOutcome == "hidden")
        }
        for reason in [SuggestionDecisionReason.supersededByTyping, .notAtGrowingEdge] {
            #expect(!reason.isPolicyHidden)
            #expect(!reason.isUnavailable)
            #expect(reason.silentOutcome == "hidden")
        }
        #expect(!SuggestionDecisionReason.shown.isPolicyHidden)
    }

    @Test("A silent opportunity writes a text-free, undisplayed event with its reason")
    func silentEventShape() throws {
        let event = try TextFreeOnlineEvent.silent(
            id: UUID(),
            occurredAt: Date(timeIntervalSince1970: 2_000),
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "s"),
            variant: "champion",
            appCategory: "chat",
            register: "chat",
            boundary: "word-boundary",
            reason: .supersededByTyping,
            generated: true,
            deadlineMissed: true,
            generatorMilliseconds: 140,
            firstStableWordMilliseconds: 90,
            nextActionMilliseconds: 210,
            opportunityCharacters: 6
        )
        #expect(!event.displayed)
        #expect(event.generated)
        #expect(!event.policyHidden)
        #expect(event.deadlineMissed)
        #expect(event.outcome == "hidden")
        #expect(event.guardReason == "superseded-by-typing")
        #expect(event.acceptedCharacters == 0)
        #expect(event.candidateCharacters == 0)
        #expect(event.generatorMilliseconds == 140)
        #expect(event.firstStableWordMilliseconds == 90)
        #expect(event.retentionAt5Seconds.retainedCharacters == 0)
        let line = try TextFreeOnlineEvent.encodeJSONL(event)
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: TextFreeOnlineEvent.allowedKeys))
        #expect(try TextFreeOnlineEvent.decodeProductionLine(line.dropLast()) == event)

        let unavailable = try TextFreeOnlineEvent.silent(
            id: UUID(),
            occurredAt: Date(timeIntervalSince1970: 2_000),
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "s"),
            variant: "champion",
            appCategory: "prose",
            register: "prose",
            boundary: "sentence-boundary",
            reason: .timeout,
            generated: false,
            deadlineMissed: false,
            generatorMilliseconds: nil,
            firstStableWordMilliseconds: nil,
            nextActionMilliseconds: nil,
            opportunityCharacters: 1
        )
        #expect(unavailable.outcome == "unavailable")
        #expect(unavailable.timedOut)
        #expect(unavailable.candidateSourceBucket == "unknown-legacy")
    }

    @Test("The response receipt survives the wire and a pre-receipt line carries none")
    func responseReceipt() throws {
        let silence = GhostBrainResponse.silence(reason: .nonActionableScene, opportunityID: "op-1", register: .chat)
        let decoded = try JSONDecoder().decode(GhostBrainResponse.self, from: JSONEncoder().encode(silence))
        #expect(decoded.outcome == .silence)
        #expect(decoded.opportunityID == "op-1")
        #expect(decoded.reason == "non-actionable-scene")
        #expect(decoded.generated == false)
        #expect(decoded.register == "chat")

        let served = GhostBrainResponse.suggestion("there", register: .email, source: .baseModel)
            .stamped(opportunityID: "op-2", reason: .shown, generated: true, generatorMilliseconds: 120, firstStableWordMilliseconds: 80)
        let decodedServed = try JSONDecoder().decode(GhostBrainResponse.self, from: JSONEncoder().encode(served))
        #expect(decodedServed.suggestion == "there")
        #expect(decodedServed.reason == "shown")
        #expect(decodedServed.generatorMilliseconds == 120)
        #expect(decodedServed.firstStableWordMilliseconds == 80)

        let legacy = GhostBrainResponse.decode(Data(#"{"outcome":"silence"}"#.utf8))
        #expect(legacy.reason == nil)
        #expect(legacy.opportunityID == nil)
        #expect(legacy.generated == nil)

        let request = GhostBrainRequest(context: "hi ", app: "com.apple.Notes", opportunityID: "op-3")
        let decodedRequest = try JSONDecoder().decode(GhostBrainRequest.self, from: JSONEncoder().encode(request))
        #expect(decodedRequest.opportunityID == "op-3")
    }
}
