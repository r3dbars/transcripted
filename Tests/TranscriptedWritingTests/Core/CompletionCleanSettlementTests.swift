import Foundation
import Testing
@testable import TranscriptedWritingCore

/// `CompletionOutputCleaner.clean` reports when later raw output can no longer
/// change the visible text. The streaming engine uses it to stop the helper
/// decoding tokens that can never reach the screen, so the bit must be
/// exactly as conservative as the display cap it mirrors.
@Suite("Completion clean settlement")
struct CompletionCleanSettlementTests {
    private let threeWords = CompletionOutputCleaner(maxVisibleWords: 3)

    @Test("Fewer words than the cap are never settled")
    func fewerWordsThanCap() {
        let outcome = threeWords.clean(" see you", after: "I will ")
        #expect(outcome.result.suggestion?.visibleText == "see you")
        #expect(!outcome.visibleTextIsSettled)
    }

    @Test("Exactly the cap is not settled: the last word may still be growing")
    func exactlyAtCapIsNotSettled() {
        let outcome = threeWords.clean(" see you tomorrow", after: "I will ")
        #expect(outcome.result.suggestion?.visibleText == "see you tomorrow")
        #expect(!outcome.visibleTextIsSettled)
    }

    @Test("One word past the cap settles, and the visible text is the capped text")
    func onePastCapSettles() {
        let outcome = threeWords.clean(" see you tomorrow at", after: "I will ")
        #expect(outcome.result.suggestion?.visibleText == "see you tomorrow")
        #expect(outcome.visibleTextIsSettled)
    }

    @Test("Settled visible text equals what a longer output would have produced")
    func settledTextMatchesLongerOutput() {
        let context = "Thanks, I will "
        let short = threeWords.clean(" see you tomorrow at", after: context)
        let long = threeWords.clean(" see you tomorrow at the office around noon", after: context)
        #expect(short.visibleTextIsSettled)
        #expect(short.result.suggestion?.visibleText == long.result.suggestion?.visibleText)
    }

    @Test("A dangling function word past the cap still settles to the same repaired text")
    func danglingTailPastCapSettles() {
        let context = "Thanks, I will "
        let short = threeWords.clean(" see you at the", after: context)
        let long = threeWords.clean(" see you at the park later", after: context)
        #expect(short.visibleTextIsSettled)
        #expect(short.result.suggestion?.visibleText == "see you")
        #expect(short.result.suggestion?.visibleText == long.result.suggestion?.visibleText)
    }

    @Test("The character cap settles the text once the word-capped text exceeds it")
    func characterCapSettles() {
        let cleaner = CompletionOutputCleaner(maxVisibleWords: 8, maxVisibleCharacters: 12)
        let under = cleaner.clean(" abcdefghijk", after: "x ")
        #expect(!under.visibleTextIsSettled)
        // 14 characters including the leading separator: strictly over 12.
        let over = cleaner.clean(" abcde fghijkl", after: "x ")
        #expect(over.visibleTextIsSettled)
        #expect(over.result.suggestion?.visibleText == "abcde")
    }

    @Test("An unsafe scalar settles as a rejection later tokens cannot undo")
    func unsafeScalarSettles() {
        let outcome = threeWords.clean(" see\u{200B} you", after: "I ")
        #expect(outcome.result.rejectionReason == .unsafeHiddenOrControlCharacter)
        #expect(outcome.visibleTextIsSettled)
    }

    @Test("A context replay settles: more output only adds n-grams")
    func contextReplaySettles() {
        let context = "let me know what you think about it "
        let outcome = threeWords.clean(" sure, let me know what you think", after: context)
        #expect(outcome.result.rejectionReason == .replaysContext)
        #expect(outcome.visibleTextIsSettled)
    }

    @Test("Rejections later tokens could change are not settled")
    func changeableRejectionsAreNotSettled() {
        #expect(!threeWords.clean("   ", after: "I ").visibleTextIsSettled)
        #expect(!threeWords.clean(" <no_suggestion>", after: "I ").visibleTextIsSettled)
        #expect(!threeWords.clean(" will", after: "I will ").visibleTextIsSettled)
    }

    @Test("cleanWithReason is the settlement-free view of the same pass")
    func cleanWithReasonMatchesClean() {
        for raw in [" see you tomorrow at", " see you", " sure, let me know what you think"] {
            let context = "let me know what you think about it "
            let a = threeWords.cleanWithReason(raw, after: context)
            let b = threeWords.clean(raw, after: context).result
            #expect(a.suggestion?.visibleText == b.suggestion?.visibleText)
            #expect(a.rejectionReason == b.rejectionReason)
        }
    }
}
