import XCTest
import Foundation
@testable import TranscriptedCore

/// The ERes2Net swap introduces 192-d embeddings alongside the legacy 256-d
/// WeSpeaker profiles. These tests prove the safety invariant: a 192-d vector and
/// a 256-d vector can never match or blend together, so mixing models cannot
/// corrupt a SpeakerProfile or produce a false identity match.
@available(macOS 14.0, *)
final class SpeakerDBDimensionIsolationTests: XCTestCase {

    private func tmpDB() -> SpeakerDatabase {
        SpeakerDatabase(path: NSTemporaryDirectory() + "spk_dim_\(UUID().uuidString).sqlite")
    }

    private func vec(_ value: Float, _ dim: Int) -> [Float] {
        ERes2NetEmbedder.l2Normalize(Array(repeating: value, count: dim))
    }

    func testStoresEachDimensionFaithfully() {
        let db = tmpDB()
        let p192 = db.addOrUpdateSpeaker(embedding: vec(0.1, 192), existingId: nil)
        let p256 = db.addOrUpdateSpeaker(embedding: vec(0.1, 256), existingId: nil)
        XCTAssertEqual(Set(db.allSpeakers().map { $0.embedding.count }), [192, 256])
        XCTAssertEqual(db.getSpeaker(id: p192.id)?.embedding.count, 192)
        XCTAssertEqual(db.getSpeaker(id: p256.id)?.embedding.count, 256)
    }

    func testCrossDimCosineIsZero() {
        XCTAssertEqual(Transcription.cosineSimilarityStatic(vec(0.1, 192), vec(0.1, 256)), 0.0)
    }

    func testCrossDimSnapshotMatchReturnsNil() {
        let profile256 = SpeakerProfile(
            id: UUID(), displayName: "Existing", nameSource: nil, embedding: vec(0.1, 256),
            firstSeen: Date(), lastSeen: Date(), callCount: 10, confidence: 0.9, disputeCount: 0)
        // A 192-d query against a 256-d profile must never match, even at threshold 0.
        XCTAssertNil(Transcription.matchAgainstProfiles(vec(0.1, 192), profiles: [profile256], threshold: 0.0))
    }

    func testMatchSpeakerGuardsDimension() {
        let db = tmpDB()
        _ = db.addOrUpdateSpeaker(embedding: vec(0.2, 192), existingId: nil)
        // 256-d query: no match, even at threshold zero.
        XCTAssertNil(db.matchSpeaker(embedding: vec(0.2, 256), threshold: 0.0))
        XCTAssertNil(db.matchSpeaker(embedding: vec(0.2, 256), threshold: 0.1))
        // 192-d query of the same vector: matches.
        XCTAssertNotNil(db.matchSpeaker(embedding: vec(0.2, 192), threshold: 0.5))
    }

    func testExplicitCrossDimUpdateCreatesNewProfileInsteadOfBlending() {
        let db = tmpDB()
        let existing = db.addOrUpdateSpeaker(embedding: vec(0.1, 192), existingId: nil)
        let crossDim = db.addOrUpdateSpeaker(embedding: vec(0.3, 256), existingId: existing.id)

        XCTAssertNotEqual(crossDim.id, existing.id)
        XCTAssertEqual(db.getSpeaker(id: existing.id)?.embedding.count, 192)
        XCTAssertEqual(db.getSpeaker(id: crossDim.id)?.embedding.count, 256)
        XCTAssertEqual(Set(db.allSpeakers().map { $0.embedding.count }), [192, 256])
    }

    func testEMAUpdateWithinDimensionStaysSameDimAndUnitNorm() {
        let db = tmpDB()
        let p = db.addOrUpdateSpeaker(embedding: vec(0.1, 192), existingId: nil)
        let updated = db.addOrUpdateSpeaker(embedding: vec(0.3, 192), existingId: p.id)
        XCTAssertEqual(updated.embedding.count, 192)
        XCTAssertEqual(updated.callCount, 2)
        let norm = updated.embedding.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-3)
    }

    func testSeparateDBFilesAreIsolated() {
        let a = tmpDB(), b = tmpDB()
        _ = a.addOrUpdateSpeaker(embedding: vec(0.1, 192), existingId: nil)
        XCTAssertEqual(a.allSpeakers().count, 1)
        XCTAssertEqual(b.allSpeakers().count, 0, "ERes2Net DB and WeSpeaker DB must not share rows")
    }
}
