import Testing
@testable import TranscriptedWritingCore

private func scene(_ turns: [ScreenScene.ConversationTurn]) -> ScreenScene.Scene {
    ScreenScene.Scene(mode: .replying, conversationTurns: turns, referenceSnippets: [])
}

private func turn(_ speaker: ScreenScene.Speaker, _ text: String) -> ScreenScene.ConversationTurn {
    ScreenScene.ConversationTurn(speaker: speaker, text: text)
}

/// The `.referencing` shape `ScreenScene.classify` produces: no conversation
/// turns at all, just visible text from a window beside the composer.
private func referencingScene(_ snippets: [String]) -> ScreenScene.Scene {
    ScreenScene.Scene(mode: .referencing, conversationTurns: [], referenceSnippets: snippets)
}

@Suite("Sensitive scene policy")
struct SensitiveScenePolicyTests {
    // MARK: - The two live 2026-08-16 dogfood cases (build 2705)

    @Test("Case A: 'passed away' / 'funeral' conversation suppresses the garbled-relationship suggestion")
    func suppressesCaseA() {
        // The other party wrote these; the user was mid-typing "I am so
        // sorry, I will be at the funeral" when the ghost offered the wrong,
        // garbled "of my friend, I will be there".
        let s = scene([
            turn(.other, "my dad passed away this morning"),
            turn(.other, "funeral is going to be next week"),
        ])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
    }

    @Test("Case B: same conversation suppresses even on a two-word field prefix")
    func suppressesCaseB() {
        // The policy only ever looks at the classified scene's conversation
        // turns, not the user's own field text — so the fact that the user
        // had typed only "I'm so" when the bad "sorry I'm late" suggestion
        // fired is irrelevant to the check; the scene alone is enough.
        let s = scene([
            turn(.other, "my dad passed away this morning"),
            turn(.other, "funeral is going to be next week"),
        ])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == .bereavement)
    }

    // MARK: - No scene / non-sensitive: unaffected

    @Test("No scene (plain typing, no screen context) never suppresses")
    func noSceneNeverFires() {
        #expect(!SensitiveScenePolicy.isSensitive(scene: nil))
    }

    @Test("An ordinary, non-sensitive conversation does not suppress")
    func ordinaryConversationDoesNotFire() {
        let s = scene([
            turn(.other, "want to grab lunch later?"),
            turn(.selfSpeaker, "sure, how about noon"),
        ])
        #expect(!SensitiveScenePolicy.isSensitive(scene: s))
    }

    @Test("A scene with no conversation turns does not suppress")
    func emptyTurnsDoesNotFire() {
        let s = ScreenScene.Scene(mode: .composing, conversationTurns: [], referenceSnippets: [])
        #expect(!SensitiveScenePolicy.isSensitive(scene: s))
    }

    // MARK: - Other sensitivity classes

    @Test("Medical crisis language suppresses")
    func medicalCrisisFires() {
        let s = scene([turn(.other, "she's in the hospital, they think it might be serious")])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == .medicalCrisis)
    }

    @Test("Emergency/accident language suppresses")
    func emergencyFires() {
        let s = scene([turn(.other, "I was in a car accident, I'm okay but the car is totaled")])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == .emergency)
    }

    @Test("Breakup/divorce disclosure suppresses")
    func relationshipEndingFires() {
        let s = scene([turn(.other, "we broke up last weekend, it's been rough")])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == .relationshipEnding)
    }

    @Test("Job loss disclosure suppresses")
    func jobLossFires() {
        let s = scene([turn(.other, "I got laid off yesterday, still processing it")])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == .jobLoss)
    }

    // MARK: - Word-boundary negatives

    @Test("Word-boundary: 'rip' does not fire inside 'ripe' or 'stripped'")
    func ripDoesNotMatchSubstring() {
        let s = scene([turn(.other, "the strawberries are finally ripe, and my jeans got stripped at the knee")])
        #expect(!SensitiveScenePolicy.isSensitive(scene: s))
    }

    @Test(
        """
        Known v1 false-positive tradeoff, documented rather than special-cased: \
        'surgical strike' contains no phrase from the table (surgery/surgical are \
        different words), so it correctly does not fire — but a gaming line like \
        'the surgery went perfectly, best raid of the season' would, since 'surgery \
        went' matches regardless of register. Blunt-by-design per the plan; a \
        register-aware classifier is out of scope for v1.
        """
    )
    func documentedFalsePositiveTradeoff() {
        let benign = scene([turn(.other, "nice, that was a clean surgical strike on their base")])
        #expect(!SensitiveScenePolicy.isSensitive(scene: benign))

        let falsePositive = scene([turn(.other, "the surgery went perfectly, best raid of the season")])
        #expect(SensitiveScenePolicy.isSensitive(scene: falsePositive))
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        let s = scene([turn(.other, "FUNERAL is next week, please come")])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
    }

    // MARK: - The referencing mode (composing beside a visible window)

    @Test("A crisis phrase visible only in a reference snippet suppresses")
    func referenceSnippetSuppresses() {
        // Same failure shape as Case B, one window over: the writer is
        // composing in one app while a document or thread beside it carries
        // the grief. That text reaches the prompt through the Reference
        // block, so the same phrase table has to cover it.
        let s = referencingScene(["Draft: the funeral is going to be next week, details to follow"])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == .bereavement)
    }

    @Test("Every sensitivity class fires from a reference snippet, not just bereavement")
    func referenceSnippetCoversEveryCategory() {
        let cases: [(String, SensitiveScenePolicy.Category)] = [
            ("dad passed away this morning", .bereavement),
            ("she is in the icu tonight", .medicalCrisis),
            ("there was a car accident on the bridge", .emergency),
            ("we broke up last weekend", .relationshipEnding),
            ("I got laid off yesterday", .jobLoss),
        ]
        for (text, expected) in cases {
            let s = referencingScene([text])
            #expect(SensitiveScenePolicy.isSensitive(scene: s), "did not fire: \(text)")
            #expect(SensitiveScenePolicy.matchedCategory(scene: s) == expected)
        }
    }

    @Test("A crisis phrase in a later reference snippet still suppresses")
    func laterReferenceSnippetSuppresses() {
        let s = referencingScene([
            "quarterly roadmap notes",
            "reply to the team about the memorial service on Friday",
        ])
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
    }

    @Test("An ordinary referencing scene does not suppress")
    func benignReferenceSnippetDoesNotFire() {
        let s = referencingScene([
            "Release checklist: confirm the build number, then update the changelog",
        ])
        #expect(!SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == nil)
    }

    @Test("Reference snippets keep the same word boundaries as turns")
    func referenceSnippetRespectsWordBoundaries() {
        let s = referencingScene(["the strawberries are finally ripe and the jeans got stripped"])
        #expect(!SensitiveScenePolicy.isSensitive(scene: s))
    }

    @Test("A matching conversation turn still reports its own category ahead of any snippet")
    func conversationTurnWinsOverSnippet() {
        // Turns are scanned first, so a `.replying` scene reports exactly the
        // category it reported before snippets were scanned at all.
        let s = ScreenScene.Scene(
            mode: .replying,
            conversationTurns: [turn(.other, "my dad passed away this morning")],
            referenceSnippets: ["I got laid off yesterday"]
        )
        #expect(SensitiveScenePolicy.isSensitive(scene: s))
        #expect(SensitiveScenePolicy.matchedCategory(scene: s) == .bereavement)
    }
}

