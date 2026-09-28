import Testing
@testable import TranscriptedWritingCore

@Suite("Capture kind policy")
struct CaptureKindPolicyTests {
    private let cap = ScreenScene.defaultStalenessCapSeconds

    @Test("Window is the default before anything is known")
    func windowFirst() {
        #expect(CaptureKindPolicy.kind(forcedFullDisplay: false, lastWindowSceneHadConversation: nil,
                                       secondsSinceLastFullDisplay: nil, stalenessCapSeconds: cap) == .window)
    }

    @Test("A window with a conversation never escalates to the display")
    func conversationStaysOnWindow() {
        #expect(CaptureKindPolicy.kind(forcedFullDisplay: false, lastWindowSceneHadConversation: true,
                                       secondsSinceLastFullDisplay: nil, stalenessCapSeconds: cap) == .window)
        #expect(CaptureKindPolicy.kind(forcedFullDisplay: false, lastWindowSceneHadConversation: true,
                                       secondsSinceLastFullDisplay: cap * 10, stalenessCapSeconds: cap) == .window)
    }

    @Test("No conversation in the window reads the display once per staleness window")
    func noConversationReadsDisplayWhenStale() {
        #expect(CaptureKindPolicy.kind(forcedFullDisplay: false, lastWindowSceneHadConversation: false,
                                       secondsSinceLastFullDisplay: nil, stalenessCapSeconds: cap) == .fullDisplay)
        #expect(CaptureKindPolicy.kind(forcedFullDisplay: false, lastWindowSceneHadConversation: false,
                                       secondsSinceLastFullDisplay: cap - 1, stalenessCapSeconds: cap) == .window)
        #expect(CaptureKindPolicy.kind(forcedFullDisplay: false, lastWindowSceneHadConversation: false,
                                       secondsSinceLastFullDisplay: cap, stalenessCapSeconds: cap) == .fullDisplay)
    }

    @Test("Forced full display wins")
    func forced() {
        #expect(CaptureKindPolicy.kind(forcedFullDisplay: true, lastWindowSceneHadConversation: true,
                                       secondsSinceLastFullDisplay: 0, stalenessCapSeconds: cap) == .fullDisplay)
    }
}
