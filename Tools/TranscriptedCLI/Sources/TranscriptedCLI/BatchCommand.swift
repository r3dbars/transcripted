import ArgumentParser
import Foundation

#if TRANSCRIPTEDCLI_WITH_DIARIZATION && canImport(FluidAudio)
import FluidAudio
#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run offline diarization on all audio files in a directory."
    )

    @Argument(help: "Directory containing audio files.")
    var audioDir: String

    @Option(name: .long, help: "Path to a pyannote OfflineDiarizerConfig JSON file. Selects pyannote; --diarization-engine pyannote is not required.")
    var config: String?

    @Option(name: .long, help: "Path to directory containing diarization models.")
    var modelsDir: String?

    @Option(name: .long, help: "Diarization engine: app (default; follows the app's Nemotron unless changed), nemotron, or pyannote.")
    var diarizationEngine = "app"

    @Option(name: .long, help: "Output directory for RTTM files. Defaults to audio directory.")
    var outputDir: String?

    @Option(name: .long, help: "Audio file extension to process.")
    var ext: String = "m4a"

    mutating func validate() throws {
        guard CLIDiarization.engineChoices.contains(diarizationEngine) else {
            throw ValidationError("--diarization-engine must be " + CLIDiarization.engineChoices.joined(separator: ", ") + ".")
        }
    }

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

        var selection = try CLIDiarization.runnableEngine(
            choice: diarizationEngine,
            storedPreference: CLIDiarization.storedAppPreference()
        )
        let configSelection = CLIDiarization.applyConfigSelection(
            engine: selection.engine, hasConfig: config != nil
        )
        selection.engine = configSelection.engine
        if let note = configSelection.fallbackNote {
            selection.fallbackNote = note
        }
        CLIDiarization.writeFallbackNote(selection.fallbackNote)
        let engine = selection.engine
        if engine == "nemotron" {
            #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
            try await runNemotron(audioFiles: audioFiles, outDirURL: outDirURL)
            return
            #else
            throw ValidationError("Nemotron diarization needs the meeting-import CLI shipped in Transcripted.app. Pass --diarization-engine pyannote, or rebuild with TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1.")
            #endif
        }

        // Load config
        let diarizerConfig: OfflineDiarizerConfig
        if let configPath = config {
            diarizerConfig = try ConfigLoader.load(from: configPath)
        } else {
            diarizerConfig = DiarizerCompatibility.legacyDefaultConfig
        }

        // Initialize diarizer once
        DiarizerCompatibility.keepUnpinnedDiarizerCaches()
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
        }

        let batchElapsed = Date().timeIntervalSince(batchStart)
        writeSummary(fileCount: audioFiles.count, elapsed: batchElapsed, outputDir: outDirURL, engine: engine)
    }

    private func writeSummary(fileCount: Int, elapsed: TimeInterval, outputDir: URL, engine: String) {
        print("""
        {
          "files_processed": \(fileCount),
          "total_processing_seconds": \(String(format: "%.1f", elapsed)),
          "output_dir": "\(outputDir.path)",
          "engine": "\(engine)"
        }
        """)
    }

    #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
    private func runNemotron(audioFiles: [URL], outDirURL: URL) async throws {
        let ready = try await CLIDiarizationService.readyService(
            backend: .nemotron, modelsDir: modelsDir, choice: diarizationEngine
        )
        CLIDiarization.writeFallbackNote(ready.selection.fallbackNote)
        let service = ready.service
        let batchStart = Date()
        for (index, audioURL) in audioFiles.enumerated() {
            let fileId = audioURL.deletingPathExtension().lastPathComponent
            let progress = "[\(index + 1)/\(audioFiles.count)]"
            FileHandle.standardError.write(Data("\(progress) \(audioURL.lastPathComponent)...".utf8))
            let fileStart = Date()
            let segments = try await CLIDiarizationService.segments(service: service, audioURL: audioURL)
            let fileElapsed = Date().timeIntervalSince(fileStart)
            let speakerIds = Set(segments.map(\.speakerId))
            FileHandle.standardError.write(Data(" \(speakerIds.count) speakers, \(segments.count) segments, \(String(format: "%.1f", fileElapsed))s\n".utf8))
            let rttmPath = outDirURL.appendingPathComponent("\(fileId).rttm").path
            try RTTMText.output(fileId: fileId, segments: CLIDiarizationService.rttmSegments(from: segments), to: rttmPath)
        }
        let batchElapsed = Date().timeIntervalSince(batchStart)
        await MainActor.run { service.cleanup() }
        writeSummary(
            fileCount: audioFiles.count,
            elapsed: batchElapsed,
            outputDir: outDirURL,
            engine: ready.selection.engine
        )
    }
    #endif
}
#else
struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run offline diarization on all audio files in a directory."
    )

    @Argument(help: "Directory containing audio files.")
    var audioDir: String

    @Option(name: .long, help: "Path to a pyannote OfflineDiarizerConfig JSON file. Selects pyannote; --diarization-engine pyannote is not required.")
    var config: String?

    @Option(name: .long, help: "Path to directory containing diarization models.")
    var modelsDir: String?

    @Option(name: .long, help: "Diarization engine: app (default; follows the app's Nemotron unless changed), nemotron, or pyannote.")
    var diarizationEngine = "app"

    @Option(name: .long, help: "Output directory for RTTM files. Defaults to audio directory.")
    var outputDir: String?

    @Option(name: .long, help: "Audio file extension to process.")
    var ext: String = "m4a"

    mutating func validate() throws {
        guard CLIDiarization.engineChoices.contains(diarizationEngine) else {
            throw ValidationError("--diarization-engine must be " + CLIDiarization.engineChoices.joined(separator: ", ") + ".")
        }
    }

    func run() async throws {
        throw ValidationError("Offline diarization dependencies are unavailable. Run `bash build-deps.sh` from the repo root, then rebuild with `TRANSCRIPTEDCLI_ENABLE_DIARIZATION=1`.")
    }
}
#endif
