import ArgumentParser
import Foundation
import FluidAudio

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run offline diarization on all audio files in a directory."
    )

    @Argument(help: "Directory containing audio files.")
    var audioDir: String

    @Option(name: .long, help: "Path to JSON config file for diarizer parameters.")
    var config: String?

    @Option(name: .long, help: "Path to directory containing diarization models.")
    var modelsDir: String?

    @Option(name: .long, help: "Output directory for RTTM files. Defaults to audio directory.")
    var outputDir: String?

    @Option(name: .long, help: "Audio file extension to process.")
    var ext: String = "m4a"

    func run() async throws {
        let dirURL = URL(fileURLWithPath: audioDir)
        let outDirURL = URL(fileURLWithPath: outputDir ?? audioDir)

        // Find audio files
        let contents = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil
        )
        let audioFiles = contents
            .filter { $0.pathExtension.lowercased() == ext.lowercased() }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !audioFiles.isEmpty else {
            throw ValidationError("No .\(ext) files found in \(audioDir)")
        }

        // Create output directory if needed
        try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)

        // Load config
        let diarizerConfig: OfflineDiarizerConfig
        if let configPath = config {
            diarizerConfig = try ConfigLoader.load(from: configPath)
        } else {
            diarizerConfig = OfflineDiarizerConfig.default.applyingSpeakerBounds(min: 2, max: 8)
        }

        // Initialize diarizer once
        let manager = OfflineDiarizerManager(config: diarizerConfig)
        if let dir = modelsDir {
            let models = try await OfflineDiarizerModels.load(from: URL(fileURLWithPath: dir))
            manager.initialize(models: models)
        } else {
            try await manager.prepareModels()
        }

        // Process each file
        let batchStart = Date()
        var totalDuration: Double = 0
        var totalProcessing: Double = 0
        var results: [[String: Any]] = []

        for (index, audioURL) in audioFiles.enumerated() {
            let fileId = audioURL.deletingPathExtension().lastPathComponent
            let progress = "[\(index + 1)/\(audioFiles.count)]"

            FileHandle.standardError.write(Data("\(progress) \(audioURL.lastPathComponent)...".utf8))

            let fileStart = Date()
            let result = try await manager.process(audioURL)
            let fileElapsed = Date().timeIntervalSince(fileStart)

            let speakerIds = Set(result.segments.map { $0.speakerId })

            FileHandle.standardError.write(Data(" \(speakerIds.count) speakers, \(result.segments.count) segments, \(String(format: "%.1f", fileElapsed))s\n".utf8))

            // Write RTTM
            let rttmPath = outDirURL.appendingPathComponent("\(fileId).rttm").path
            try RTTMWriter.output(segments: result.segments, fileId: fileId, to: rttmPath)

            totalProcessing += fileElapsed
            if let timings = result.timings {
                totalDuration += timings.audioLoadingSeconds
            }

            results.append([
                "file": fileId,
                "speakers": speakerIds.count,
                "segments": result.segments.count,
                "processing_seconds": round(fileElapsed * 10) / 10,
            ])
        }

        let batchElapsed = Date().timeIntervalSince(batchStart)

        // Summary JSON to stdout
        let summaryJSON = """
        {
          "files_processed": \(audioFiles.count),
          "total_processing_seconds": \(String(format: "%.1f", batchElapsed)),
          "output_dir": "\(outDirURL.path)"
        }
        """
        print(summaryJSON)
    }
}
