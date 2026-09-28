import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Effective configuration: four policies, one digest")
struct TildeConfigurationTests {
    @Test("Production keeps every measured number after the split")
    func productionUnchanged() {
        let decision = DecisionPolicy.conservative
        #expect(decision.maximumVisibleWords == CompletionSuggestion.defaultMaxVisibleWords)
        #expect(decision.sceneEchoMinimumWords == SceneEchoPolicy.defaultMinimumWords)
        #expect(decision.sceneEchoMinimumCharacters == SceneEchoPolicy.defaultMinimumCharacters)
        #expect(decision.factualGrounding == .off)
        #expect(decision.sceneSuggestionOptions == .production)
        #expect(!decision.includesWindowTitleInScene)
        let interaction = InteractionPolicy.conservative
        #expect(!interaction.chainsCompletionAfterAccept)
        #expect(interaction.calmRevealDelays == .production)
        #expect(!interaction.requestsAfterPunctuation)
        // Between spaces, production's only predictor stays the system
        // dictionary: the model is asked at boundaries and nowhere else.
        #expect(!interaction.requestsMidWordContinuation)
        #expect(!TildeProductProfile.production.requestsMidWordContinuation)
        #expect(TildeProductProfile.production.decisionPolicy == .conservative)
        #expect(TildeProductProfile.production.interactionPolicy == .conservative)
    }

    @Test("The 9B behaviour is the tuned stack; only the 9B build gets the tuned interaction")
    func tunedStack() {
        #expect(DecisionPolicy.tuned9B.maximumVisibleWords == 3)
        #expect(DecisionPolicy.tuned9B.sceneEchoMinimumCharacters == 24)
        #expect(DecisionPolicy.tuned9B.factualGrounding == .numbersAndNames)
        #expect(DecisionPolicy.tuned9B.replyCueAnchoredToCurrentSentence)
        #expect(!DecisionPolicy.tuned9B.extendedOrdinarySilenceGate)
        #expect(InteractionPolicy.tuned9B.calmRevealDelays == .preview)
        #expect(InteractionPolicy.tuned9B.chainsCompletionAfterAccept)
        #expect(InteractionPolicy.tuned9B.requestsAfterPunctuation)
        #expect(InteractionPolicy.tuned9B.requestsMidWordContinuation)
        #expect(TildeProductProfile.preview9B.requestsMidWordContinuation)
        #expect(TildeProductProfile.preview9B.decisionPolicy == .tuned9B)
        #expect(TildeProductProfile.preview9B.interactionPolicy == .tuned9B)
    }

