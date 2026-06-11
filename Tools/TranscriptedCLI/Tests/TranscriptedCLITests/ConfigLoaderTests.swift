import ArgumentParser
import XCTest
@testable import transcripted_cli

final class ConfigLoaderTests: XCTestCase {
    func testDecodeReadsAllSupportedKeys() throws {
        let json = """
        {
            "clusteringThreshold": 0.55,
            "Fa": 0.25,
            "Fb": 0.63,
            "windowDuration": 8.0,
            "segmentationStepRatio": 0.3,
            "embeddingBatchSize": 16,
            "embeddingExcludeOverlap": false,
            "minSegmentDuration": 1.2,
            "minGapDuration": 0.3,
            "speechOnsetThreshold": 0.45,
            "speechOffsetThreshold": 0.4,
            "segmentationMinDurationOn": 0.1,
            "segmentationMinDurationOff": 0.25,
            "maxVBxIterations": 24,
            "convergenceTolerance": 0.0002
        }
        """
        let config = try DiarizeConfig.decode(from: Data(json.utf8))

        XCTAssertEqual(config.clusteringThreshold, 0.55)
        XCTAssertEqual(config.Fa, 0.25)
        XCTAssertEqual(config.Fb, 0.63)
        XCTAssertEqual(config.windowDuration, 8.0)
        XCTAssertEqual(config.segmentationStepRatio, 0.3)
        XCTAssertEqual(config.embeddingBatchSize, 16)
        XCTAssertEqual(config.embeddingExcludeOverlap, false)
        XCTAssertEqual(config.minSegmentDuration, 1.2)
        XCTAssertEqual(config.minGapDuration, 0.3)
        XCTAssertEqual(config.speechOnsetThreshold, 0.45)
        XCTAssertEqual(config.speechOffsetThreshold, 0.4)
        XCTAssertEqual(config.segmentationMinDurationOn, 0.1)
        XCTAssertEqual(config.segmentationMinDurationOff, 0.25)
        XCTAssertEqual(config.maxVBxIterations, 24)
        XCTAssertEqual(config.convergenceTolerance, 0.0002)
    }

    func testDecodeLeavesMissingFieldsNilSoDefaultsApply() throws {
        let json = """
        { "clusteringThreshold": 0.7 }
        """
        let config = try DiarizeConfig.decode(from: Data(json.utf8))

        XCTAssertEqual(config.clusteringThreshold, 0.7)
        XCTAssertNil(config.Fa)
        XCTAssertNil(config.windowDuration)
        XCTAssertNil(config.maxVBxIterations)
    }

    func testDecodeRejectsUnsupportedKeys() {
        let json = """
        {
            "clusteringThreshold": 0.7,
            "clustering_threshold": 0.5,
            "bogusKnob": true
        }
        """

        XCTAssertThrowsError(try DiarizeConfig.decode(from: Data(json.utf8))) { error in
            guard let validationError = error as? ValidationError else {
                XCTFail("Expected ValidationError, got \(error)")
                return
            }
            XCTAssertTrue(validationError.message.contains("Unsupported diarizer config keys"))
            XCTAssertTrue(validationError.message.contains("bogusKnob"))
            XCTAssertTrue(validationError.message.contains("clustering_threshold"))
        }
    }

    func testDecodeRejectsKeysWithoutACounterpartInLinkedFluidAudio() {
        // `exclusiveSegments` exists in newer FluidAudio releases but not in the
        // prebuilt module this CLI links against, so it must error loudly
        // instead of being silently dropped.
        let json = """
        { "exclusiveSegments": false }
        """

        XCTAssertThrowsError(try DiarizeConfig.decode(from: Data(json.utf8))) { error in
            guard let validationError = error as? ValidationError else {
                XCTFail("Expected ValidationError, got \(error)")
                return
            }
            XCTAssertTrue(validationError.message.contains("exclusiveSegments"))
        }
    }

    func testDecodeRejectsNonObjectJSON() {
        XCTAssertThrowsError(try DiarizeConfig.decode(from: Data("[1, 2, 3]".utf8))) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }
}

#if TRANSCRIPTEDCLI_WITH_DIARIZATION && canImport(FluidAudio)
import FluidAudio

