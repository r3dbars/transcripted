import Testing
@testable import TranscriptedWritingCore

/// The proof for `PreparedCompletionContext`: the visible output is what it
/// was before the context was prepared once per request, and the context is
/// no longer tokenized once per streamed partial.
@Suite("Prepared completion context")
struct PreparedCompletionContextTests {
    private let cleaner = CompletionOutputCleaner(maxVisibleWords: 8)

    // MARK: - Byte identity

    @Test("Every cleaner golden still holds through the prepared context")
    func cleanerGoldensHold() {
        var index = 0
        for context in PreparedContextGoldens.contexts {
            let prepared = PreparedTypedContext(textBeforeCursor: context)
            for raw in PreparedContextGoldens.rawOutputs {
                let signature = PreparedContextGoldens.signature(cleaner.clean(raw, in: prepared))
                #expect(
                    signature == PreparedContextGoldens.goldenSignatures[index],
                    """
                    visible output drifted for context \(String(describing: context)) \
                    and raw \(raw): \(signature)
                    """
                )
                index += 1
            }
        }
        #expect(index == PreparedContextGoldens.goldenSignatures.count)
    }

    @Test("Every scene-policy golden still holds through the prepared forms")
    func scenePolicyGoldensHold() {
        var index = 0
        for (sceneIndex, scene) in PreparedContextGoldens.scenes.enumerated() {
            let productionEcho = SceneEchoPolicy.prepared(scene: scene, profile: .production)
            let tunedEcho = SceneEchoPolicy.prepared(scene: scene, profile: .preview9B)
            let names = FactualGroundingPolicy.prepared(
                typedContext: PreparedContextGoldens.groundingTypedContext,
                scene: scene,
                mode: .numbersAndNames
            )
            let anchors = FactualGroundingPolicy.prepared(
                typedContext: PreparedContextGoldens.groundingTypedContext,
                scene: scene,
                mode: .allAnchors
            )
            for candidate in PreparedContextGoldens.candidates {
                let line = [
                    String(sceneIndex),
                    String(SceneEchoPolicy.isEcho(candidate, in: productionEcho)),
                    String(SceneEchoPolicy.isEcho(candidate, in: tunedEcho)),
                    String(FactualGroundingPolicy.containsUnsupportedFact(candidate, in: names)),
                    String(FactualGroundingPolicy.containsUnsupportedFact(candidate, in: anchors)),
                ].joined(separator: "|")
                #expect(
                    line == PreparedContextGoldens.goldenPolicyDecisions[index],
                    "scene decision drifted for candidate \(candidate): \(line)"
                )
                index += 1
            }
        }
        #expect(index == PreparedContextGoldens.goldenPolicyDecisions.count)
    }

    @Test("Grounding off stays off through the prepared form")
    func preparedPoliciesMatchPerCallForm() {
        for scene in PreparedContextGoldens.scenes {
            #expect(
                !FactualGroundingPolicy.containsUnsupportedFact(
                    "Priya at 9pm",
                    in: FactualGroundingPolicy.prepared(
                        typedContext: "", scene: scene, mode: .off
                    )
                )
            )
        }
    }

    // MARK: - Counting: once per request, not once per partial

    @Test("A streaming request tokenizes its context once, not once per partial")
    func contextIsTokenizedOncePerRequest() {
        // The live shape: one bounded context, then a dozen complete-word
        // partials as the helper streams, then the final pass. Before this
        // change every one of those thirteen cleaning calls re-tokenized the
        // whole context.
        let context = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 60)
            + "and then "
        let counter = TokenizeCounter()
        let prepared = PreparedTypedContext(
            textBeforeCursor: context,
            tokenizer: counter.tokenize
        )
        #expect(counter.count == 1)

        let words = [
            " we", " will", " head", " out", " after", " the",
            " last", " one", " lands", " and", " lock", " up",
        ]
        var rawOutput = ""
        var partials = 0
        for word in words {
            rawOutput += word
            if cleaner.clean(rawOutput, in: prepared).result.suggestion != nil { partials += 1 }
        }
        _ = cleaner.cleanWithReason(rawOutput, in: prepared)

        #expect(partials >= 8, "the streaming shape under test must actually produce partials")
        #expect(counter.count == 1, "the context was tokenized \(counter.count) times, not once")
    }

    @Test("A prepared context holds the same words the tokenizer produces")
    func preparedWordsMatchTokenizer() {
        let context = "Sure, I will "
        let prepared = PreparedTypedContext(textBeforeCursor: context)
        #expect(prepared.words == CompletionContextWords.normalizedWords(in: context))
        #expect(prepared.isPresent)
        #expect(prepared.endsWithWhitespace)
        #expect(!prepared.endsWithLetter)

        let midWord = PreparedTypedContext(textBeforeCursor: "I will be at the fun")
        #expect(midWord.isPresent)
        #expect(!midWord.endsWithWhitespace)
        #expect(midWord.endsWithLetter)

        #expect(!PreparedTypedContext.absent.isPresent)
        #expect(PreparedTypedContext.absent.words.isEmpty)
    }

    @Test("The request-level context carries all three prepared forms")
    func requestLevelContextIsBuiltFromOneRequest() {
        let scene = ScreenScene.Scene(
            mode: .referencing,
            conversationTurns: [],
            referenceSnippets: ["the workshop runs Tuesday at 9am in room 204 with Dana"]
        )
        let request = PreparedCompletionContext(
            textBeforeCursor: "I will be there at ",
            scene: scene,
            profile: .preview9B
        )
        #expect(request.typed.words == ["i", "will", "be", "there", "at"])
        #expect(SceneEchoPolicy.isEcho("the workshop runs Tuesday", in: request.sceneEcho))
        #expect(FactualGroundingPolicy.containsUnsupportedFact("11am sharp", in: request.grounding))
        #expect(!FactualGroundingPolicy.containsUnsupportedFact("9am", in: request.grounding))
    }
}

/// Counts how many times a context is tokenized. Single-threaded by
/// construction: one request's preparation, then that request's cleaning
/// calls, all on this test's thread.
private final class TokenizeCounter {
    private(set) var count = 0

    func tokenize(_ text: String) -> [String] {
        count += 1
        return CompletionContextWords.normalizedWords(in: text)
    }
}
