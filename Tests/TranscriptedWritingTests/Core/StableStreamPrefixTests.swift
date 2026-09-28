import Testing
@testable import TranscriptedWritingCore

@Suite("Stable stream prefix")
struct StableStreamPrefixTests {
    @Test("Only whitespace ends a streamed word")
    func whitespaceBoundary() {
        #expect(StableStreamPrefix.prefix(of: " very") == nil)
        #expect(StableStreamPrefix.prefix(of: " very ") == " very")
        #expect(StableStreamPrefix.prefix(of: " very good") == " very")
        #expect(StableStreamPrefix.prefix(of: " at 10:") == " at")
        #expect(StableStreamPrefix.prefix(of: " costs 1,000 today") == " costs 1,000")
        #expect(StableStreamPrefix.prefix(of: " see v1.2 notes") == " see v1.2")
    }

    @Test("Punctuation-only prefixes are not shown")
    func requiresAlphanumeric() {
        #expect(StableStreamPrefix.prefix(of: " -- ") == nil)
        #expect(StableStreamPrefix.prefix(of: "   ") == nil)
    }

    @Test("Deltas without whitespace cannot advance the boundary")
    func boundaryAdvance() {
        #expect(!StableStreamPrefix.mayAdvanceBoundary("ing"))
        #expect(StableStreamPrefix.mayAdvanceBoundary(" the"))
        #expect(StableStreamPrefix.mayAdvanceBoundary("done "))
    }
}
