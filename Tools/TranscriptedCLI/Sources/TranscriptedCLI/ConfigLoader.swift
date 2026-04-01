import Foundation
import FluidAudio

/// JSON-decodable config that maps 1:1 to OfflineDiarizerConfig's flat init.
/// All fields optional — missing fields use FluidAudio defaults.
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
    var minSpeakers: Int?
    var maxSpeakers: Int?

    func toOfflineDiarizerConfig() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig(
            clusteringThreshold: clusteringThreshold ?? 0.6,
            Fa: Fa ?? 0.07,
            Fb: Fb ?? 0.8,
            windowDuration: windowDuration ?? 10.0,
            segmentationStepRatio: segmentationStepRatio ?? 0.2,
            embeddingBatchSize: embeddingBatchSize ?? 32,
            embeddingExcludeOverlap: embeddingExcludeOverlap ?? true,
            minSegmentDuration: minSegmentDuration ?? 1.0,
            minGapDuration: minGapDuration ?? 0.1,
            exclusiveSegments: exclusiveSegments ?? true,
            speechOnsetThreshold: speechOnsetThreshold ?? 0.5,
            speechOffsetThreshold: speechOffsetThreshold ?? 0.5,
            segmentationMinDurationOn: segmentationMinDurationOn ?? 0.0,
            segmentationMinDurationOff: segmentationMinDurationOff ?? 0.0,
            maxVBxIterations: maxVBxIterations ?? 20,
            convergenceTolerance: convergenceTolerance ?? 1e-4
        )
        if minSpeakers != nil || maxSpeakers != nil {
            config = config.withSpeakers(min: minSpeakers, max: maxSpeakers)
        }
        return config
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