extension ConfigLoaderTests {
    func testConfigJSONChangesOfflineDiarizerConfig() throws {
        let json = """
        {
            "clusteringThreshold": 0.55,
            "Fa": 0.25,
            "Fb": 0.63,
            "windowDuration": 8.0,
            "segmentationStepRatio": 0.3,
            "embeddingBatchSize": 16,
            "embeddingExcludeOverlap": false,
            "minSegmentDuration": 1.2,
            "minGapDuration": 0.3,
            "speechOnsetThreshold": 0.45,
            "speechOffsetThreshold": 0.4,
            "segmentationMinDurationOn": 0.1,
            "segmentationMinDurationOff": 0.25,
            "maxVBxIterations": 24,
            "convergenceTolerance": 0.0002
        }
        """
        let decoded = try DiarizeConfig.decode(from: Data(json.utf8))
        let config = decoded.toOfflineDiarizerConfig()

        XCTAssertEqual(config.clusteringThreshold, 0.55)
        XCTAssertEqual(config.Fa, 0.25)
        XCTAssertEqual(config.Fb, 0.63)
        XCTAssertEqual(config.windowDuration, 8.0)
        XCTAssertEqual(config.segmentationStepRatio, 0.3)
        XCTAssertEqual(config.embeddingBatchSize, 16)
        XCTAssertEqual(config.embeddingExcludeOverlap, false)
        XCTAssertEqual(config.minSegmentDuration, 1.2)
        XCTAssertEqual(config.minGapDuration, 0.3)
        XCTAssertEqual(config.speechOnsetThreshold, 0.45)
        XCTAssertEqual(config.speechOffsetThreshold, 0.4)
        XCTAssertEqual(config.segmentationMinDurationOn, 0.1)
        XCTAssertEqual(config.segmentationMinDurationOff, 0.25)
        XCTAssertEqual(config.maxVBxIterations, 24)
        XCTAssertEqual(config.convergenceTolerance, 0.0002)

        // Values actually moved away from the library defaults.
        let defaults = OfflineDiarizerConfig.default
        XCTAssertNotEqual(config.clusteringThreshold, defaults.clusteringThreshold)
        XCTAssertNotEqual(config.Fa, defaults.Fa)
        XCTAssertNotEqual(config.maxVBxIterations, defaults.maxVBxIterations)
        XCTAssertNotEqual(config.windowDuration, defaults.windowDuration)
    }

    func testPartialConfigJSONKeepsDefaultsForMissingFields() throws {
        let json = """
        { "clusteringThreshold": 0.7, "maxVBxIterations": 30 }
        """
        let decoded = try DiarizeConfig.decode(from: Data(json.utf8))
        let config = decoded.toOfflineDiarizerConfig()
        let defaults = OfflineDiarizerConfig.default

        XCTAssertEqual(config.clusteringThreshold, 0.7)
        XCTAssertEqual(config.maxVBxIterations, 30)
        XCTAssertEqual(config.Fa, defaults.Fa)
        XCTAssertEqual(config.Fb, defaults.Fb)
        XCTAssertEqual(config.windowDuration, defaults.windowDuration)
        XCTAssertEqual(config.segmentationStepRatio, defaults.segmentationStepRatio)
        XCTAssertEqual(config.embeddingBatchSize, defaults.embeddingBatchSize)
        XCTAssertEqual(config.embeddingExcludeOverlap, defaults.embeddingExcludeOverlap)
        XCTAssertEqual(config.minSegmentDuration, defaults.minSegmentDuration)
        XCTAssertEqual(config.minGapDuration, defaults.minGapDuration)
        XCTAssertEqual(config.speechOnsetThreshold, defaults.speechOnsetThreshold)
        XCTAssertEqual(config.speechOffsetThreshold, defaults.speechOffsetThreshold)
        XCTAssertEqual(config.segmentationMinDurationOn, defaults.segmentationMinDurationOn)
        XCTAssertEqual(config.segmentationMinDurationOff, defaults.segmentationMinDurationOff)
        XCTAssertEqual(config.convergenceTolerance, defaults.convergenceTolerance)
    }
}
#endif
