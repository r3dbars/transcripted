import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

func testSpeakerMergeTargets() {
    runSuite("Merge Into lists every other saved person once: duplicates first, then A to Z ignoring case, same name by most meetings") {
        let bob = makeMergeTargetProfile("bob", calls: 2)
        let alice1 = makeMergeTargetProfile("Alice", calls: 1)
        let alice5 = makeMergeTargetProfile("Alice", calls: 5)
        let carol = makeMergeTargetProfile("Carol", calls: 4)
        let unnamed3 = makeMergeTargetProfile(nil, calls: 3)
        let unnamed7 = makeMergeTargetProfile(nil, calls: 7)
        let dave = makeMergeTargetProfile("Dave", calls: 1)
        let ava = makeMergeTargetProfile("Ava", calls: 3)
        let profiles = [bob, alice1, alice5, carol, unnamed3, unnamed7, dave, ava]
        let peers: [UUID: Set<UUID>] = [
            alice5.id: [alice1.id, ava.id],
            alice1.id: [alice5.id],
            ava.id: [alice5.id],
        ]
        let index = SpeakerMergeTargetIndex(profiles: profiles, duplicatePeerIDsByProfileID: peers)

        assertEqual(
            index.targets(for: alice5.id).map(\.id),
            [alice1.id, ava.id, bob.id, carol.id, dave.id, unnamed7.id, unnamed3.id],
            "possible duplicates come first, then everyone else by name"
        )
        assertEqual(
            index.targets(for: alice1.id).map(\.id),
            [alice5.id, ava.id, bob.id, carol.id, dave.id, unnamed7.id, unnamed3.id],
            "one duplicate peer first, never the person themselves"
        )
        assertEqual(
            index.targets(for: unnamed7.id).map(\.id),
            [alice5.id, alice1.id, ava.id, bob.id, carol.id, dave.id, unnamed3.id],
            "unnamed voices sort as Unknown voice; same name keeps most meetings first"
        )
        assertEqual(
            index.targets(for: dave.id).map(\.id),
            [alice5.id, alice1.id, ava.id, bob.id, carol.id, unnamed7.id, unnamed3.id]
        )
        assertEqual(index.targets(for: dave.id).count, profiles.count - 1)
        assertTrue(index.targets(for: UUID()).isEmpty, "a person missing from the snapshot has no merge targets")
        assertTrue(
            SpeakerMergeTargetIndex(profiles: [bob], duplicatePeerIDsByProfileID: [:]).targets(for: bob.id).isEmpty,
            "a lone saved person has nobody to merge into"
        )
    }

    runSuite("Merge Into order matches the per-person sort for every person, across seeded random libraries") {
        let consistentNames: [String?] = [
            nil, "Unknown voice", "", "Alice", "Ava", "Bob", "Émile", "Emil", "Zoë", "Zoe Smith",
            "carol", "Dave", "Ödön", "Oscar", "Sam-Lee", "Lee Sam",
        ]
        let variantNames: [String?] = consistentNames + ["alice", "BOB", "unknown voice", "Straße", "Strasse"]
        var generator = MergeTargetSeededGenerator(seed: 0x5EED)
        for (pool, sizes) in [(consistentNames, [2, 5, 17, 60, 300]), (variantNames, [5, 17, 60, 150])] {
            for size in sizes {
                let profiles = (0..<size).map { _ in
                    makeMergeTargetProfile(
                        pool[Int(generator.next() % UInt64(pool.count))],
                        calls: Int(generator.next() % 4)
                    )
                }
                var peers: [UUID: Set<UUID>] = [:]
                for _ in 0..<(size / 3) {
                    let lhs = profiles[Int(generator.next() % UInt64(size))].id
                    let rhs = profiles[Int(generator.next() % UInt64(size))].id
                    guard lhs != rhs else { continue }
                    peers[lhs, default: []].insert(rhs)
                    peers[rhs, default: []].insert(lhs)
                }
                let index = SpeakerMergeTargetIndex(profiles: profiles, duplicatePeerIDsByProfileID: peers)
                for profile in profiles {
                    let expected = mergeTargetOracle(for: profile, in: profiles, duplicatePeerIds: peers[profile.id] ?? [])
                    let actual = index.targets(for: profile.id)
                    assertEqual(actual.map(\.id), expected.map(\.id), "size \(size): order differs from the per-person sort")
                    assertEqual(actual.count, expected.count)
                }
            }
        }
    }

    runSuite("Names that differ only by case keep the exact per-person order") {
        assertTrue(SpeakerMergeTargetIndex.hasCaseVariantNames(["Alice", "Bob", "alice"]))
        assertTrue(SpeakerMergeTargetIndex.hasCaseVariantNames(["unknown voice", "Unknown voice"]))
        assertFalse(SpeakerMergeTargetIndex.hasCaseVariantNames(["Alice", "Bob", "Alice", "Unknown voice"]))

        let typed = makeMergeTargetProfile("unknown voice", calls: 2)
        let unnamed = makeMergeTargetProfile(nil, calls: 9)
        let named = makeMergeTargetProfile("Unknown voice", calls: 4)
        let other = makeMergeTargetProfile("Zed", calls: 1)
        let profiles = [typed, unnamed, named, other]
        let index = SpeakerMergeTargetIndex(profiles: profiles, duplicatePeerIDsByProfileID: [:])
        for profile in profiles {
            assertEqual(
                index.targets(for: profile.id).map(\.id),
                mergeTargetOracle(for: profile, in: profiles, duplicatePeerIds: []).map(\.id)
            )
        }
    }

    runSuite("Duplicate scan reasons: same name, similar names, and voice matches") {
        func reason(_ lhs: String?, _ rhs: String?, voice: Double?, lhsDisputes: Int = 0) -> SpeakerDuplicateReason? {
            SpeakerDuplicateMatchPolicy.reason(
                SpeakerDuplicateNameKey(displayName: lhs),
                SpeakerDuplicateNameKey(displayName: rhs),
                lhsDisputeCount: lhsDisputes,
                rhsDisputeCount: 0,
                voiceSimilarity: voice
            )
        }
        assertEqual(reason(" Alice ", "alice", voice: nil), .sameName, "trimmed, case-insensitive same name")
        assertEqual(reason("Alice", "alice", voice: 0.95), .sameNameAndVoice)
        assertEqual(reason("Alice Smith", "alice", voice: nil), .similarName, "one name contains the other")
        assertEqual(reason("Sam-Lee", "Lee Sam", voice: nil), .similarName, "same name tokens in another order")
        assertEqual(reason("Sam-Lee", "Lee Sam", voice: 0.91), .similarNameAndVoice)
        assertNil(reason("Alice", "Bob", voice: 0.93), "different names need 0.96 to count as one voice")
        assertEqual(reason("Alice", "Bob", voice: 0.96), .voiceMatch)
        assertEqual(reason(nil, nil, voice: 0.93), .voiceMatch, "unnamed voices only need 0.90")
        assertNil(reason(nil, "  ", voice: 0.89))
        assertNil(reason(nil, nil, voice: 0.99, lhsDisputes: 1), "a disputed profile never voice-matches")
        assertNil(reason("Al", "Al Smith", voice: nil), "names under 3 letters don't count as related")
        assertNil(reason("Alice", "Bob", voice: nil))
    }
}

