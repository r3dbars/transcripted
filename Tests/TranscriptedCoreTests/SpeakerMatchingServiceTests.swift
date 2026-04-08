import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerMatchingServiceTests: XCTestCase {

    func testMatchAgainstProfilesAcceptsMatureHighConfidenceProfile() {
        let profile = speakerProfile(embedding: [1, 0], callCount: 5)

        let match = Transcription.matchAgainstProfiles([1, 0], profiles: [profile], threshold: 0.70)

        XCTAssertEqual(match?.profileId, profile.id)
        XCTAssertEqual(match?.similarity ?? 0, 1.0, accuracy: 0.000_1)
    }

    func testMatchAgainstProfilesRejectsImmatureProfileBelowEffectiveThreshold() {
        let profile = speakerProfile(
            embedding: unitVector(cosineToXAxis: 0.75),
            callCount: 1
        )

        let match = Transcription.matchAgainstProfiles([1, 0], profiles: [profile], threshold: 0.70)

        XCTAssertNil(match)
    }

    func testMatchAgainstProfilesRejectsAmbiguousProfiles() {
        let profiles = [
            speakerProfile(embedding: unitVector(cosineToXAxis: 0.90), callCount: 6),
            speakerProfile(embedding: unitVector(cosineToXAxis: 0.87), callCount: 6),
        ]

        let match = Transcription.matchAgainstProfiles([1, 0], profiles: profiles, threshold: 0.70)

        XCTAssertNil(match)
    }

    func testComputeWeightedMeanEmbeddingBiasesTowardHeavierSamples() {
        let weighted = Transcription.computeWeightedMeanEmbedding(
            [[1, 0], [0, 1]],
            weights: [3, 1]
        )

        XCTAssertGreaterThan(weighted[0], weighted[1])
        XCTAssertEqual(vectorMagnitude(weighted), 1.0, accuracy: 0.000_1)
    }

    private func speakerProfile(
        embedding: [Float],
        callCount: Int,
        name: String? = "Known Speaker"
    ) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            displayName: name,
            nameSource: NameSource.userManual,
            embedding: embedding,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: callCount,
            confidence: 0.8,
            disputeCount: 0
        )
    }

    private func unitVector(cosineToXAxis: Float) -> [Float] {
        let y = sqrt(max(0, 1 - (cosineToXAxis * cosineToXAxis)))
        return [cosineToXAxis, y]
    }

    private func vectorMagnitude(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + ($1 * $1) })
    }
}
