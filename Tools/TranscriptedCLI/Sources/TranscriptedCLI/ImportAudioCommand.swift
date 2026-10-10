import ArgumentParser
import Darwin
import Foundation
import TranscriptedCaptureKit
#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
import TranscriptedCore
#endif

/// Full meeting import is additive: `transcribe` keeps its text/JSON/SRT contract.
struct ImportAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-audio",
        abstract: "Transcribe and diarize a file into the Transcripted meeting library.",
        discussion: "Uses local Parakeet v3 and the app's diarization engine (Nemotron by default; pyannote stays available). Never records audio or deletes the input. "
            + "Recognizes eligible saved speakers from a read-only snapshot of the app's active voiceprint database; does not learn new people. "
            + "Says on stderr why each numbered speaker stayed numbered. "
            + "Does not use the app's Whisper/language selection. Repeated imports create distinct captures."
    )

    @Argument(help: "Existing audio or video file (WAV, M4A, MP3, AIFF, MP4, MOV, ...).")
    var mediaPath: String

    @Option(name: .long, help: "Direct meeting output directory. Defaults to the app-selected library (or Transcripted directory environment overrides).")
    var outputDir: String?

    @Option(name: .long, help: "Meeting title. Defaults to the input filename without its extension.")
    var title: String?

    @Flag(name: .long, help: "Name the Markdown just after the title (the input filename by default), with no date in front or ID at the end. Adds the ID only if that name is already taken.")
    var plainFilename = false

    @Flag(name: .long, help: "Save Markdown only, without a retained playback WAV. The original input is always preserved.")
    var noRetainAudio = false

    @Flag(name: .long, help: "Use numbered speakers only; do not read the app's saved speaker database.")
    var noSpeakerIdentification = false

    @Option(name: .long, help: "Read-only speaker database override; must match the selected speaker embedder.")
    var speakerDb: String?

    @Option(name: .long, help: "Voiceprint model: app (default; follows the app, ReDimNet2 unless changed), redimnet2, wespeaker, or eres2net. ReDimNet2 and ERes2Net need their installed local model.")
    var speakerEmbedder = "app"

    @Option(name: .long, help: "Diarization engine: app (default; follows the app's hidden switch / TRANSCRIPTED_DIARIZATION_BACKEND, Nemotron unless changed), nemotron, or pyannote.")
    var diarizationEngine = "app"

    @Flag(name: .long, help: "Also name a speaker held back only by confirmation count and/or a similarity below the silent-naming bar but above the model's invitee/suggest floor, when the top match also beats the runner-up by the model's invitee margin, written as \"Name (likely)\". Off by default. Never a confirmed identity.")
    var nameLikelySpeakers = false

    @Option(name: .long, help: "Path to a complete Parakeet TDT v3 model directory, or a flat Nemotron diarizer directory (same as diarize --models-dir).")
    var modelsDir: String?

    @Option(name: .long, help: "Path to a complete pyannote or Nemotron diarization model directory.")
    var diarizationModelsDir: String?

    @Flag(name: .long, help: "Never download models. Missing or incomplete local models are errors.")
    var noDownload = false

    @Flag(name: .long, help: "Print one JSON receipt to stdout; diagnostics go to stderr.")
    var json = false

    mutating func validate() throws {
        #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
        guard Self.speakerEmbedderChoices.contains(speakerEmbedder) else {
            throw ValidationError("--speaker-embedder must be " + Self.speakerEmbedderChoices.joined(separator: ", ") + ".")
        }
        #else
        // This build cannot import audio. Parse flags without duplicating
        // Core's model registry; run() reports the missing capability.
        guard !speakerEmbedder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--speaker-embedder cannot be empty.")
        }
        #endif
        guard Self.diarizationEngineChoices.contains(diarizationEngine) else {
            throw ValidationError("--diarization-engine must be " + Self.diarizationEngineChoices.joined(separator: ", ") + ".")
        }
        if noSpeakerIdentification && nameLikelySpeakers {
            throw ValidationError("--name-likely-speakers cannot be combined with --no-speaker-identification.")
        }
        if noSpeakerIdentification && speakerDb != nil {
            throw ValidationError("--speaker-db cannot be combined with --no-speaker-identification.")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--title cannot be empty.")
        }
        for (name, path) in [("--output-dir", outputDir), ("--models-dir", modelsDir),
                             ("--diarization-models-dir", diarizationModelsDir), ("--speaker-db", speakerDb)] {
            if let path, path.isEmpty { throw ValidationError("\(name) cannot be empty.") }
        }
    }

    func run() async throws {
        #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
        // Core/library diagnostics must never pollute JSON stdout or the app log.
        setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)
        let stdout = try ImportAudioStandardOutput()
        defer { stdout.restore() }
        let operation = Task { try await MeetingImportWorkflow.run(self) }
        let signals = ImportAudioSignals { operation.cancel() }
        defer { signals.restore() }
        do {
            let receipt = try await operation.value
            // Once published, report success even if a late signal arrived. A zero
            // exit means the receipt's committed artifacts exist, not a queued job.
            let data: Data
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                data = try encoder.encode(receipt) + Data("\n".utf8)
            } else {
                data = Data((receipt.transcriptPath + "\n").utf8)
            }
            try stdout.write(data)
        } catch {
            if let signal = signals.receivedSignal {
                throw ExitCode(128 + signal)
            }
            throw error
        }
        #else
        throw ValidationError("Meeting import requires macOS 26+ and the shared meeting pipeline. Run bash build-deps.sh at the repo root, then TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift build --package-path Tools/TranscriptedCLI.")
        #endif
    }

    static var speakerEmbedderChoices: [String] {
        #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
        ["app"] + SpeakerVoiceprintSelection.Model.allCases.map(\.rawValue)
        #else
        ["app"]
        #endif
    }

    static var diarizationEngineChoices: [String] { CLIDiarization.engineChoices }

    var resolvedOutputDirectory: URL {
        Self.outputDirectory(override: outputDir)
    }

    static func outputDirectory(
        override: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil
    ) -> URL {
        if let override { return URL(fileURLWithPath: override, isDirectory: true) }
        return CaptureLibraryResolver.resolve(environment: environment, homeDirectory: homeDirectory).meetingDirs[0]
    }
}
