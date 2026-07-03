import ArgumentParser
import Foundation

#if TRANSCRIPTEDCLI_WITH_TRANSCRIPTION && canImport(FluidAudio)
import FluidAudio

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe audio or video files to plain text with the local Parakeet model."
    )

    @Argument(help: "Audio or video files to transcribe (WAV, MP3, M4A, AAC, AIFF, CAF, MP4, MOV, M4V, ...).")
    var mediaPaths: [String]

    @Option(name: .long, help: "Path to a staged Parakeet TDT v3 model folder (a parakeet-tdt-0.6b-v3-coreml HuggingFace clone, or FluidAudio's parakeet-tdt-0.6b-v3 cache folder).")
    var modelsDir: String?

    @Flag(name: .long, help: "Fail instead of downloading models when no local copy exists.")
    var noDownload: Bool = false

    @Flag(name: .long, help: "Output JSON with text, segments, and timing metadata instead of plain text.")
    var json: Bool = false

    @Flag(name: .long, help: "Output SubRip subtitles (SRT) instead of plain text.")
    var srt: Bool = false

    @Option(name: .shortAndLong, help: "Output file path (single input only). Prints to stdout if omitted.")
    var output: String?

    @Option(name: .long, help: "Output directory; writes one <input-stem>.<txt|json|srt> per input file.")
    var outputDir: String?

    func validate() throws {
        guard !mediaPaths.isEmpty else {
            throw ValidationError("Provide at least one audio or video file to transcribe.")
        }
        if output != nil, mediaPaths.count > 1 {
            throw ValidationError("--output supports a single input file. Use --output-dir for multiple files.")
        }
        if output != nil, outputDir != nil {
            throw ValidationError("Use either --output or --output-dir, not both.")
        }
        if srt, mediaPaths.count > 1, outputDir == nil {
            throw ValidationError("SRT output for multiple files needs --output-dir so each file gets its own subtitle track.")
        }
    }

    func run() async throws {
        let format = try TranscribeOutputFormat.resolve(json: json, srt: srt)

        let fileManager = FileManager.default
        let mediaURLs: [URL] = try mediaPaths.map { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else {
                throw ValidationError("Media file not found: \(path)")
            }
            return url
        }

        var batchOutputURLs: [URL]?
        if let outputDir {
            let url = URL(fileURLWithPath: outputDir, isDirectory: true).standardizedFileURL
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            batchOutputURLs = TranscribeOutputBuilder.outputURLs(
                for: mediaURLs,
                outputDirectory: url,
                format: format
            )
        }

        let manager = try await TranscribeModelResolver.loadManager(
            modelsDir: modelsDir,
            allowDownload: !noDownload,
            log: Self.logProgress
        )

        var stdoutJSONOutputs: [TranscribeFileOutput] = []

        for (index, mediaURL) in mediaURLs.enumerated() {
            if mediaURLs.count > 1 {
                Self.logProgress("[\(index + 1)/\(mediaURLs.count)] \(mediaURL.lastPathComponent)")
            }

            Self.logProgress("Decoding \(mediaURL.lastPathComponent)...")
            let decoded = try await TranscribeMediaLoader.loadSamples(from: mediaURL)

            // Parakeet rejects clips under one second; pad short clips with
            // trailing silence instead of surfacing a cryptic model error.
            var samples = decoded.samples
            let minimumSamples = Int(TranscribeMediaLoader.targetSampleRate)
            if samples.count < minimumSamples {
                samples.append(contentsOf: repeatElement(0, count: minimumSamples - samples.count))
            }

            Self.logProgress("Transcribing \(mediaURL.lastPathComponent) (\(Self.formattedDuration(decoded.durationSeconds)))...")
            let startedAt = Date()
            // FluidAudio 0.15.x hands decoder-state ownership to the caller
            // (the 0.7.9 `source:` parameter is gone). Fresh state per file so
            // batch runs can never leak decoder context between inputs.
            let decoderLayers = await manager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            let elapsed = Date().timeIntervalSince(startedAt)

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                Self.logProgress("Warning: no speech detected in \(mediaURL.lastPathComponent)")
            }

            let tokens = (result.tokenTimings ?? []).map { timing in
                TranscribeToken(
                    text: timing.token.replacingOccurrences(of: "\u{2581}", with: " "),
                    startSeconds: timing.startTime,
                    endSeconds: timing.endTime
                )
            }
            let segments = TranscribeOutputBuilder.segments(from: tokens)
            let fileOutput = TranscribeFileOutput(
                file: mediaURL.path,
                text: text,
                durationSeconds: decoded.durationSeconds,
                processingSeconds: elapsed,
                speedFactor: elapsed > 0 ? decoded.durationSeconds / elapsed : 0,
                confidence: Double(result.confidence),
                segments: segments
            )

            Self.logProgress("Done: \(Self.formattedDuration(decoded.durationSeconds)) of audio in \(String(format: "%.1f", elapsed))s")

            let rendered: String
            switch format {
            case .text:
                rendered = text + "\n"
            case .srt:
                rendered = TranscribeOutputBuilder.srt(from: segments)
            case .json:
                rendered = String(
                    data: try TranscribeOutputBuilder.encodeJSON([fileOutput]),
                    encoding: .utf8
                )! + "\n"
            }

            if let output {
                let outputURL = URL(fileURLWithPath: output).standardizedFileURL
                try Data(rendered.utf8).write(to: outputURL)
                Self.logProgress("Wrote \(outputURL.path)")
            } else if let batchOutputURLs {
                let outputURL = batchOutputURLs[index]
                try Data(rendered.utf8).write(to: outputURL)
                Self.logProgress("Wrote \(outputURL.path)")
            } else {
                switch format {
                case .json:
                    // Accumulate so multiple inputs print one valid JSON document.
                    stdoutJSONOutputs.append(fileOutput)
                case .text:
                    if mediaURLs.count > 1 {
                        print("## \(mediaURL.lastPathComponent)")
                    }
                    print(text)
                    if mediaURLs.count > 1, index < mediaURLs.count - 1 {
                        print("")
                    }
                case .srt:
                    print(rendered, terminator: "")
                }
            }
        }

        if !stdoutJSONOutputs.isEmpty {
            let data = try TranscribeOutputBuilder.encodeJSON(stdoutJSONOutputs)
            print(String(data: data, encoding: .utf8)!)
        }
    }

    private static func logProgress(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Resolves where Parakeet models come from, preferring copies that already
/// exist on disk before falling back to the FluidAudio download path:
/// 1. `--models-dir` when the caller passes one
/// 2. the installed Transcripted.app's bundled models
/// 3. the shared FluidAudio cache used by the app
///    (`~/Library/Application Support/FluidAudio/Models/`), downloading into
///    it on first use unless `--no-download` was set.
enum TranscribeModelResolver {
    /// build.sh bundles under the 0.15.x folder name (no `-coreml` suffix).
    static let bundledModelSubpath = "Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3"

    static func candidateBundledModelDirectories(fileManager: FileManager = .default) -> [URL] {
        let applicationRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        return applicationRoots.map { root in
            root.appendingPathComponent("Transcripted.app", isDirectory: true)
                .appendingPathComponent(bundledModelSubpath, isDirectory: true)
        }
    }

    static func loadManager(
        modelsDir: String?,
        allowDownload: Bool,
        log: (String) -> Void
    ) async throws -> AsrManager {
        let models: AsrModels

        if let modelsDir {
            let directory = URL(fileURLWithPath: modelsDir, isDirectory: true).standardizedFileURL
            guard AsrModels.modelsExist(at: directory) else {
                throw ValidationError(
                    "No complete Parakeet TDT v3 model bundle at \(directory.path)."
                        + " Point --models-dir at a staged model folder (a parakeet-tdt-0.6b-v3-coreml"
                        + " HuggingFace clone, or FluidAudio's parakeet-tdt-0.6b-v3 cache folder)."
                )
            }
            log("Loading Parakeet models from \(directory.path)")
            models = try await AsrModels.load(from: directory, version: .v3)
        } else if let bundled = candidateBundledModelDirectories()
            .first(where: { AsrModels.modelsExist(at: $0) }) {
            log("Loading Parakeet models bundled with Transcripted.app")
            models = try await AsrModels.load(from: bundled, version: .v3)
        } else {
            migrateLegacyParakeetCacheIfNeeded(log: log)
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
            let cached = AsrModels.modelsExist(at: cacheDirectory)
            if cached {
                log("Loading Parakeet models from \(cacheDirectory.path)")
            } else if allowDownload {
                log("Downloading Parakeet models (~600MB, first run only) to \(cacheDirectory.path)...")
            } else {
                throw ValidationError(
                    "No local Parakeet models found (checked the installed Transcripted.app and \(cacheDirectory.path))."
                        + " Rerun without --no-download, open Transcripted once so it downloads models, or pass --models-dir."
                )
            }
            let directory = try await AsrModels.download(version: .v3)
            models = try await AsrModels.load(from: directory, version: .v3)
        }

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return manager
    }

    /// FluidAudio 0.15.x renamed the v3 cache folder from
    /// `parakeet-tdt-0.6b-v3-coreml` to `parakeet-tdt-0.6b-v3`. Mirror the
    /// app's in-place rename so a 0.7.9-era cache keeps its ~600MB download
    /// and FluidAudio only fetches the file new in 0.15.x. A failed rename is
    /// harmless — the loader falls back to a fresh download.
    static func migrateLegacyParakeetCacheIfNeeded(
        fileManager: FileManager = .default,
        log: (String) -> Void
    ) {
        let newDir = AsrModels.defaultCacheDirectory(for: .v3)
        guard !newDir.lastPathComponent.hasSuffix("-coreml") else { return }
        let legacyDir = newDir.deletingLastPathComponent()
            .appendingPathComponent(newDir.lastPathComponent + "-coreml", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyDir.path),
              !fileManager.fileExists(atPath: newDir.path) else { return }
        do {
            try fileManager.moveItem(at: legacyDir, to: newDir)
            log("Migrated legacy Parakeet model cache to \(newDir.lastPathComponent)")
        } catch {
            log("Legacy model cache migration failed (will download fresh): \(error.localizedDescription)")
        }
    }
}
#else
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe audio or video files to plain text with the local Parakeet model."
    )

    @Argument(help: "Audio or video files to transcribe (WAV, MP3, M4A, AAC, AIFF, CAF, MP4, MOV, M4V, ...).")
    var mediaPaths: [String]

    @Option(name: .long, help: "Path to a staged Parakeet TDT v3 model folder (a parakeet-tdt-0.6b-v3-coreml HuggingFace clone, or FluidAudio's parakeet-tdt-0.6b-v3 cache folder).")
    var modelsDir: String?

    @Flag(name: .long, help: "Fail instead of downloading models when no local copy exists.")
    var noDownload: Bool = false

    @Flag(name: .long, help: "Output JSON with text, segments, and timing metadata instead of plain text.")
    var json: Bool = false

    @Flag(name: .long, help: "Output SubRip subtitles (SRT) instead of plain text.")
    var srt: Bool = false

    @Option(name: .shortAndLong, help: "Output file path (single input only). Prints to stdout if omitted.")
    var output: String?

    @Option(name: .long, help: "Output directory; writes one <input-stem>.<txt|json|srt> per input file.")
    var outputDir: String?

    func run() async throws {
        throw ValidationError("Local transcription dependencies are unavailable. Run `bash build-deps.sh` from the repo root, then rebuild with `TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1`.")
    }
}
#endif
