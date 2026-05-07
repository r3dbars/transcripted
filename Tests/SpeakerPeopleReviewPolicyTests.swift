import Foundation

func testSpeakerPeopleReviewPolicy() {
    runSuite("SpeakerPeopleReviewPolicy marks unnamed speakers for review") {
        let profile = makePeopleReviewProfile(name: nil)

        assertTrue(
            SpeakerPeopleReviewPolicy.needsReview(profile: profile, duplicateIds: []),
            "unnamed deferred speakers should stay visible in Needs Review"
        )
    }

    runSuite("SpeakerPeopleReviewPolicy marks disputed speakers for review") {
        let profile = makePeopleReviewProfile(name: "Alex", disputeCount: 1)

        assertTrue(
            SpeakerPeopleReviewPolicy.needsReview(profile: profile, duplicateIds: []),
            "disputed profiles should stay visible in Needs Review"
        )
    }

    runSuite("SpeakerPeopleReviewPolicy leaves clean named speakers out of review") {
        let profile = makePeopleReviewProfile(name: "Alex")

        assertFalse(
            SpeakerPeopleReviewPolicy.needsReview(profile: profile, duplicateIds: []),
            "clean named profiles should not crowd the review queue"
        )
    }

    runSuite("SpeakerPeopleReviewPolicy sorts review work before clean profiles") {
        let clean = makePeopleReviewProfile(name: "Alex", calls: 12)
        let unnamed = makePeopleReviewProfile(name: nil, calls: 1)

        let sorted = SpeakerPeopleReviewPolicy.sortedForPeopleSettings(
            [clean, unnamed],
            duplicateIds: []
        )

        assertEqual(sorted.first?.id, unnamed.id, "deferred unnamed speakers should appear first")
    }
}

private func makePeopleReviewProfile(
    name: String?,
    calls: Int = 1,
    disputeCount: Int = 0
) -> SpeakerProfile {
    SpeakerProfile(
        id: UUID(),
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: [0.1, 0.2, 0.3],
        firstSeen: Date(),
        lastSeen: Date(),
        callCount: calls,
        confidence: 0.8,
        disputeCount: disputeCount
    )
}
