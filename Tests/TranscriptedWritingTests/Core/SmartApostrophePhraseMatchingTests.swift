import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Smart apostrophe phrase matching")
struct SmartApostrophePhraseMatchingTests {
    @Test("Existing sensitive phrases match ASCII and right-smart apostrophes in turns and references")
    func sensitivePhraseEquivalence() {
        let examples: [(String, SensitiveScenePolicy.Category)] = [
            ("he's dead", .bereavement),
            ("she's dead", .bereavement),
            ("we're divorcing", .relationshipEnding),
        ]
        for (ascii, expected) in examples {
            let smart = ascii.replacingOccurrences(of: "'", with: "\u{2019}")
            for text in [ascii, smart, smart.uppercased()] {
                // The emoji also checks that regex ranges use the normalized
                // string's UTF-16 coordinates, not a character-count range.
                let message = "🕊️ " + text + "."
                let reply = replyScene(message)
                let reference = ScreenScene.Scene(mode: .referencing, conversationTurns: [], referenceSnippets: [message])
                #expect(SensitiveScenePolicy.matchedCategory(scene: reply) == expected)
                #expect(SensitiveScenePolicy.matchedCategory(scene: reference) == expected)
                #expect(SensitiveScenePolicy.isSensitive(scene: reply))
            }
        }
    }

    @Test("Existing contraction cues produce the same complete intent ranking and label-only hint")
    func intentCueEquivalence() {
        let examples: [(String, IntentFuture.Kind)] = [
            ("can't ", .decline), ("won't ", .decline), ("I'll ", .commit),
        ]
        let scene = replyScene("Hello.")
        for (ascii, expected) in examples {
            let smart = ascii.replacingOccurrences(of: "'", with: "\u{2019}")
            let ordinary = IntentFuturesPlanner.futures(scene: scene, textBeforeCursor: ascii)
            let typographic = IntentFuturesPlanner.futures(scene: scene, textBeforeCursor: smart)
            #expect(ordinary.first?.kind == expected)
            #expect(typographic.first?.kind == expected)
            #expect(typographic == ordinary)
            #expect(IntentFuturesPlanner.promptHint(for: typographic) == IntentFuturesPlanner.promptHint(for: ordinary))
        }
    }

    @Test("Ordinary contractions and phrase boundaries do not gain a new sensitive meaning")
    func ordinaryAndBoundaryControls() {
        for text in ["She's ready for lunch.", "She’s ready for lunch.", "He’s deadly accurate at chess."] {
            #expect(!SensitiveScenePolicy.isSensitive(scene: replyScene(text)))
        }
        #expect(!SensitiveScenePolicy.isSensitive(scene: nil))
        let noScene = IntentFuturesPlanner.futures(scene: nil, textBeforeCursor: "I’ll ")
        #expect(noScene == [.init(kind: .continueWriting, weight: 1)])
        let ordinary = IntentFuturesPlanner.futures(scene: replyScene("Hello."), textBeforeCursor: "Maybe ")
        #expect(ordinary.first?.kind == .answer)
    }

    @Test("Only the right-smart apostrophe gains equivalence, without rewriting the input scene")
    func limitedNormalizationAndOriginalText() {
        let text = "She’s dead."
        let scene = replyScene(text)
        #expect(SensitiveScenePolicy.isSensitive(scene: scene))
        #expect(scene.conversationTurns.first?.text == text)
        #expect(!SensitiveScenePolicy.isSensitive(scene: replyScene("She‘s dead.")))
        let unrecognized = IntentFuturesPlanner.futures(scene: replyScene("Hello."), textBeforeCursor: "can‘t ")
        #expect(!unrecognized.contains { $0.kind == .decline })
    }

    private func replyScene(_ text: String) -> ScreenScene.Scene {
        .init(mode: .replying, conversationTurns: [.init(speaker: .other, text: text)], referenceSnippets: [])
    }
}
