import Testing
@testable import TranscriptedWritingCore

@Suite("Suggestion reveal delay")
struct SuggestionRevealDelayPolicyTests {
    @Test("Chromium browsers and Electron apps use calm marked text")
    func knownJumpyHostsUseCalmMarkedText() {
        #expect(SuggestionRevealDelayPolicy.requiresCalmMarkedText(
            bundleIdentifier: "com.google.Chrome.beta",
            hasElectronFramework: false
        ))
        #expect(SuggestionRevealDelayPolicy.requiresCalmMarkedText(
            bundleIdentifier: "com.example.editor",
            hasElectronFramework: true
        ))
        #expect(!SuggestionRevealDelayPolicy.requiresCalmMarkedText(
            bundleIdentifier: "com.apple.TextEdit",
            hasElectronFramework: false
        ))
    }

    @Test("The current grapheme selects native and calm reveal timing")
    func currentGraphemeSelectsDelay() {
        #expect(SuggestionRevealDelayPolicy.nanoseconds(
            afterUserTyped: "a",
            calmMarkedText: false
        ) == 10_000_000)
        #expect(SuggestionRevealDelayPolicy.nanoseconds(
            afterUserTyped: " ",
            calmMarkedText: false
        ) == 50_000_000)
        #expect(SuggestionRevealDelayPolicy.nanoseconds(
            afterUserTyped: "a",
            calmMarkedText: true
        ) == 120_000_000)
        #expect(SuggestionRevealDelayPolicy.nanoseconds(
            afterUserTyped: " ",
            calmMarkedText: true
        ) == 200_000_000)
    }

    @Test("Chromium and Electron start inference immediately and delay only reveal")
    func calmHostsDelayOnlyReveal() {
        let timing = SuggestionRevealDelayPolicy.schedule(
            afterUserTyped: " ",
            calmMarkedText: true
        )
        #expect(timing.inferenceDelayNanoseconds == 0)
        #expect(timing.revealDelayNanoseconds == 200_000_000)
    }

    @Test("The preview calm pair is shorter on both edges and leaves native timing alone")
    func previewCalmDelays() {
        let preview = SuggestionRevealDelayPolicy.CalmDelays.preview
        #expect(SuggestionRevealDelayPolicy.nanoseconds(afterUserTyped: " ", calmMarkedText: true, calm: preview) == 120_000_000)
        #expect(SuggestionRevealDelayPolicy.nanoseconds(afterUserTyped: "a", calmMarkedText: true, calm: preview) == 80_000_000)
        #expect(SuggestionRevealDelayPolicy.nanoseconds(afterUserTyped: " ", calmMarkedText: true, chained: true, calm: preview) == 80_000_000)
        #expect(SuggestionRevealDelayPolicy.nanoseconds(afterUserTyped: " ", calmMarkedText: false, calm: preview) == 50_000_000)
        #expect(SuggestionRevealDelayPolicy.nanoseconds(afterUserTyped: " ", calmMarkedText: true) == 200_000_000)
    }

    @Test("Punctuation is a request boundary only when allowed")
    func punctuationBoundary() {
        #expect(RawContinuationPrompt.endsAtRequestBoundary("see you ", allowingPunctuation: false))
        #expect(!RawContinuationPrompt.endsAtRequestBoundary("see you.", allowingPunctuation: false))
        #expect(RawContinuationPrompt.endsAtRequestBoundary("see you.", allowingPunctuation: true))
        #expect(RawContinuationPrompt.endsAtRequestBoundary("well,", allowingPunctuation: true))
        #expect(!RawContinuationPrompt.endsAtRequestBoundary("(note)", allowingPunctuation: true))
        #expect(!RawContinuationPrompt.endsAtRequestBoundary("word", allowingPunctuation: true))
        #expect(!RawContinuationPrompt.endsAtRequestBoundary("", allowingPunctuation: true))
    }
}
