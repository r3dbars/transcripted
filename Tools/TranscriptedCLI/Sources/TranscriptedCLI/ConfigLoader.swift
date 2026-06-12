import ArgumentParser
import Foundation

/// JSON-decodable config for the supported OfflineDiarizerConfig parameters.
/// Missing fields use FluidAudio defaults. Unknown keys are rejected so typos
/// fail loudly instead of silently falling back to defaults.
///
/// Every key here must map to a property on the OfflineDiarizerConfig exposed
/// by the prebuilt FluidAudio module under deps-modules/ (the pinned
/// build-deps.sh version). Keys without a counterpart there (for example
/// `exclusiveSegments`, added in a newer FluidAudio) stay out of this list so
/// they error instead of being silently dropped.
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
    var speechOnsetThreshold: Float?
    var speechOffsetThreshold: Float?
    var segmentationMinDurationOn: Double?
    var segmentationMinDurationOff: Double?
    var maxVBxIterations: Int?
    var convergenceTolerance: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case clusteringThreshold
        case Fa
        case Fb
        case windowDuration
        case segmentationStepRatio
        case embeddingBatchSize
        case embeddingExcludeOverlap
        case minSegmentDuration
        case minGapDuration
        case speechOnsetThreshold
        case speechOffsetThreshold
        case segmentationMinDurationOn
        case segmentationMinDurationOff
        case maxVBxIterations
        case convergenceTolerance
    }

    static let supportedKeys = Set(CodingKeys.allCases.map { $0.rawValue })

    /// Decode config JSON, rejecting any keys that do not map to an
    /// OfflineDiarizerConfig parameter.
    static func decode(from data: Data) throws -> DiarizeConfig {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw ValidationError("Diarizer config must be a top-level JSON object.")
        }
        let unsupported = object.keys.filter { !supportedKeys.contains($0) }.sorted()
        guard unsupported.isEmpty else {
            throw ValidationError(
                "Unsupported diarizer config keys: \(unsupported.joined(separator: ", ")). "
                    + "Supported keys: \(supportedKeys.sorted().joined(separator: ", "))."
            )
        }
        return try JSONDecoder().decode(DiarizeConfig.self, from: data)
    }
}

#if TRANSCRIPTEDCLI_WITH_DIARIZATION && canImport(FluidAudio)
import FluidAudio

extension DiarizeConfig {
    func toOfflineDiarizerConfig() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        if let value = clusteringThreshold { config.clusteringThreshold = value }
        if let value = Fa { config.Fa = value }
        if let value = Fb { config.Fb = value }
        if let value = windowDuration { config.windowDuration = value }
        if let value = segmentationStepRatio { config.segmentationStepRatio = value }
        if let value = embeddingBatchSize { config.embeddingBatchSize = value }
        if let value = embeddingExcludeOverlap { config.embeddingExcludeOverlap = value }
        if let value = minSegmentDuration { config.minSegmentDuration = value }
        if let value = minGapDuration { config.minGapDuration = value }
        if let value = speechOnsetThreshold { config.speechOnsetThreshold = value }
        if let value = speechOffsetThreshold { config.speechOffsetThreshold = value }
        if let value = segmentationMinDurationOn { config.segmentationMinDurationOn = value }
        if let value = segmentationMinDurationOff { config.segmentationMinDurationOff = value }
        if let value = maxVBxIterations { config.maxVBxIterations = value }
        if let value = convergenceTolerance { config.convergenceTolerance = value }
        return config
    }
}

enum ConfigLoader {
    static func load(from path: String) throws -> OfflineDiarizerConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let config = try DiarizeConfig.decode(from: data)
        return config.toOfflineDiarizerConfig()
    }
}
#endif
