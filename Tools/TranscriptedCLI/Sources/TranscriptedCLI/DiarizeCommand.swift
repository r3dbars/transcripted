import ArgumentParser
import Foundation

#if TRANSCRIPTEDCLI_WITH_DIARIZATION && canImport(FluidAudio)
import FluidAudio
#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct Diarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run offline diarization on a single audio file."
    )

    @Argument(help: "Path to audio file (WAV, M4A, etc.)")
    var audioPath: String

    @Option(name: .long, help: "Path to a pyannote OfflineDiarizerConfig JSON file. Selects pyannote; --diarization-engine pyannote is not required.")
    var config: String?

    @Option(name: .long, help: "Path to directory containing diarization models.")
    var modelsDir: String?

    @Option(name: .long, help: "Diarization engine: app (default; follows the app's Nemotron unless changed), nemotron, or pyannote.")
    var diarizationEngine = "app"

    @Option(name: .shortAndLong, help: "Output RTTM file path. Prints to stdout if omitted.")
    var output: String?

    @Flag(name: .long, help: "Output JSON with full segment data instead of RTTM.")
    var json: Bool = false

    mutating func validate() throws {
        guard CLIDiarization.engineChoices.contains(diarizationEngine) else {
            throw ValidationError("--diarization-engine must be " + CLIDiarization.engineChoices.joined(separator: ", ") + ".")
        }
    }

    func run() async throws {
        let audioURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ValidationError("Audio file not found: \(audioPath)")
        }

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
            try await runNemotron(audioURL: audioURL)
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

        // Initialize diarizer
        DiarizerCompatibility.keepUnpinnedDiarizerCaches()
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
            try outputJSON(result: result, audioPath: audioPath, elapsed: elapsed, engine: engine)
        } else {
            let fileId = audioURL.deletingPathExtension().lastPathComponent
            try RTTMWriter.output(segments: result.segments, fileId: fileId, to: output)
        }
    }

    private func outputJSON(result: DiarizationResult, audioPath: String, elapsed: TimeInterval, engine: String) throws {
        let segments = result.segments.map { seg in
            DiarizeSegmentOutput(
                speakerId: seg.speakerId,
                startSeconds: Double(seg.startTimeSeconds),
                endSeconds: Double(seg.endTimeSeconds),
                durationSeconds: Double(seg.endTimeSeconds - seg.startTimeSeconds),
                qualityScore: seg.qualityScore
            )
        }

        let timings: DiarizeTimingsOutput? = result.timings.map { t in
            DiarizeTimingsOutput(
                segmentationSeconds: t.segmentationSeconds,
                embeddingSeconds: t.embeddingExtractionSeconds,
                clusteringSeconds: t.speakerClusteringSeconds,
                totalSeconds: t.totalProcessingSeconds
            )
        }

        try DiarizeOutputBuilder.write(
            DiarizeFileOutput(
                audioFile: audioPath,
                segments: segments,
                speakerCount: Set(result.segments.map { $0.speakerId }).count,
                processingSeconds: elapsed,
                timings: timings,
                engine: engine
            ),
            to: output
        )
    }

    #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
    private func runNemotron(audioURL: URL) async throws {
        let ready = try await CLIDiarizationService.readyService(
            backend: .nemotron, modelsDir: modelsDir, choice: diarizationEngine
        )
        CLIDiarization.writeFallbackNote(ready.selection.fallbackNote)
        let service = ready.service
        let startTime = Date()
        FileHandle.standardError.write(Data("Diarizing \(audioURL.lastPathComponent)...\n".utf8))
        let segments = try await CLIDiarizationService.segments(service: service, audioURL: audioURL)
        let elapsed = Date().timeIntervalSince(startTime)
        let speakerIds = Set(segments.map(\.speakerId))
        FileHandle.standardError.write(Data("Done: \(segments.count) segments, \(speakerIds.count) speakers, \(String(format: "%.1f", elapsed))s\n".utf8))
        if json {
            try CLIDiarizationService.writeJSON(
                segments: segments,
                audioPath: audioPath,
                elapsed: elapsed,
                engine: ready.selection.engine,
                to: output
            )
        } else {
            let fileId = audioURL.deletingPathExtension().lastPathComponent
            try RTTMText.output(fileId: fileId, segments: CLIDiarizationService.rttmSegments(from: segments), to: output)
        }
        await MainActor.run { service.cleanup() }
    }
    #endif
}
#else
struct Diarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run offline diarization on a single audio file."
    )

    @Argument(help: "Path to audio file (WAV, M4A, etc.)")
    var audioPath: String

    @Option(name: .long, help: "Path to a pyannote OfflineDiarizerConfig JSON file. Selects pyannote; --diarization-engine pyannote is not required.")
    var config: String?

    @Option(name: .long, help: "Path to directory containing diarization models.")
    var modelsDir: String?

    @Option(name: .long, help: "Diarization engine: app (default; follows the app's Nemotron unless changed), nemotron, or pyannote.")
    var diarizationEngine = "app"

    @Option(name: .shortAndLong, help: "Output RTTM file path. Prints to stdout if omitted.")
    var output: String?

    @Flag(name: .long, help: "Output JSON with full segment data instead of RTTM.")
    var json: Bool = false

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
