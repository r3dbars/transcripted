import Foundation

func testSpeakerDuplicateSnapshotCache() {
    let detect: ([SpeakerProfile]) -> [SpeakerDuplicateCandidate] = { profiles in
        SpeakerDuplicateDetection.duplicateCandidates(from: profiles) { lhs, rhs in
            guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
            return SpeakerVectorMath.cosineSimilarity(lhs, rhs)
        }
    }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = SpeakerProfile(
        id: UUID(), displayName: "José Rivera", nameSource: "user_manual",
        embedding: [1, 0], firstSeen: date, lastSeen: date,
        callCount: 3, confidence: 0.9, disputeCount: 0
    )
    let peer = SpeakerProfile(
        id: UUID(), displayName: "Different Name", nameSource: nil,
        embedding: [1, 0], firstSeen: date, lastSeen: date,
        callCount: 1, confidence: 0.8, disputeCount: 0
    )

    runSuite("Unchanged speaker snapshots reuse the all-pairs result") {
        let cache = SpeakerDuplicateSnapshotCache()
        var builds = 0
        let build: ([SpeakerProfile]) -> [SpeakerDuplicateCandidate] = { profiles in
            builds += 1
            return detect(profiles)
        }
        let first = cache.candidates(from: [original, peer], build: build)
        let again = cache.candidates(from: [original, peer], build: build)
        assertEqual(builds, 1, "reopen and trailing requests do not recompute the same profiles")
        assertEqual(again.map(\.id), first.map(\.id))
        assertEqual(first.first?.reason, .voiceMatch, "different names still match the same voice")
        assertEqual(first.first?.target.id, original.id, "the higher call count remains the merge target")
        assertEqual(first.first?.voiceSimilarity, 1)
    }

    runSuite("Every profile change invalidates cached candidate payloads") {
        let mutations: [(String, (inout SpeakerProfile) -> Void)] = [
            ("display name", { $0.displayName = "Casey" }),
            ("name source", { $0.nameSource = "calendar" }),
            ("embedding", { $0.embedding = [0, 1] }),
            ("exemplars", { $0.exemplars = [[0, 1]] }),
            ("first seen", { $0.firstSeen = date.addingTimeInterval(1) }),
            ("last seen", { $0.lastSeen = date.addingTimeInterval(1) }),
            ("call count", { $0.callCount = 0 }),
            ("confirmed meetings", { $0.confirmedMeetingCount = 4 }),
            ("confidence", { $0.confidence = 0.3 }),
            ("disputes", { $0.disputeCount = 1 }),
        ]
        for (name, mutate) in mutations {
            let cache = SpeakerDuplicateSnapshotCache()
            var builds = 0
            let build: ([SpeakerProfile]) -> [SpeakerDuplicateCandidate] = { profiles in
                builds += 1
                return detect(profiles)
            }
            _ = cache.candidates(from: [original, peer], build: build)
            var changed = original
            mutate(&changed)
            let actual = cache.candidates(from: [changed, peer], build: build)
            let expected = detect([changed, peer])
            assertEqual(builds, 2, "\(name) must not reuse stale embedded profiles")
            assertEqual(actual.map(\.id), expected.map(\.id), name)
            assertEqual(actual.map(\.reason), expected.map(\.reason), name)
            assertEqual(actual.map(\.voiceSimilarity), expected.map(\.voiceSimilarity), name)
            if name == "disputes" || name == "embedding" {
                assertTrue(actual.isEmpty, "the voice-only match must disappear after \(name) changes")
            }
        }
    }

    runSuite("Speaker deletion, insertion, and order changes cannot reuse old candidates") {
        let cache = SpeakerDuplicateSnapshotCache()
        assertEqual(cache.candidates(from: [original, peer], build: detect).count, 1)
        assertTrue(cache.candidates(from: [original], build: detect).isEmpty, "deleted speakers disappear")
        assertEqual(cache.candidates(from: [peer, original], build: detect).count, 1, "insertions are compared again")
        assertEqual(cache.candidates(from: [original, peer], build: detect).first?.target.id, original.id)
    }
}
