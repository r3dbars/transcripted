import ArgumentParser
import Darwin
import Foundation
import TranscriptedCaptureKit

/// Full meeting import is additive: `transcribe` keeps its text/JSON/SRT contract.
struct ImportAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-audio",
        abstract: "Transcribe and diarize a file into the Transcripted meeting library.",
        discussion: "Uses local Parakeet v3 and PyAnnote. Never records audio or deletes the input. "
            + "Recognizes eligible saved speakers from a read-only snapshot; does not learn new people. "
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

    @Option(name: .long, help: "Voiceprint model: app (default), wespeaker, or eres2net. ERes2Net requires an installed local model.")
    var speakerEmbedder = "app"

    @Option(name: .long, help: "Path to a complete Parakeet TDT v3 model directory.")
    var modelsDir: String?

    @Option(name: .long, help: "Path to a complete offline speaker-diarization model directory.")
    var diarizationModelsDir: String?

    @Flag(name: .long, help: "Never download models. Missing or incomplete local models are errors.")
    var noDownload = false

    @Flag(name: .long, help: "Print one JSON receipt to stdout; diagnostics go to stderr.")
    var json = false

    mutating func validate() throws {
        guard ["app", "wespeaker", "eres2net"].contains(speakerEmbedder) else {
            throw ValidationError("--speaker-embedder must be app, wespeaker, or eres2net.")
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
