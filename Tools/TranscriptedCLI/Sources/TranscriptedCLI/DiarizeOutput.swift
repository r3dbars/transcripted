import Foundation

/// `diarize --json` payload. Existing keys stay; new ones are additive only.
/// Lives outside the FluidAudio / Core gates so retrieval-mode tests can lock
/// the shape without linking models.
struct DiarizeSegmentOutput: Encodable, Equatable {
    let speakerId: String
    let startSeconds: Double
    let endSeconds: Double
    let durationSeconds: Double
    let qualityScore: Float
}

struct DiarizeTimingsOutput: Encodable, Equatable {
    let segmentationSeconds: Double
    let embeddingSeconds: Double
    let clusteringSeconds: Double
    let totalSeconds: Double

    /// JSONEncoder drops nil optionals, which would remove the existing
    /// `timings` key. Engines without measured stages still emit the object.
    static let missing = DiarizeTimingsOutput(
        segmentationSeconds: 0,
        embeddingSeconds: 0,
        clusteringSeconds: 0,
        totalSeconds: 0
    )
}

struct DiarizeFileOutput: Encodable, Equatable {
    let audioFile: String
    let segments: [DiarizeSegmentOutput]
    let speakerCount: Int
    let processingSeconds: Double
    let timings: DiarizeTimingsOutput
    let engine: String
}

enum DiarizeOutputBuilder {
    static func encode(_ output: DiarizeFileOutput) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(output)
    }

    static func write(_ output: DiarizeFileOutput, to path: String?) throws {
        let data = try encode(output)
        if let path {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            print(String(data: data, encoding: .utf8)!)
        }
    }
}