@Suite("Sensitive scene phrase table")
struct SensitiveScenePhraseTableTests {
    /// The compiled table must preserve every shipped phrase and boundary.
    /// A missing or malformed pattern would fail silently and let Tilde suggest
    /// into exactly the conversations this policy exists to stay out of, so
    /// prove the whole table rather than a sample.
    @Test("Every phrase in the table still fires when it appears on a word boundary")
    func everyShippedPhraseStillFires() {
        for (category, phrases) in SensitiveScenePolicy.phrasesByCategory {
            for phrase in phrases {
                let s = scene([turn(.other, "so anyway, \(phrase) yesterday.")])
                #expect(
                    SensitiveScenePolicy.isSensitive(scene: s),
                    "\(category) phrase stopped matching: \(phrase)"
                )
            }
        }
    }

    @Test("Every phrase in the table also fires from a reference snippet")
    func everyShippedPhraseFiresFromAReferenceSnippet() {
        for (category, phrases) in SensitiveScenePolicy.phrasesByCategory {
            for phrase in phrases {
                let s = referencingScene(["so anyway, \(phrase) yesterday."])
                #expect(
                    SensitiveScenePolicy.isSensitive(scene: s),
                    "\(category) phrase does not cover the referencing mode: \(phrase)"
                )
            }
        }
    }

    @Test("The table is non-empty and every phrase is lowercase, as the matcher assumes")
    func tableShapeHolds() {
        let all = SensitiveScenePolicy.phrasesByCategory.values.flatMap { $0 }
        #expect(all.count >= 40)
        for phrase in all {
            #expect(phrase == phrase.lowercased(), "phrase is not lowercase: \(phrase)")
            #expect(!phrase.isEmpty)
        }
    }
}
