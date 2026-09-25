import TranscriptedWritingCore
import Testing
@testable import TranscriptedWritingRuntime

/// The 9B preview carries the owner-directed scene changes; every other
/// profile keeps the measured production prompt and gate byte for byte.
@Suite("Profile scene options")
struct ProfileSceneOptionsTests {
    @Test("Production and the other previews keep the measured gate and prompt")
    func productionIsUnchanged() {
        for profile in [TildeProductProfile.production] {
            #expect(profile.sceneSuggestionOptions == .production)
            #expect(!profile.includesWindowTitleInScene)
            #expect(!profile.chainsCompletionAfterAccept)
            #expect(profile.calmRevealDelays == .production)
            #expect(!profile.requestsAfterPunctuation)
        }
    }

    @Test("The 9B preview trials the shorter calm floor and punctuation boundaries")
    func preview9BRevealAndPunctuation() {
        #expect(TildeProductProfile.preview9B.calmRevealDelays == .preview)
        #expect(TildeProductProfile.preview9B.requestsAfterPunctuation)
    }

    @Test("Only the 9B preview chains a new request after a consumed accept")
    func preview9BChains() {
        #expect(TildeProductProfile.preview9B.chainsCompletionAfterAccept)
    }

    @Test("The 9B preview anchors the reply cue and includes the window title")
    func preview9BCarriesTheChanges() {
        #expect(TildeProductProfile.preview9B.sceneSuggestionOptions.replyCueAnchoredToCurrentSentence)
        #expect(!TildeProductProfile.preview9B.sceneSuggestionOptions.extendedOrdinarySilenceGate)
        #expect(TildeProductProfile.preview9B.includesWindowTitleInScene)
    }
}
