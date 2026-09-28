import Testing
@testable import TranscriptedWritingCore

@Suite("Context reset detector")
struct ContextResetDetectorTests {
    @Test("Typing at the edge is not a reset")
    func typingIsNotReset() {
        #expect(!ContextResetDetector.isReset(previous: "I can make it on ", current: "I can make it on Thursday "))
        #expect(!ContextResetDetector.isReset(previous: "I can make it on Thursday ", current: "I can make it on "))
    }

    @Test("A wholesale content change is a reset")
    func threadSwitchIsReset() {
        #expect(ContextResetDetector.isReset(
            previous: "No rush, just let me know today if you can. ",
            current: "Want me to swing by after work and grab it? "
        ))
    }

    @Test("Short fields never count as resets")
    func shortFieldsIgnored() {
        #expect(!ContextResetDetector.isReset(previous: "Yes ", current: "Sure "))
        #expect(!ContextResetDetector.isReset(previous: "", current: "hello there friend "))
    }
}
