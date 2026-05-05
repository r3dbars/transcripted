import Foundation

func testSpeakerDuplicateReviewPolicy() {
    runSuite("SpeakerDuplicateReviewPolicy ignores generic speaker-name tokens") {
        let first = speakerProfile(name: "Speaker A", embedding: [1, 0, 0], callCount: 2)
        let second = speakerProfile(name: "Speaker B", embedding: [0, 1, 0], callCount: 2)
        let third = speakerProfile(name: "Unknown speaker", embedding: [0, 0, 1], callCount: 2)
        let fourth = speakerProfile(name: "Unknown speaker 2", embedding: [0.5, 0.5, 0], callCount: 2)

        let candidates = SpeakerDuplicateReviewPolicy.candidates(from: [first, second, third, fourth])

        assertEqual(candidates.count, 0, "generic labels should not look related just because both contain speaker")
    }

    runSuite("SpeakerDuplicateReviewPolicy flags same saved name as possible duplicate") {
        let older = speakerProfile(
            name: "Alex",
            embedding: [1, 0, 0],
            callCount: 3,
            lastSeen: Date(timeIntervalSince1970: 10)
        )
        let newer = speakerProfile(
            name: "Alex",
            embedding: [0, 1, 0],
            callCount: 9,
            lastSeen: Date(timeIntervalSince1970: 20)
        )

        let candidates = SpeakerDuplicateReviewPolicy.candidates(from: [older, newer])

        assertEqual(candidates.count, 1)
        assertEqual(candidates[0].reason, .sameName)
        assertEqual(candidates[0].target.id, newer.id, "the higher-call profile should be the default keeper")
    }

    runSuite("SpeakerDuplicateReviewPolicy holds voice-only matches out of the default queue") {
        let first = speakerProfile(name: "Alex", embedding: [1, 0, 0], callCount: 3)
        let weakConflict = speakerProfile(name: "Jordan", embedding: [0.94, 0.35, 0], callCount: 3)
        let strongConflict = speakerProfile(name: "Taylor", embedding: [0.99, 0.01, 0], callCount: 3)

        let weakCandidates = SpeakerDuplicateReviewPolicy.candidates(from: [first, weakConflict])
        let strongCandidates = SpeakerDuplicateReviewPolicy.candidates(from: [first, strongConflict])

        assertEqual(weakCandidates.count, 0, "conflicting names need very strong voice similarity")
        assertEqual(strongCandidates.count, 0, "voice-only pairs are not safe enough for the default duplicate queue")
    }

    runSuite("SpeakerDuplicateReviewPolicy keeps the queue capped for the settings surface") {
        assertEqual(SpeakerDuplicateReviewPolicy.maxVisibleCandidates, 25)
    }
}

private func speakerProfile(
    name: String?,
    embedding: [Float],
    callCount: Int,
    lastSeen: Date = Date(timeIntervalSince1970: 10)
) -> SpeakerProfile {
    SpeakerProfile(
        id: UUID(),
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: embedding,
        firstSeen: Date(timeIntervalSince1970: 0),
        lastSeen: lastSeen,
        callCount: callCount,
        confidence: 0.8,
        disputeCount: 0
    )
}
