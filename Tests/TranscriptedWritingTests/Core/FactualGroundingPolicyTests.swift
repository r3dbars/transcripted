import Testing
@testable import TranscriptedWritingCore

@Suite("Factual grounding policy")
struct FactualGroundingPolicyTests {
    private let scene = ScreenScene.Scene(
        mode: .replying,
        conversationTurns: [
            .init(speaker: .other, text: "can you send the deck before the review?"),
            .init(speaker: .selfSpeaker, text: "yes, sending it Thursday."),
        ],
        referenceSnippets: ["Review is at 4pm in room 12; ping dana@example.com."]
    )

    @Test("Off never rejects")
    func offIsInert() {
        #expect(!FactualGroundingPolicy.containsUnsupportedFact(
            "at 9am on Tuesday",
            typedContext: "I'll be there ",
            scene: scene,
            mode: .off
        ))
    }

    @Test("An invented number, date, or address is unsupported")
    func inventedAnchorsRejected() {
        for candidate in [
            "at 9am",
            "on Tuesday",
            "in room 15",
            "cc priya@example.com",
            "ask Marcus about it",
        ] {
            #expect(FactualGroundingPolicy.containsUnsupportedFact(
                candidate,
                typedContext: "sure, ",
                scene: scene,
                mode: .numbersAndNames
            ), "expected \(candidate) to be unsupported")
        }
    }

    @Test("Anchors the writer typed or the screen showed are supported")
    func groundedAnchorsPass() {
        for candidate in [
            "at 4pm",
            "in room 12",
            "sending it Thursday",
            "dana@example.com has it",
        ] {
            #expect(!FactualGroundingPolicy.containsUnsupportedFact(
                candidate,
                typedContext: "sure, ",
                scene: scene,
                mode: .numbersAndNames
            ), "expected \(candidate) to be supported")
        }
    }

    @Test("Ordinary language carries no anchors")
    func plainContinuationsPass() {
        for candidate in ["sounds good to me", "sure, on my way", "ok thanks"] {
            #expect(!FactualGroundingPolicy.containsUnsupportedFact(
                candidate,
                typedContext: "",
                scene: scene,
                mode: .numbersAndNames
            ), "expected \(candidate) to be supported")
        }
    }

    @Test("A sentence-initial capital is position, not a name")
    func leadingCapitalIsNotAnAnchor() {
        #expect(!FactualGroundingPolicy.containsUnsupportedFact(
            "Great, see you there",
            typedContext: "",
            scene: scene,
            mode: .numbersAndNames
        ))
        // The same word later in the candidate is treated as an assertion.
        #expect(FactualGroundingPolicy.containsUnsupportedFact(
            "see you there Great",
            typedContext: "",
            scene: scene,
            mode: .numbersAndNames
        ))
    }

    @Test("All-anchors additionally holds long uncapitalized words")
    func allAnchorsIsStricter() {
        #expect(!FactualGroundingPolicy.containsUnsupportedFact(
            "the presentation is ready",
            typedContext: "",
            scene: scene,
            mode: .numbersAndNames
        ))
        #expect(FactualGroundingPolicy.containsUnsupportedFact(
            "the presentation is ready",
            typedContext: "",
            scene: scene,
            mode: .allAnchors
        ))
    }

    @Test("No scene still grounds against the typed context")
    func typedContextAloneGrounds() {
        #expect(!FactualGroundingPolicy.containsUnsupportedFact(
            "at 4pm",
            typedContext: "the sync is at 4pm and ",
            scene: nil,
            mode: .numbersAndNames
        ))
        #expect(FactualGroundingPolicy.containsUnsupportedFact(
            "at 5pm",
            typedContext: "the sync is at 4pm and ",
            scene: nil,
            mode: .numbersAndNames
        ))
    }
}
