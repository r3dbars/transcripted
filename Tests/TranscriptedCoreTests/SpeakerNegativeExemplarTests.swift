import XCTest
@testable import TranscriptedCore

/// Proves the negative-exemplar signal end to end: a correction records the rejected embedding
/// against the wrongly-suggested profile, and a later similar embedding is excluded from that
/// profile while still matching the correct one — even after the profile's dispute freeze is
/// cleared (the durable learning the dispute count alone does not provide).
@available(macOS 14.0, *)
final class SpeakerNegativeExemplarTests: XCTestCase {

    // MARK: - Store round-trip + retention

    func testRecordAndReadNegativeExemplars() {
        let (db, _) = makeDatabase()
        let profileId = UUID()

        db.recordNegativeExemplar(profileId: profileId, embedding: vector(degrees: 19))

        XCTAssertEqual(db.negativeExemplars(profileId: profileId).count, 1)
        XCTAssertEqual(db.negativeExemplarsByProfile()[profileId]?.count, 1)
        // Stored normalized, so a same-direction candidate reads back at cosine ~1.
        let stored = db.negativeExemplars(profileId: profileId)[0]
        XCTAssertEqual(SpeakerVectorMath.cosineSimilarity(stored, vector(degrees: 19)), 1.0, accuracy: 0.001)
    }

    func testEmptyEmbeddingIsNotRecorded() {
        let (db, _) = makeDatabase()
        let profileId = UUID()

        db.recordNegativeExemplar(profileId: profileId, embedding: [])

        XCTAssertTrue(db.negativeExemplars(profileId: profileId).isEmpty)
    }

    func testRetentionCapsPerProfile() {
        let (db, _) = makeDatabase()
        let profileId = UUID()
        let cap = SpeakerDatabase.negativeExemplarRetentionPerProfile

        for degree in 0..<(cap + 12) {
            db.recordNegativeExemplar(profileId: profileId, embedding: vector(degrees: Float(degree)))
        }

        XCTAssertEqual(db.negativeExemplars(profileId: profileId).count, cap)
    }

    func testDeletingSpeakerRemovesNegativeExemplars() {
        let (db, _) = makeDatabase()
        let profile = db.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        db.recordNegativeExemplar(profileId: profile.id, embedding: vector(degrees: 19))

        db.deleteSpeaker(id: profile.id)

        XCTAssertNil(db.getSpeaker(id: profile.id))
        XCTAssertTrue(
            db.negativeExemplars(profileId: profile.id).isEmpty,
            "deleting a profile must delete its identity-bound negative embeddings"
        )
        XCTAssertNil(db.negativeExemplarsByProfile()[profile.id])
    }

    // MARK: - In-memory matcher veto (matchAgainstProfiles)

    func testNegativeExemplarExcludesWrongProfileButKeepsCorrectMatch() {
        // Alice at 0°, Bob at 55°, both mature and un-disputed. A voice at 21° is genuinely closer
        // to Alice than to Bob, so without any signal it matches Alice.
        let alice = profile(embedding: vector(degrees: 0), callCount: 6)
        let bob = profile(embedding: vector(degrees: 55), callCount: 6)
        let profiles = [alice, bob]
        let returningVoice = vector(degrees: 21)

        let withoutSignal = Transcription.matchAgainstProfiles(returningVoice, profiles: profiles, threshold: 0.70)
        XCTAssertEqual(withoutSignal?.profileId, alice.id, "control: voice matches Alice with no negative exemplar")

        // A prior correction recorded this voice (≈19°) as "not Alice".
        let negatives: [UUID: [[Float]]] = [alice.id: [vector(degrees: 19)]]
        let withSignal = Transcription.matchAgainstProfiles(
            returningVoice,
            profiles: profiles,
            threshold: 0.70,
            negativeExemplarsByProfile: negatives
        )
        XCTAssertEqual(withSignal?.profileId, bob.id, "veto flips the wrongly-suggested Alice to Bob")
    }

    func testGenuineVoiceStillMatchesDespiteNegativeExemplar() {
        // The negative exemplar on Alice must not block a genuine Alice voice: a voice clearly closer
        // to Alice's fingerprint (2°) than to the rejected sample (19°) is trusted, not vetoed.
        let alice = profile(embedding: vector(degrees: 0), callCount: 6)
        let negatives: [UUID: [[Float]]] = [alice.id: [vector(degrees: 19)]]

        let match = Transcription.matchAgainstProfiles(
            vector(degrees: 2),
            profiles: [alice],
            threshold: 0.70,
            negativeExemplarsByProfile: negatives
        )

        XCTAssertEqual(match?.profileId, alice.id)
    }

    // MARK: - Persistent matcher veto (matchSpeaker) — survives dispute reset

