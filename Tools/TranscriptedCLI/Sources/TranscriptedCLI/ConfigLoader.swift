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
        // FluidAudio's public OfflineDiarizerConfig surface has drifted from the
        // older flat initializer this CLI used to mirror. Keep config-file
        // loading buildable by falling back to the library defaults for now,
        // while still threading through the legacy speaker-bound compatibility
        // shim above.
        OfflineDiarizerConfig.default.applyingSpeakerBounds(min: minSpeakers, max: maxSpeakers)
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