    @Test("Production with Qwen is one explicit configuration: tuned generation and decision, conservative interaction")
    func productionWithQwen() {
        let gemma = TildeEffectiveConfiguration.resolve(
            build: .production, completionProfile: .production, modelIdentifier: "gemma-4-e2b-q4km"
        )
        let qwen = TildeEffectiveConfiguration.resolve(
            build: .production, completionProfile: .preview9B, modelIdentifier: "qwen-3.5-9b-base-q4km"
        )
        let preview = TildeEffectiveConfiguration.resolve(
            build: .preview9B, completionProfile: .preview9B, modelIdentifier: "qwen-3.5-9b-base-q4km"
        )
        #expect(gemma.decision == .conservative)
        #expect(gemma.interaction == .conservative)
        #expect(gemma.generator.temperature == 0)
        #expect(qwen.decision == .tuned9B)
        #expect(qwen.interaction == .conservative)
        // The official Qwen choice runs the tuned filters in the production
        // build, so it must not pick up the preview's keyboard behaviour:
        // mid-word requests are the 9B preview's trial alone.
        #expect(!qwen.interaction.requestsMidWordContinuation)
        #expect(preview.interaction.requestsMidWordContinuation)
        #expect(qwen.generator.temperature == 0.10)
        #expect(qwen.generator.generatedTokenBudget == 12)
        #expect(preview.decision == .tuned9B)
        #expect(preview.interaction == .tuned9B)
        // Three configurations, three digests; the same inputs, the same digest.
        #expect(Set([gemma.digestSHA256, qwen.digestSHA256, preview.digestSHA256]).count == 3)
        #expect(qwen.digestSHA256.count == 64)
        #expect(qwen.digestSHA256 == TildeEffectiveConfiguration.resolve(
            build: .production, completionProfile: .preview9B, modelIdentifier: "qwen-3.5-9b-base-q4km"
        ).digestSHA256)
    }

    @Test("The keyboard adopts the served interaction policy from any response line")
    func keyboardAdoptsServedPolicy() throws {
        var served = ServedInteractionPolicy(default: .conservative)
        #expect(served.policy == .conservative)
        #expect(served.configurationDigest == nil)
        let configuration = TildeEffectiveConfiguration.resolve(
            build: .preview9B, completionProfile: .preview9B, modelIdentifier: "qwen-3.5-9b-base-q4km"
        )
        let line = GhostBrainResponse.partial("wor", register: .chat).stamped(configuration: configuration)
        let decoded = try JSONDecoder().decode(GhostBrainResponse.self, from: JSONEncoder().encode(line))
        let changed = served.adopt(decoded)
        #expect(changed)
        #expect(served.policy == .tuned9B)
        // The keyboard learns mid-word from the app, never from its own
        // bundle: a conservative default that adopted a tuned line now
        // requests mid-word, and the app that told it so is the one that
        // will accept the request on the wire.
        #expect(served.policy.requestsMidWordContinuation)
        #expect(served.configurationDigest == configuration.digestSHA256)
        let changedAgain = served.adopt(decoded)
        #expect(!changedAgain)
        // A pre-digest app teaches nothing and changes nothing.
        let legacy = GhostBrainResponse.decode(Data(#"{"outcome":"silence"}"#.utf8))
        let changedByLegacy = served.adopt(legacy)
        #expect(!changedByLegacy)
        #expect(served.policy == .tuned9B)
    }

    @Test("A newer keyboard reads an older app's interaction object with conservative defaults")
    func olderInteractionObjectDecodes() throws {
        let legacy = Data(#"{"chainsCompletionAfterAccept":true,"calmRevealPostSpaceMilliseconds":120,"calmRevealMidWordMilliseconds":80,"requestsAfterPunctuation":true}"#.utf8)
        let policy = try JSONDecoder().decode(InteractionPolicy.self, from: legacy)
        #expect(policy.chainsCompletionAfterAccept)
        #expect(!policy.requestsMidWordContinuation)
        #expect(policy.midWordRequestThrottleMilliseconds == 0)
        // And a response whose interaction object cannot be read at all still
        // delivers its suggestion; the keyboard just adopts nothing.
        let line = Data(#"{"outcome":"suggestion","suggestion":"there","interaction":{"garbage":1}}"#.utf8)
        let response = GhostBrainResponse.decode(line)
        #expect(response.outcome == .suggestion)
        #expect(response.suggestion == "there")
        #expect(response.interaction == nil)
    }

    @Test("Stamping the configuration keeps the decision receipt intact")
    func stampsCompose() throws {
        let configuration = TildeEffectiveConfiguration.resolve(
            build: .production, completionProfile: .production, modelIdentifier: "gemma-4-e2b-q4km"
        )
        let line = GhostBrainResponse.suggestion("there", register: .email, source: .baseModel)
            .stamped(opportunityID: "op", reason: .shown, generated: true, generatorMilliseconds: 99)
            .stamped(configuration: configuration)
        let decoded = try JSONDecoder().decode(GhostBrainResponse.self, from: JSONEncoder().encode(line))
        #expect(decoded.reason == "shown")
        #expect(decoded.generatorMilliseconds == 99)
        #expect(decoded.configurationDigest == configuration.digestSHA256)
        #expect(decoded.interaction == .conservative)
        // And the other order.
        let reversed = GhostBrainResponse.silence(reason: .emptyPrompt, opportunityID: "op")
            .stamped(configuration: configuration)
            .stamped(opportunityID: "op", reason: .emptyPrompt, generated: false)
        #expect(reversed.configurationDigest == configuration.digestSHA256)
        #expect(reversed.reason == "empty-prompt")
    }
}