    func testMatchSpeakerVetoesProfileWithNegativeExemplarEvenWhenUndisputed() {
        let (db, _) = makeDatabase()
        let alice = db.addOrUpdateSpeaker(embedding: vector(degrees: 0))
        let bob = db.addOrUpdateSpeaker(embedding: vector(degrees: 55))
        let returningVoice = vector(degrees: 21)

        // Control: closest profile is Alice.
        XCTAssertEqual(db.matchSpeaker(embedding: returningVoice, threshold: 0.6)?.profile.id, alice.id)

        // Record the rejection, then (crucially) leave Alice un-disputed — the dispute freeze the
        // matcher already honors is NOT what excludes her here; the negative exemplar is.
        db.recordNegativeExemplar(profileId: alice.id, embedding: vector(degrees: 19))
        XCTAssertEqual(db.getSpeaker(id: alice.id)?.disputeCount, 0)

        XCTAssertEqual(
            db.matchSpeaker(embedding: returningVoice, threshold: 0.6)?.profile.id,
            bob.id,
            "un-disputed Alice is still vetoed by her negative exemplar; Bob wins"
        )
    }

    // MARK: - End to end through the real correction path (simulation harness)

    func testCorrectionRecordsNegativeExemplarThatSurvivesRepairAndMatchesCorrectPerson() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NegativeExemplarE2E-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        // Pat is a known speaker with a fingerprint at 160°. Drew's voice sits at 150° — close
        // enough to wrongly auto-match Pat (cos 10° ≈ 0.985, above the match floor), which is exactly
        // the marginal confusable case the user corrects. Keeping Drew's voice OFFSET from Pat's
        // fingerprint (not identical) mirrors reality: the returning voice is far more similar to its
        // own rejected sample (≈1.0) than to Pat (0.985), so the veto fires robustly.
        let patFingerprint = vector(degrees: 160)
        let drewVoice = vector(degrees: 150)
        let suite = SpeakerNamingSimulationSuite(
            name: "negative-exemplar-correction",
            knownSpeakers: [
                SpeakerNamingSimulationKnownSpeaker(displayName: "Pat Chen", embedding: patFingerprint, callCount: 7)
            ],
            meetings: [
                SpeakerNamingSimulationMeeting(
                    id: "wrong-match-corrected",
                    title: "Wrong Match Corrected",
                    segments: (0..<4).map { index in
                        SpeakerNamingSimulationSegment(
                            channel: .system,
                            diarizerSpeakerId: 1,
                            truthSpeakerId: "drew",
                            expectedDisplayName: "Drew Keeper",
                            text: "line \(index)",
                            start: TimeInterval(index) * 3,
                            embedding: drewVoice
                        )
                    },
                    actions: [
                        .correct(channel: .system, diarizerSpeakerId: 1, from: "Pat Chen", to: "Drew Keeper")
                    ]
                )
            ],
            minimumExactLabelAccuracy: 0.0
        )

        _ = try SpeakerNamingSimulationRunner(workingDirectory: workingDirectory).run(suite)

        // Reopen the harness's speaker DB to inspect what the correction persisted.
        let speakerDBPath = workingDirectory
            .appendingPathComponent("speaker-naming-simulation-run", isDirectory: true)
            .appendingPathComponent("state/speakers.sqlite")
        let db = SpeakerDatabase(path: speakerDBPath.path)

        let pat = try XCTUnwrap(db.allSpeakers().first { $0.displayName == "Pat Chen" }, "Pat profile persisted")
        let drew = try XCTUnwrap(db.allSpeakers().first { $0.displayName == "Drew Keeper" }, "corrected-to Drew profile created")

        // 1. The correction created a negative exemplar against the wrongly-suggested Pat.
        XCTAssertFalse(db.negativeExemplars(profileId: pat.id).isEmpty, "correction recorded a negative exemplar on Pat")

        // 2. Simulate a later repair that clears Pat's dispute freeze. The negative exemplar must
        //    outlive it — otherwise the wrong voice would re-match Pat once un-frozen.
        db.resetDisputeCount(id: pat.id)
        XCTAssertEqual(db.getSpeaker(id: pat.id)?.disputeCount, 0)

        // 3. The same voice returns: it is excluded from Pat and matches the correct person (Drew).
        let result = db.matchSpeaker(embedding: drewVoice, threshold: 0.6)
        XCTAssertEqual(result?.profile.id, drew.id, "returning voice matches Drew, not the vetoed Pat")
        XCTAssertNotEqual(result?.profile.id, pat.id)
    }

    // MARK: - Helpers

    private func makeDatabase() -> (db: SpeakerDatabase, path: String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNegativeExemplarTests-\(UUID().uuidString).sqlite")
            .path
        return (SpeakerDatabase(path: path), path)
    }

    private func profile(embedding: [Float], callCount: Int) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            displayName: "Known Speaker",
            nameSource: NameSource.userManual,
            embedding: embedding,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: callCount,
            confidence: 0.8,
            disputeCount: 0
        )
    }

    private func vector(degrees: Float) -> [Float] {
        let radians = degrees * .pi / 180
        return [cos(radians), sin(radians)]
    }
}
