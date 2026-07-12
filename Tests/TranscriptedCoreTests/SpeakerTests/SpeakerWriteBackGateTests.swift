import XCTest
@testable import TranscriptedCore

/// DB-level verification that the write-time contamination gate (#6) actually freezes the stored
/// voiceprint when alpha is 0, while still recording the appearance, and blends normally otherwise.
@available(macOS 14.0, *)
final class SpeakerWriteBackGateTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerWriteBackGateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testFrozenAlphaLeavesVoiceprintUnchangedButRecordsAppearance() {
        let base = axis(0)   // [1, 0, 0, ...]
        let created = database.addOrUpdateSpeaker(embedding: base, existingId: nil)
        let before = try! XCTUnwrap(database.getSpeaker(id: created.id)).embedding

        // A contaminating embedding pointing in a very different direction, blended at alpha 0.
        let contaminant = axis(1)   // [0, 1, 0, ...]
        let updated = database.addOrUpdateSpeaker(embedding: contaminant, existingId: created.id, blendAlpha: 0)
        let after = try! XCTUnwrap(database.getSpeaker(id: created.id)).embedding

        // Voiceprint must be byte-for-byte (cosine 1.0) unchanged.
        XCTAssertEqual(cosine(before, after), 1.0, accuracy: 1e-5,
                       "alpha 0 must not move the stored fingerprint")
        // Appearance is still recorded: call count advances, profile matures.
        XCTAssertEqual(updated.callCount, created.callCount + 1)
    }

    func testStandardAlphaBlendsTowardNewEmbedding() {
        let base = axis(0)
        let created = database.addOrUpdateSpeaker(embedding: base, existingId: nil)
        let contaminant = axis(1)

        _ = database.addOrUpdateSpeaker(
            embedding: contaminant,
            existingId: created.id,
            blendAlpha: SpeakerWritePathPolicy.confidentBlendAlpha
        )
        let after = try! XCTUnwrap(database.getSpeaker(id: created.id)).embedding

        // With a real blend the fingerprint moves off the original axis toward the new one.
        XCTAssertLessThan(cosine(base, after), 0.9999, "alpha > 0 must move the fingerprint")
        XCTAssertGreaterThan(cosine(contaminant, after), 0.0, "fingerprint should tilt toward the new embedding")
    }

    func testDefaultTwoArgWriteBackStillBlends() {
        // The legacy 2-arg call site must keep its historical full-rate behaviour.
        let base = axis(0)
        let created = database.addOrUpdateSpeaker(embedding: base, existingId: nil)
        _ = database.addOrUpdateSpeaker(embedding: axis(1), existingId: created.id)
        let after = try! XCTUnwrap(database.getSpeaker(id: created.id)).embedding
        XCTAssertLessThan(cosine(base, after), 0.9999)
    }

    // MARK: - Helpers

    private func axis(_ index: Int, dim: Int = 256) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[index] = 1
        return v
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        Transcription.cosineSimilarityStatic(a, b)
    }
}
