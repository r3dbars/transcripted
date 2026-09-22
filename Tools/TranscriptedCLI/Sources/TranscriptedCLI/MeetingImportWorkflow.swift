#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
import ArgumentParser
import AVFoundation
import Combine
import FluidAudio
import Foundation
import TranscriptedCore

enum MeetingImportWorkflow {
    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func run(_ command: ImportAudio) async throws -> MeetingImportReceipt {
        let fm = FileManager.default
        let input = try validatedInput(command.mediaPath)
        // Foundation may ignore a caller-assigned TMPDIR on macOS. Honor the
        // usual CLI override explicitly so automation can isolate its scratch.
        let tempRoot: URL
        if let temporaryPath = ProcessInfo.processInfo.environment["TMPDIR"], !temporaryPath.isEmpty {
            guard temporaryPath.hasPrefix("/") else { throw ValidationError("TMPDIR must be an absolute directory path.") }
            tempRoot = URL(fileURLWithPath: temporaryPath, isDirectory: true)
        } else {
            tempRoot = fm.temporaryDirectory
        }
        let job = tempRoot.appendingPathComponent("transcripted-cli-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: job) }

        try Task.checkCancellation()
        log("Decoding \(input.lastPathComponent)…")
        let normalized = job.appendingPathComponent("input.wav")
        // Release the whole-file decode buffer before the shared pipeline loads
        // it. This file is ours; the supplied input is never renamed or removed.
        try await normalize(input, to: normalized)
        try Task.checkCancellation()

        let modelPaths = try MeetingImportModels.resolve(
            modelsDir: command.modelsDir,
            diarizationModelsDir: command.diarizationModelsDir,
            noDownload: command.noDownload
        )
        let manager = try await TranscribeModelResolver.loadManager(
            modelsDir: modelPaths.parakeet?.path,
            allowDownload: !command.noDownload,
            log: log
        )
        try Task.checkCancellation()
        let embedder = try MeetingImportModels.speakerEmbedder(choice: command.speakerEmbedder)
        let sourceDB = command.speakerDb.map { URL(fileURLWithPath: $0) }
            ?? CoreStoragePaths.default.speakerDB.deletingLastPathComponent()
                .appendingPathComponent(embedder == nil ? "speakers.sqlite" : "speakers_eres2net.sqlite")
        let snapshot = job.appendingPathComponent("speakers.sqlite")
        if !command.noSpeakerIdentification {
            if fm.fileExists(atPath: sourceDB.path) {
                do {
                    try SpeakerDatabaseSnapshot.create(sourceURL: sourceDB, destinationURL: snapshot)
                } catch {
                    // Explicit DB failures should be observable to automation.
                    // The default missing/unreadable store permits numbered speakers.
                    if command.speakerDb != nil { throw error }
                    log("Warning: could not read saved speakers; using numbered speakers (\(error.localizedDescription)).")
                }
            } else if command.speakerDb != nil {
                throw ValidationError("Speaker database not found: \(sourceDB.path)")
            } else {
                log("No saved speaker database; using numbered speakers.")
            }
        }

        let store = SpeakerDatabase(path: snapshot.path)
        let originalProfiles = store.allSpeakers()
        let pipeline = await MainActor.run {
            let speech = MeetingImportSpeechEngine(manager: manager)
            let diarization = DiarizationService(
                bundleProvider: { _ in modelPaths.diarization },
                segmentEmbedder: embedder
            )
            return Transcription(speechToText: speech, diarization: diarization,
                                 speakerStore: store, speakerClipsDirectory: job.appendingPathComponent("clips"))
        }
        log("Transcribing and separating speakers with local Parakeet v3 + PyAnnote…")
        try Task.checkCancellation()
        let result = try await pipeline.transcribeAudioFile(at: normalized)
        try Task.checkCancellation()
        guard result.systemWordCount > 0 else { throw PipelineError.noSpeechDetected }

        let identities = MeetingImportSpeakerMapping.resolve(result: result, originalProfiles: originalProfiles, store: store)
        let captureID = UUID()
        let title = command.title ?? input.deletingPathExtension().lastPathComponent
        let date = Date()
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result, transcriptId: captureID,
            speakerMappings: identities.mappings, speakerSources: identities.sources, speakerDbIds: identities.databaseIDs,
            date: date, meetingTitle: title,
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio])
        )
        try Task.checkCancellation()
        let receipt = try MeetingImportPublisher.publish(
            markdown: markdown, normalizedAudioURL: command.noRetainAudio ? nil : normalized,
            outputDirectory: command.resolvedOutputDirectory, title: title, captureID: captureID, date: date
        )
        log("Saved \(result.systemWordCount) words, \(result.systemSpeakerCount) speaker(s). Original input preserved.")
        return receipt
    }

    static func validatedInput(_ path: String) throws -> URL {
        let input = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard (try? input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ValidationError("Input must be an existing regular audio/video file: \(path)")
        }
        return input
    }

    static func normalize(_ input: URL, to output: URL) async throws {
        let decoded = try await TranscribeMediaLoader.loadSamples(from: input)
        try Task.checkCancellation()
        guard decoded.durationSeconds >= 2 else {
            throw ValidationError("Meeting imports need at least 2 seconds of audio; use transcribe for shorter clips.")
        }
        guard decoded.samples.count <= Int(UInt32.max),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(decoded.samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw ValidationError("Could not allocate normalized audio; try a shorter recording.")
        }
        buffer.frameLength = buffer.frameCapacity
        decoded.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

@MainActor
private final class MeetingImportSpeechEngine: SpeechToTextEngine {
    let manager: AsrManager
    var isReady: Bool { true }
    init(manager: AsrManager) { self.manager = manager }
    func initialize() async {}
    func cleanup() {}

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        try Task.checkCancellation()
        var audio = samples
        if audio.count < 16_000 { audio.append(contentsOf: repeatElement(0, count: 16_000 - audio.count)) }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MeetingImportModels {
    struct Paths: Sendable { let parakeet: URL?; let diarization: URL? }

    static let diarizationRequiredPaths = [
        "Segmentation.mlmodelc", "Embedding.mlmodelc", "FBank.mlmodelc",
        "PldaRho.mlmodelc", "plda-parameters.json", "xvector-transform.json"
    ]

    static func resolve(modelsDir: String?, diarizationModelsDir: String?, noDownload: Bool) throws -> Paths {
        let fm = FileManager.default
        let parakeet: URL?
        if let modelsDir {
            let explicit = URL(fileURLWithPath: modelsDir, isDirectory: true)
            guard AsrModels.modelsExist(at: explicit) else { throw ValidationError("Incomplete Parakeet v3 models at --models-dir: \(modelsDir)") }
            parakeet = explicit
        } else {
            let cache = AsrModels.defaultCacheDirectory(for: .v3)
            let legacy = cache.deletingLastPathComponent().appendingPathComponent(cache.lastPathComponent + "-coreml")
            parakeet = (TranscribeModelResolver.candidateBundledModelDirectories() + [cache, legacy])
                .first { AsrModels.modelsExist(at: $0) }
        }
        let diarization: URL?
        if let diarizationModelsDir {
            let explicit = URL(fileURLWithPath: diarizationModelsDir, isDirectory: true)
            guard completeDiarizationModels(at: explicit) else { throw ValidationError("Incomplete diarization models at --diarization-models-dir: \(diarizationModelsDir)") }
            diarization = explicit
        } else {
            let resources = CLIModelPaths.bundledResourceDirectories()
            let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FluidAudio/Models/speaker-diarization")
            diarization = (resources.map { $0.appendingPathComponent("offline-diarizer-models") } + [cache])
                .first { completeDiarizationModels(at: $0) }
        }
        if noDownload && (parakeet == nil || diarization == nil) {
            throw ValidationError("--no-download requires complete local Parakeet v3 AND offline diarization models. Open Transcripted to install models or supply --models-dir and --diarization-models-dir.")
        }
        return Paths(parakeet: parakeet, diarization: diarization)
    }

    static func completeDiarizationModels(at directory: URL) -> Bool {
        diarizationRequiredPaths.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func speakerEmbedder(choice: String) throws -> (any SpeakerSegmentEmbedder)? {
        let preferences = UserDefaults.standard.persistentDomain(forName: "com.justinbetker.draft")
        let allowed = ["wespeaker", "eres2net"]
        let environmentChoice = ProcessInfo.processInfo.environment["TRANSCRIPTED_SPEAKER_EMBEDDER"]?.lowercased()
        let preference = preferences?["speaker-embedder-preference"] as? String
        let appChoice = environmentChoice.flatMap { allowed.contains($0) ? $0 : nil }
            ?? preference.flatMap { allowed.contains($0) ? $0 : nil } ?? "wespeaker"
        let resolved = choice == "app" ? appChoice : choice
        guard resolved == "eres2net" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = CLIModelPaths.bundledResourceDirectories().map {
            $0.appendingPathComponent("eres2net-embedding/Model.mlmodelc")
        } + [home.appendingPathComponent("Library/Application Support/FluidAudio/Models/eres2net-embedding/Model.mlmodelc")]
        for model in candidates where FileManager.default.fileExists(atPath: model.path) {
            if let embedder = ERes2NetEmbedder(modelURL: model) { return embedder }
        }
        if choice == "eres2net" { throw ValidationError("ERes2Net was explicitly selected but its local model could not load. Install it in Transcripted, or select --speaker-embedder wespeaker.") }
        MeetingImportWorkflow.log("Warning: the app's ERes2Net model is unavailable; using WeSpeaker and its separate speaker database, as the app does.")
        return nil
    }
}
#endif