/// Test-local copy of the per-person comparator the Speakers page has always used.
private func mergeTargetOracle(
    for profile: SpeakerProfile,
    in profiles: [SpeakerProfile],
    duplicatePeerIds: Set<UUID>
) -> [SpeakerProfile] {
    profiles.filter { $0.id != profile.id }.sorted { lhs, rhs in
        let lhsIsDuplicate = duplicatePeerIds.contains(lhs.id)
        let rhsIsDuplicate = duplicatePeerIds.contains(rhs.id)
        if lhsIsDuplicate != rhsIsDuplicate {
            return lhsIsDuplicate && !rhsIsDuplicate
        }
        let lhsName = lhs.displayName ?? "Unknown voice"
        let rhsName = rhs.displayName ?? "Unknown voice"
        if lhsName == rhsName {
            return lhs.callCount > rhs.callCount
        }
        return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
    }
}

private struct MergeTargetSeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private func makeMergeTargetProfile(_ name: String?, calls: Int) -> SpeakerProfile {
    SpeakerProfile(
        id: UUID(),
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: [0.1, 0.2, 0.3],
        firstSeen: Date(timeIntervalSince1970: 0),
        lastSeen: Date(timeIntervalSince1970: 0),
        callCount: calls,
        confidence: 0.8,
        disputeCount: 0
    )
}
