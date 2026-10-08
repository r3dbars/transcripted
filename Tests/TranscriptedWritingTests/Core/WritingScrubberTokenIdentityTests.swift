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

    @Test("An old token does not pull an over-limit ordinary value into password classification")
    func oldTokenKeepsOverLimitValue() {
        let text = String(repeating: "a1B2", count: 12) + WritingSecretScrubber.token(for: .password)
        let result = WritingSecretScrubber.scrub(text, appBundleIdentifier: "com.tinyspeck.slackmacgap")
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }

    @Test("Classifiers see original lengths and repeated old tokens never report new kinds")
    func oldTokenIdentitiesPreserveLength() {
        let text = WritingSecretScrubber.Kind.allCases.map { kind in
            let token = WritingSecretScrubber.token(for: kind)
            return token + " " + token
        }.joined(separator: "\n")
        let identity = WritingScrubberTokenIdentity(text)
        #expect(identity.originalText(identity.markedText).count == text.count)
        #expect(identity.originalText(identity.markedText).utf16.count == text.utf16.count)
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
        #expect(identity.originalText(identity.markedText).count == text.count)
        let result = identity.result(from: identity.markedText)
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }

    @Test("Every three-letter marker can already exist without exhausting identity allocation")
    func saturatedShortMarkerNamespace() {
        var tokens: [String] = []
        for a in 97...122 { for b in 97...122 { for c in 97...122 {
            let kind = String(UnicodeScalar(a)!) + String(UnicodeScalar(b)!) + String(UnicodeScalar(c)!)
            tokens.append("⟨redacted:" + kind + "⟩")
        } } }
        let text = tokens.joined(separator: " ") + " " + WritingSecretScrubber.token(for: .jwt)
        let identity = WritingScrubberTokenIdentity(text)
        #expect(identity.originalText(identity.markedText) == text)
        let result = identity.result(from: identity.markedText)
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }

}
