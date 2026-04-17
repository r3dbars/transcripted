import ArgumentParser
import Foundation

#if TRANSCRIPTEDCLI_WITH_DIARIZATION
import FluidAudio

struct Diarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run offline diarization on a single audio file."
    )

    @Argument(help: "Path to audio file (WAV, M4A, etc.)")
    var audioPath: String

    @Option(name: .long, help: "Path to JSON config file for diarizer parameters.")
    var config: String?

    @Option(name: .long, help: "Path to directory containing diarization models.")
    var modelsDir: String?

    @Option(name: .shortAndLong, help: "Output RTTM file path. Prints to stdout if omitted.")
    var output: String?

    @Flag(name: .long, help: "Output JSON with full segment data instead of RTTM.")
    var json: Bool = false

    func run() async throws {
        let audioURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ValidationError("Audio file not found: \(audioPath)")
        }

        // Load config
        let diarizerConfig: OfflineDiarizerConfig
        if let configPath = config {
            diarizerConfig = try ConfigLoader.load(from: configPath)
        } else {
            diarizerConfig = OfflineDiarizerConfig.default
        }

        // Initialize diarizer
        let manager = OfflineDiarizerManager(config: diarizerConfig)
        if let dir = modelsDir {
            let models = try await OfflineDiarizerModels.load(from: URL(fileURLWithPath: dir))
            manager.initialize(models: models)
        } else {
            try await manager.prepareModels()
        }

        // Run diarization
        let startTime = Date()
        FileHandle.standardError.write(Data("Diarizing \(audioURL.lastPathComponent)...\n".utf8))
        let result = try await manager.process(audioURL)
        let elapsed = Date().timeIntervalSince(startTime)

        let speakerIds = Set(result.segments.map { $0.speakerId })
        FileHandle.standardError.write(Data("Done: \(result.segments.count) segments, \(speakerIds.count) speakers, \(String(format: "%.1f", elapsed))s\n".utf8))

        // Output
        if json {
            try outputJSON(result: result, audioPath: audioPath, elapsed: elapsed)
        } else {
            let fileId = audioURL.deletingPathExtension().lastPathComponent
            try RTTMWriter.output(segments: result.segments, fileId: fileId, to: output)
        }
    }

    private func outputJSON(result: DiarizationResult, audioPath: String, elapsed: TimeInterval) throws {
        struct JSONOutput: Encodable {
            let audioFile: String
            let segments: [SegmentOutput]
            let speakerCount: Int
            let processingSeconds: Double
            let timings: TimingsOutput?
        }
        struct SegmentOutput: Encodable {
            let speakerId: String
            let startSeconds: Float
            let endSeconds: Float
            let durationSeconds: Float
            let qualityScore: Float
        }
        struct TimingsOutput: Encodable {
            let segmentationSeconds: Double
            let embeddingSeconds: Double
            let clusteringSeconds: Double
            let totalSeconds: Double
        }

        let segments = result.segments.map { seg in
            SegmentOutput(
                speakerId: seg.speakerId,
                startSeconds: seg.startTimeSeconds,
                endSeconds: seg.endTimeSeconds,
                durationSeconds: seg.endTimeSeconds - seg.startTimeSeconds,
                qualityScore: seg.qualityScore
            )
        }

        let timings: TimingsOutput? = result.timings.map { t in
            TimingsOutput(
                segmentationSeconds: t.segmentationSeconds,
                embeddingSeconds: t.embeddingExtractionSeconds,
                clusteringSeconds: t.speakerClusteringSeconds,
                totalSeconds: t.totalProcessingSeconds
            )
        }

        let output = JSONOutput(
            audioFile: audioPath,
            segments: segments,
            speakerCount: Set(result.segments.map { $0.speakerId }).count,
            processingSeconds: elapsed,
            timings: timings
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)

        if let path = self.output {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            print(String(data: data, encoding: .utf8)!)
        }
    }
}
#else
struct Diarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run offline diarization on a single audio file."
    )

    @Argument(help: "Path to audio file (WAV, M4A, etc.)")
    var audioPath: String

    @Option(name: .long, help: "Path to JSON config file for diarizer parameters.")
    var config: String?

    @Option(name: .long, help: "Path to directory containing diarization models.")
    var modelsDir: String?

    @Option(name: .shortAndLong, help: "Output RTTM file path. Prints to stdout if omitted.")
    var output: String?

    @Flag(name: .long, help: "Output JSON with full segment data instead of RTTM.")
    var json: Bool = false

    func run() async throws {
        throw ValidationError("Offline diarization dependencies are unavailable. Run `bash build-deps.sh` from the repo root, then rebuild `transcripted-cli`.")
    }
}
#endif
