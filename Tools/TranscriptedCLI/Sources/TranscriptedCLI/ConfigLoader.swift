import Foundation

#if TRANSCRIPTEDCLI_WITH_DIARIZATION
import FluidAudio

/// JSON-decodable config for the supported OfflineDiarizerConfig parameters.
/// Missing fields use FluidAudio defaults.
struct DiarizeConfig: Codable {
    var clusteringThreshold: Double?
    var Fa: Double?
    var Fb: Double?
    var windowDuration: Double?
    var segmentationStepRatio: Double?
    var embeddingBatchSize: Int?
    var embeddingExcludeOverlap: Bool?
    var minSegmentDuration: Double?
    var minGapDuration: Double?
    var exclusiveSegments: Bool?
    var speechOnsetThreshold: Float?
    var speechOffsetThreshold: Float?
    var segmentationMinDurationOn: Double?
    var segmentationMinDurationOff: Double?
    var maxVBxIterations: Int?
    var convergenceTolerance: Double?

    func toOfflineDiarizerConfig() -> OfflineDiarizerConfig {
        TranscriptedDiarizerConfig.make(overrides: self)
    }
}

enum TranscriptedDiarizerConfig {
    static func make(overrides: DiarizeConfig? = nil) -> OfflineDiarizerConfig {
        // Same values used by Sources/TranscriptedCore/Services/DiarizationService.swift.
        OfflineDiarizerConfig(
            clusteringThreshold: overrides?.clusteringThreshold ?? 0.6,
            Fa: overrides?.Fa ?? 0.25,
            Fb: overrides?.Fb ?? 0.63,
            windowDuration: overrides?.windowDuration ?? 10.0,
            segmentationStepRatio: overrides?.segmentationStepRatio ?? 0.266,
            embeddingBatchSize: overrides?.embeddingBatchSize ?? 32,
            embeddingExcludeOverlap: overrides?.embeddingExcludeOverlap ?? true,
            minSegmentDuration: overrides?.minSegmentDuration ?? 1.1821,
            minGapDuration: overrides?.minGapDuration ?? 0.2874,
            speechOnsetThreshold: overrides?.speechOnsetThreshold ?? 0.4472,
            speechOffsetThreshold: overrides?.speechOffsetThreshold ?? 0.4472,
            segmentationMinDurationOn: overrides?.segmentationMinDurationOn ?? 0.0,
            segmentationMinDurationOff: overrides?.segmentationMinDurationOff ?? 0.2738,
            maxVBxIterations: overrides?.maxVBxIterations ?? 24,
            convergenceTolerance: overrides?.convergenceTolerance ?? 0.0001
        )
    }
}

enum ConfigLoader {
    static func load(from path: String) throws -> OfflineDiarizerConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(DiarizeConfig.self, from: data)
        return config.toOfflineDiarizerConfig()
    }
}
#endif
