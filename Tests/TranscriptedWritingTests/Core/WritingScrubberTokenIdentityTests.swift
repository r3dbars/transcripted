import Testing
@testable import TranscriptedWritingCore

@Suite("Old redaction identities preserve classification")
struct WritingScrubberTokenIdentityTests {
    @Test("Old tokens do not move password-shaped values across the length limit", arguments: [9, 10, 11])
    func oldTokenKeepsPasswordLength(repetitions: Int) {
        let token = WritingSecretScrubber.token(for: .password)
        let text = String(repeating: "a1B2", count: repetitions) + token
        let result = WritingSecretScrubber.scrub(text, appBundleIdentifier: "com.tinyspeck.slackmacgap")
        #expect(result.clean == token)
        #expect(result.kinds == [.password])
        #expect(result.isOnlyRedactions)
        #expect(WritingSecretScrubber.scrub(result.clean, appBundleIdentifier: "com.tinyspeck.slackmacgap").kinds.isEmpty)
    }

    @Test("Token identities preserve lengths and restore repeated old tokens without new kinds")
    func oldTokenIdentitiesPreserveLength() {
        let text = WritingSecretScrubber.Kind.allCases.map { kind in
            let token = WritingSecretScrubber.token(for: kind)
            return token + " " + token
        }.joined(separator: "\n")
        let identity = WritingScrubberTokenIdentity(text)
        #expect(identity.markedText.count == text.count)
        #expect(identity.markedText.utf16.count == text.utf16.count)
        let restored = identity.result(from: identity.markedText)
        #expect(restored.clean == text)
        #expect(restored.kinds.isEmpty)
    }

    @Test("Input that resembles private identities is preserved without marker collisions")
    func markerLikeInputIsPreserved() {
        let text = "⟨redacted:paaaaaaa⟩ ⟨redacted:aaa⟩ "
            + WritingSecretScrubber.token(for: .password) + " "
            + WritingSecretScrubber.token(for: .jwt)
        let identity = WritingScrubberTokenIdentity(text)
        #expect(identity.markedText.count == text.count)
        let result = identity.result(from: identity.markedText)
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }
}
