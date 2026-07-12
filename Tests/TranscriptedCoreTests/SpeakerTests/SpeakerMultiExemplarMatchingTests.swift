import XCTest
import Foundation
@testable import TranscriptedCore

/// End-to-end (DB write → read → match) coverage for multi-exemplar voiceprints, plus the
/// backward-compatibility guarantee that a legacy single-average profile matches exactly as before.
@available(macOS 14.0, *)
final class SpeakerMultiExemplarMatchingTests: XCTestCase {

    private func tmpDB() -> SpeakerDatabase {
        SpeakerDatabase(path: NSTemporaryDirectory() + "spk_exemplar_\(UUID().uuidString).sqlite")
    }

    private func vec(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> [Float] {
        SpeakerVectorMath.l2Normalize([a, b, c, d])
    }

    // MARK: - Backward compatibility (single-average / no exemplars)

    func testLegacyProfileWithoutExemplarsMatchesUnchanged() {
        let db = tmpDB()
        let a = vec(1, 0, 0, 0)
        let profile = db.addOrUpdateSpeaker(embedding: a, existingId: nil)

        // Fresh profile has no exemplars; a near-A candidate matches on the single average exactly
        // as it did before this feature.
        XCTAssertTrue(db.allSpeakers().allSatisfy { $0.exemplars.isEmpty })
        let match = db.matchSpeaker(embedding: vec(0.98, 0.02, 0, 0), threshold: 0.6)
        XCTAssertEqual(match?.profile.id, profile.id)
    }

    func testMatchAgainstProfilesEmptyExemplarsEqualsSingleCosine() {
        let a = vec(1, 0, 0, 0)
        let profile = SpeakerProfile(
            id: UUID(), displayName: "A", nameSource: nil, embedding: a,
            firstSeen: Date(), lastSeen: Date(), callCount: 10, confidence: 0.9, disputeCount: 0)
        // A candidate orthogonal to the only representative must not match — exemplars can't help.
        XCTAssertNil(Transcription.matchAgainstProfiles(vec(0, 1, 0, 0), profiles: [profile], threshold: 0.6))
        // A near-A candidate matches.
        XCTAssertNotNil(Transcription.matchAgainstProfiles(vec(0.95, 0.05, 0, 0), profiles: [profile], threshold: 0.6))
    }

    // MARK: - Multi-exemplar benefit

    // A profile that has seen two distinct capture conditions matches a candidate from the SECOND
    // condition via its exemplar — where the single blended average alone would fall below threshold.
    func testDistinctConditionMatchesViaExemplarNotAverage() {
        let db = tmpDB()
        let condition1 = vec(1, 0, 0, 0)   // e.g. clean in-person mic
        let condition2 = vec(0, 1, 0, 0)   // e.g. compressed remote mic

        let profile = db.addOrUpdateSpeaker(embedding: condition1, existingId: nil)
        // A confident write-back of a distinct second condition into the same profile.
        _ = db.addOrUpdateSpeaker(embedding: condition2, existingId: profile.id)

        // The exemplar was persisted and reloads on read.
        let reloaded = db.getSpeaker(id: profile.id)
        XCTAssertEqual(reloaded?.exemplars.count, 1, "The distinct second condition should be stored as an exemplar")

        // The blended average now sits mostly on condition1; a condition2-like candidate is far from it.
        let average = reloaded!.embedding
        let candidate = vec(0.1, 0.99, 0, 0)
        let avgSimilarity = SpeakerVectorMath.cosineSimilarity(candidate, average)
        XCTAssertLessThan(avgSimilarity, 0.6, "Precondition: the single average alone would miss this candidate")

        // With the exemplar, the candidate matches back to the same person.
        let match = db.matchSpeaker(embedding: candidate, threshold: 0.6)
        XCTAssertEqual(match?.profile.id, profile.id)
        XCTAssertGreaterThan(match?.similarity ?? 0, avgSimilarity)
    }

    // matchAgainstProfiles (the in-memory snapshot path used by the pipeline and eval harness)
    // scores against the best-fitting exemplar while preserving the dimension guard.
    func testSnapshotMatchUsesBestExemplar() {
        let profile = SpeakerProfile(
            id: UUID(), displayName: "Multi", nameSource: nil, embedding: vec(1, 0, 0, 0),
            firstSeen: Date(), lastSeen: Date(), callCount: 10, confidence: 0.9, disputeCount: 0,
            exemplars: [vec(0, 1, 0, 0)])

        // Near the exemplar (far from the average) → matches via the exemplar.
        let viaExemplar = Transcription.matchAgainstProfiles(vec(0.1, 0.99, 0, 0), profiles: [profile], threshold: 0.6)
        XCTAssertEqual(viaExemplar?.profileId, profile.id)

        // Near the average → still matches via the average.
        let viaAverage = Transcription.matchAgainstProfiles(vec(0.99, 0.1, 0, 0), profiles: [profile], threshold: 0.6)
        XCTAssertEqual(viaAverage?.profileId, profile.id)

        // Orthogonal to every representative → no match.
        XCTAssertNil(Transcription.matchAgainstProfiles(vec(0, 0, 1, 0), profiles: [profile], threshold: 0.6))
    }

    // Ambiguous / weak matches freeze the average (alpha 0); they must not seed an exemplar either.
    func testFrozenWriteBackDoesNotCreateExemplar() {
        let db = tmpDB()
        let profile = db.addOrUpdateSpeaker(embedding: vec(1, 0, 0, 0), existingId: nil)
        // alpha 0 == frozen (ambiguous match): record the appearance without touching the voiceprint.
        _ = db.addOrUpdateSpeaker(embedding: vec(0, 1, 0, 0), existingId: profile.id, blendAlpha: 0)
        XCTAssertEqual(db.getSpeaker(id: profile.id)?.exemplars.count, 0, "Frozen write-back must not create an exemplar")
    }

    // Deleting a profile removes its exemplar rows (no orphans).
    func testDeleteProfileRemovesExemplars() {
        let db = tmpDB()
        let profile = db.addOrUpdateSpeaker(embedding: vec(1, 0, 0, 0), existingId: nil)
        _ = db.addOrUpdateSpeaker(embedding: vec(0, 1, 0, 0), existingId: profile.id)
        XCTAssertEqual(db.getSpeaker(id: profile.id)?.exemplars.count, 1)
        db.deleteSpeaker(id: profile.id)
        let fresh = db.addOrUpdateSpeaker(embedding: vec(1, 0, 0, 0), existingId: nil)
        XCTAssertTrue(fresh.exemplars.isEmpty, "A new profile must not inherit a deleted one's exemplars")
    }
}
