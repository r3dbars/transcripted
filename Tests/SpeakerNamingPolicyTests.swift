import Foundation

func testSpeakerNamingPolicy() {
    runSuite("SpeakerNamingPolicy.initialMapping keeps tentative matches generic") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 4,
            confidence: 0.8,
            disputeCount: 0
        )

        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0",
            profile: profile,
            similarity: 0.97
        )

        assertNil(mapping.identifiedName, "tentative matches should stay generic until the user confirms them")
        assertEqual(mapping.displayName, "Speaker 0", "tentative matches should not rewrite the transcript label")
    }

    runSuite("SpeakerNamingPolicy.initialMapping auto-applies mature high-confidence matches") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 6,
            confidence: 0.9,
            disputeCount: 0
        )

        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0",
            profile: profile,
            similarity: 0.91
        )

        assertEqual(mapping.identifiedName, "Alex", "strong repeated matches should still auto-apply")
        assertEqual(mapping.displayName, "Alex", "auto-applied names should render without a tentative suffix")
        assertEqual(mapping.confidence, .high, "strong repeated matches should be marked high confidence")
    }

    runSuite("SpeakerNamingPolicy.initialMapping keeps disputed profiles generic") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 8,
            confidence: 0.9,
            disputeCount: 1
        )

        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0",
            profile: profile,
            similarity: 0.95
        )

        assertNil(mapping.identifiedName, "disputed profiles should not auto-apply")
        assertEqual(mapping.displayName, "Speaker 0", "disputed profiles should stay generic until repaired")
    }
}
