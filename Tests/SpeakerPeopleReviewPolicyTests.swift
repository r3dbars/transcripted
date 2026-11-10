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

    runSuite("SpeakerPeopleReviewPolicy keeps review work first in a large named-speaker list") {
        let namedProfiles = (0..<2_000).map { index in
            makePeopleReviewProfile(
                name: "Person \(index)",
                calls: 1 + (index % 20)
            )
        }
        let unnamedProfiles = (0..<50).map { index in
            makePeopleReviewProfile(name: nil, calls: 1 + (index % 5))
        }
        let profiles = namedProfiles + unnamedProfiles
        let duplicateIds = Set(unnamedProfiles.prefix(10).map(\.id))

        let sorted = SpeakerPeopleReviewPolicy.sortedForPeopleSettings(
            profiles,
            duplicateIds: duplicateIds
        )

        assertEqual(sorted.count, profiles.count, "speaker list sorting should keep every profile")
        assertTrue(
            sorted.prefix(50).allSatisfy { SpeakerPeopleReviewPolicy.needsReview(profile: $0, duplicateIds: duplicateIds) },
            "speaker list sorting should keep review work ahead of clean named speakers"
        )
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
