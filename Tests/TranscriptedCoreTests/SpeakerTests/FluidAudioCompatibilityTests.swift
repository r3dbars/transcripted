import XCTest
@preconcurrency import FluidAudio
@testable import TranscriptedCore

/// Pins what keeps the FluidAudio 0.17 upgrade from changing shipped behavior:
/// the tuned pyannote config and the markerless diarizer cache policy.
final class FluidAudioCompatibilityTests: XCTestCase {

    func testCosineToDistanceMatchesTheLegacyConversion() {
        // FluidAudio 0.15.x: sqrt(max(0, 2 - 2s)) with s clamped to [-1, 1].
        XCTAssertEqual(FluidAudioCompatibility.tunedClusteringDistanceThreshold, 0.894427190999916, accuracy: 1e-12)
        XCTAssertEqual(FluidAudioCompatibility.clusteringDistance(fromCosineSimilarity: 1.0), 0, accuracy: 1e-12)
        XCTAssertEqual(FluidAudioCompatibility.clusteringDistance(fromCosineSimilarity: 0.0), 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(FluidAudioCompatibility.clusteringDistance(fromCosineSimilarity: -1.0), 2, accuracy: 1e-12)
        XCTAssertEqual(FluidAudioCompatibility.clusteringDistance(fromCosineSimilarity: 3.0), 0, accuracy: 1e-12)
        XCTAssertEqual(FluidAudioCompatibility.clusteringDistance(fromCosineSimilarity: -3.0), 2, accuracy: 1e-12)
    }

    func testTunedOfflineConfigPinsTheGridSearchedValues() throws {
        let config = FluidAudioCompatibility.tunedOfflineDiarizerConfig()
        XCTAssertEqual(config.clusteringThreshold, 0.894427190999916, accuracy: 1e-12)
        XCTAssertFalse(config.clustering.constrainedAssignment, "0.15.x assigned each local speaker independently")
        XCTAssertEqual(config.Fa, 0.25)
        XCTAssertEqual(config.Fb, 0.63)
        XCTAssertEqual(config.windowDuration, 10.0)
        XCTAssertEqual(config.segmentationStepRatio, 0.266)
        XCTAssertEqual(config.embeddingBatchSize, 32)
        XCTAssertTrue(config.embeddingExcludeOverlap)
        XCTAssertEqual(config.minSegmentDuration, 1.1821)
        XCTAssertEqual(config.minGapDuration, 0.2874)
        XCTAssertEqual(config.speechOnsetThreshold, 0.4472)
        XCTAssertEqual(config.speechOffsetThreshold, 0.4472)
        XCTAssertEqual(config.segmentationMinDurationOn, 0.0)
        XCTAssertEqual(config.segmentationMinDurationOff, 0.2738)
        XCTAssertEqual(config.maxVBxIterations, 24)
        XCTAssertEqual(config.convergenceTolerance, 0.0001)
        XCTAssertNoThrow(try config.validate())
    }

    func testDiarizerCachesResolveAtMainSoMarkerlessCachesStayValid() {
        FluidAudioCompatibility.keepUnpinnedDiarizerCaches()
        FluidAudioCompatibility.keepUnpinnedDiarizerCaches()
        XCTAssertEqual(ModelRegistry.revisionOverrides[FluidAudioCompatibility.diarizerRepoPath], "main")
        XCTAssertEqual(FluidAudioCompatibility.diarizerRepoPath, Repo.diarizer.rawValue)
    }
}
