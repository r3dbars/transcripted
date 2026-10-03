import Foundation

func testSpeakerPeopleSortOrder() {
    runSuite("Speakers list order: review work, then unnamed, then most calls, then most recent") {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func profile(
            _ name: String?,
            calls: Int,
            daysAgo: Double,
            disputes: Int = 0
        ) -> SpeakerProfile {
            SpeakerProfile(
                id: UUID(),
                displayName: name,
                nameSource: name == nil ? nil : NameSource.userManual,
                embedding: [0.1, 0.2, 0.3],
                firstSeen: now.addingTimeInterval(-90 * 86_400),
                lastSeen: now.addingTimeInterval(-daysAgo * 86_400),
                callCount: calls,
                confidence: 0.8,
                disputeCount: disputes
            )
        }

        let cleanFew = profile("Alex", calls: 2, daysAgo: 1)
        let cleanMany = profile("Blair", calls: 9, daysAgo: 5)
        let cleanManyRecent = profile("Casey", calls: 9, daysAgo: 1)
        let disputed = profile("Drew", calls: 20, daysAgo: 1, disputes: 1)
        let duplicate = profile("Emery", calls: 3, daysAgo: 2)
        let unnamedOld = profile(nil, calls: 4, daysAgo: 30)
        let blankName = profile("   \n", calls: 4, daysAgo: 3)
        let unnamedBusy = profile(nil, calls: 7, daysAgo: 10)

        let sorted = SpeakerPeopleReviewPolicy.sortedForPeopleSettings(
            [cleanFew, cleanMany, unnamedOld, disputed, cleanManyRecent, blankName, duplicate, unnamedBusy],
            duplicateIds: [duplicate.id]
        )

        // Review work first, unnamed (a whitespace-only name counts as
        // unnamed) ahead of named, then more calls, then the newer one.
        let expected = [unnamedBusy, blankName, unnamedOld, disputed, duplicate, cleanManyRecent, cleanMany, cleanFew]
        assertEqual(sorted.map(\.id), expected.map(\.id), "Speakers list order changed")

        let reordered = SpeakerPeopleReviewPolicy.sortedForPeopleSettings(
            [duplicate, cleanFew, blankName, cleanManyRecent, unnamedBusy, disputed, cleanMany, unnamedOld],
            duplicateIds: [duplicate.id]
        )
        assertEqual(reordered.map(\.id), expected.map(\.id), "order should not depend on the input order")
    }
}
