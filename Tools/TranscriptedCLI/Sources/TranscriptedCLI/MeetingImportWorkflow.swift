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
            noDownload: command.noDownload,
            engineChoice: command.diarizationEngine,
            storedPreference: CLIDiarization.storedAppPreference()
        )
        let manager = try await TranscribeModelResolver.loadManager(
            modelsDir: modelPaths.parakeet?.path,
            allowDownload: !command.noDownload,
            log: log
        )
        try Task.checkCancellation()
        let voiceprint = try MeetingImportModels.voiceprint(choice: command.speakerEmbedder)
        let embedder = voiceprint.embedder
        let sourceDB = command.speakerDb.map { URL(fileURLWithPath: $0) } ?? voiceprint.databaseURL
        let snapshotDirectory = job.appendingPathComponent("speaker-db", isDirectory: true)
        try fm.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let snapshot = snapshotDirectory.appendingPathComponent(sourceDB.lastPathComponent)
        // Why nobody can be named this run, when that's known up front.
        var identificationUnavailable: String?
        if command.noSpeakerIdentification {
            identificationUnavailable = "speaker identification is off (--no-speaker-identification)"
        } else {
            log("Voiceprints: \(voiceprint.summary). Saved speakers: \(sourceDB.path)")
            if fm.fileExists(atPath: sourceDB.path) {
                do {
                    try SpeakerDatabaseSnapshot.create(sourceURL: sourceDB, destinationURL: snapshot)
                } catch {
                    // Explicit DB failures should be observable to automation.
                    // The default missing/unreadable store permits numbered speakers.
                    if command.speakerDb != nil { throw error }
                    log("Warning: could not read saved speakers; using numbered speakers (\(error.localizedDescription)).")
                    identificationUnavailable = "the saved speaker database couldn't be read"
                }
            } else if command.speakerDb != nil {
                throw ValidationError("Speaker database not found: \(sourceDB.path)")
            } else {
                identificationUnavailable = voiceprint.missingDatabaseReason(fileManager: fm)
                log("No saved speaker database for \(voiceprint.modelName); using numbered speakers.")
            }
        }

        // The snapshot holds this model's vectors, so it uses this model's bars.
        let store = SpeakerDatabase(path: snapshot.path, thresholds: voiceprint.thresholds,
                                    adoptCanonicalModelIdentity: command.speakerDb == nil)
        let originalProfiles = store.allSpeakers()
        if identificationUnavailable == nil, !originalProfiles.isEmpty,
           store.voiceprintModel != voiceprint.activeModel {
            if command.speakerDb != nil {
                throw ValidationError("--speaker-db has a different or unverified voiceprint model. Use that model's canonical app database and matching --speaker-embedder.")
            }
            identificationUnavailable = "the saved speaker database's voiceprint model is unverified or incompatible"
        }
        // A database holds one model's voiceprints. Another model's vectors can't
        // match anyone, so say so instead of quietly numbering everyone.
        if identificationUnavailable == nil,
           let mismatch = MeetingImportVoiceprint.dimensionMismatch(profiles: originalProfiles, voiceprint: voiceprint) {
            if command.speakerDb != nil {
                throw ValidationError("--speaker-db holds \(mismatch) voiceprints, but \(voiceprint.modelName) makes \(voiceprint.dimension)-dimension ones. Pick the matching --speaker-embedder.")
            }
            identificationUnavailable = "the saved speaker database holds a different voiceprint model's people"
        }
        let speech = await MainActor.run { MeetingImportSpeechEngine(manager: manager) }
        var backend = try MeetingImportDiarization.backend(choice: command.diarizationEngine)
        if command.noDownload, backend == .nemotron, !modelPaths.nemotronAvailable {
            log("Nemotron models aren't local and --no-download is set; using pyannote.")
            backend = .pyannote
        }
        let diarization = await MainActor.run {
            DiarizationService(
                bundleProvider: MeetingImportDiarization.bundleProvider(
                    pyannote: modelPaths.diarization, nemotron: modelPaths.nemotron
                ),
                segmentEmbedder: embedder,
                backend: backend,
                allowDownload: !command.noDownload
            )
        }
        await diarization.initialize()
        let ready = await MainActor.run { diarization.isReady }
        guard ready else {
            throw ValidationError("Diarization models failed to load for \(backend.rawValue).")
        }
        let actual = await MainActor.run { diarization.activeBackend }
        let loaded = try CLIDiarization.acceptLoadedEngine(
            requested: backend.rawValue,
            actual: actual.rawValue,
            choice: command.diarizationEngine
        )
        if let note = loaded.fallbackNote {
            log(note)
        }
        let running = DiarizationBackend(rawValue: loaded.engine) ?? actual
        let pipeline = await MainActor.run {
            Transcription(speechToText: speech, diarization: diarization,
                          speakerStore: store, speakerClipsDirectory: job.appendingPathComponent("clips"))
        }
        log("Transcribing and separating speakers with local Parakeet v3 + \(running.footerDisplayName)…")
        try Task.checkCancellation()
        let transcribeStart = ProcessInfo.processInfo.systemUptime
        let result = try await pipeline.transcribeAudioFile(at: normalized)
        try Task.checkCancellation()
        let speechStats = await MainActor.run { (speech.modelCalls, speech.modelSeconds, speech.packedSegmentWindowSamples != nil) }
        let totalSeconds = String(format: "%.2f", ProcessInfo.processInfo.systemUptime - transcribeStart)
        let modelSeconds = String(format: "%.2f", speechStats.1)
        log("Transcribed in \(totalSeconds) s: \(speechStats.0) speech-to-text calls taking \(modelSeconds) s (packing \(speechStats.2 ? "on" : "off")).")
        guard result.systemWordCount > 0 else { throw PipelineError.noSpeechDetected }

        let identities = MeetingImportSpeakerMapping.resolve(
            result: result, originalProfiles: originalProfiles, store: store,
            thresholds: voiceprint.thresholds, nameLikelySpeakers: command.nameLikelySpeakers,
            unavailableReason: identificationUnavailable
        )
        for key in identities.reasons.keys.sorted() {
            let label = identities.mappings[key].map { $0.isConfirmedIdentity ? $0.displayName : "Speaker \($0.speakerId)" } ?? key
            log("\(label): \(identities.reasons[key] ?? "")")
        }
        let captureID = UUID()
        let title = command.title ?? input.deletingPathExtension().lastPathComponent
        // Same note date as the app's "Transcribe a file": when the recording was
        // made (embedded date, else a file timestamp that predates this import),
        // not when it was transcribed.
        let date = await ImportedRecordingDate.resolve(
            from: input,
            sourceAttributes: (try? fm.attributesOfItem(atPath: input.path)) ?? [:]
        )
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result, transcriptId: captureID,
            speakerMappings: identities.mappings, speakerSources: identities.sources, speakerDbIds: identities.databaseIDs,
            date: date, meetingTitle: title,
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio])
        )
        try Task.checkCancellation()
        let receipt = try MeetingImportPublisher.publish(
            markdown: markdown, normalizedAudioURL: command.noRetainAudio ? nil : normalized,
            outputDirectory: command.resolvedOutputDirectory, title: title, captureID: captureID, date: date,
            plainFilename: command.plainFilename
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
    private(set) var modelCalls = 0
    private(set) var modelSeconds: Double = 0
    init(manager: AsrManager) { self.manager = manager }
    func initialize() async {}
    func cleanup() {}

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        try Task.checkCancellation()
        var audio = samples
        if audio.count < 16_000 { audio.append(contentsOf: repeatElement(0, count: 16_000 - audio.count)) }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let callStart = ProcessInfo.processInfo.systemUptime
        let result = try await manager.transcribe(audio, decoderState: &state)
        modelCalls += 1
        modelSeconds += ProcessInfo.processInfo.systemUptime - callStart
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Same packing as the app (see SpeechSegmentPacking): short segments share
    // one 15 s Parakeet window. TRANSCRIPTED_MEETING_STT_PACKING=0 turns it
    // off, which is how a before/after speed run compares the two paths.
    var packedSegmentWindowSamples: Int? {
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_MEETING_STT_PACKING"] != "0" else { return nil }
        return ASRConstants.maxModelSamples - ASRConstants.samplesPerEncoderFrame
    }

    func transcribePackedSegments(
        _ segments: [[Float]],
        source: AudioSource,
        language: TranscriptionLanguageContext
    ) async throws -> [String]? {
        guard segments.count > 1, packedSegmentWindowSamples != nil else { return nil }
        try Task.checkCancellation()
        let layout = SpeechSegmentPacking.layout(segments)
        guard layout.samples.count <= ASRConstants.maxModelSamples else { return nil }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let callStart = ProcessInfo.processInfo.systemUptime
        let result = try await manager.transcribe(layout.samples, decoderState: &state)
        modelCalls += 1
        modelSeconds += ProcessInfo.processInfo.systemUptime - callStart
        try Task.checkCancellation()
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Array(repeating: "", count: segments.count) : nil
        }
        let tokens = timings.map { TimedTranscriptToken(text: $0.token, startSeconds: $0.startTime) }
        return SpeechSegmentPacking.split(tokens: tokens, ranges: layout.ranges)
    }
}

enum MeetingImportModels {
    struct Paths: Sendable {
        let parakeet: URL?
        let diarization: URL?
        /// Flat bundled copy for `bundleProvider`. Never the HuggingFace cache.
        let nemotron: URL?
        /// FluidAudio cache, if complete. Core loads this via HuggingFace, not as a bundle.
        let nemotronCache: URL?
        var nemotronAvailable: Bool { nemotron != nil || nemotronCache != nil }
    }

    static let diarizationRequiredPaths = [
        "Segmentation.mlmodelc", "Embedding.mlmodelc", "FBank.mlmodelc",
        "PldaRho.mlmodelc", "plda-parameters.json", "xvector-transform.json"
    ]

    static let nemotronCacheMarkerName = DiarizationBackend.nemotronCacheMarkerName
    static let nemotronCacheSilenceName = DiarizationBackend.nemotronCacheSilenceName

    /// Flat bundled Nemotron layout for the resolved preset.
    static func nemotronRequiredPaths(
        environment: [String: String] = [:]
    ) -> [String] {
        [
            DiarizationBackend.nemotronModelFileName(preset: resolvedPreset(environment: environment)),
            nemotronCacheSilenceName
        ]
    }

    static func resolvedPreset(environment: [String: String] = [:]) -> String {
        DiarizationService.resolvedNemotronPresetName(environment: environment)
    }

    static let nemotronCacheRelativePath = "Library/Application Support/FluidAudio/Models/nemotron-3-diarization"

    static func defaultNemotronCacheDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(nemotronCacheRelativePath, isDirectory: true)
    }

    static func resolve(
        modelsDir: String?,
        diarizationModelsDir: String?,
        noDownload: Bool,
        engineChoice: String = "app",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedPreference: String? = nil,
        bundledResourceDirectories: [URL] = CLIModelPaths.bundledResourceDirectories(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Paths {
        var modelsDirNemotron: URL?
        let parakeet: URL?
        if let modelsDir {
            let explicit = URL(fileURLWithPath: modelsDir, isDirectory: true)
            let isParakeet = AsrModels.modelsExist(at: explicit)
            let fromDir = diarizationModelsFromDirectory(explicit, environment: environment)
            guard isParakeet || fromDir.nemotron != nil else {
                throw ValidationError("Incomplete Parakeet v3 models at --models-dir: \(modelsDir)")
            }
            parakeet = isParakeet ? explicit : bundledOrCachedParakeet()
            modelsDirNemotron = fromDir.nemotron
        } else {
            parakeet = bundledOrCachedParakeet()
        }
        var diarizationDirNemotron: URL?
        let diarization: URL?
        if let diarizationModelsDir {
            let explicit = URL(fileURLWithPath: diarizationModelsDir, isDirectory: true)
            let fromDir = diarizationModelsFromDirectory(explicit, environment: environment)
            guard fromDir.pyannote != nil || fromDir.nemotron != nil else {
                throw ValidationError("Incomplete diarization models at --diarization-models-dir: \(diarizationModelsDir)")
            }
            diarization = fromDir.pyannote
            diarizationDirNemotron = fromDir.nemotron
        } else {
            let cache = homeDirectory.appendingPathComponent("Library/Application Support/FluidAudio/Models/speaker-diarization")
            diarization = bundledDiarizationModels(in: bundledResourceDirectories)
                ?? fluidAudioRoot(for: cache)
        }
        let discovered = resolveNemotronPaths(
            bundledResourceDirectories: bundledResourceDirectories,
            cacheDirectory: defaultNemotronCacheDirectory(homeDirectory: homeDirectory),
            environment: environment
        )
        let explicitNemotron = modelsDirNemotron ?? diarizationDirNemotron
        let paths = Paths(
            parakeet: parakeet,
            diarization: diarization,
            nemotron: explicitNemotron ?? discovered.bundled,
            nemotronCache: explicitNemotron == nil ? discovered.cache : nil
        )
        if noDownload, let error = try noDownloadError(
            parakeet: paths.parakeet,
            diarization: paths.diarization,
            nemotronAvailable: paths.nemotronAvailable,
            engineChoice: engineChoice,
            environment: environment,
            storedPreference: storedPreference
        ) {
            throw error
        }
        return paths
    }

    static func bundledOrCachedParakeet() -> URL? {
        let cache = AsrModels.defaultCacheDirectory(for: .v3)
        let legacy = cache.deletingLastPathComponent().appendingPathComponent(cache.lastPathComponent + "-coreml")
        return (TranscribeModelResolver.candidateBundledModelDirectories() + [cache, legacy])
            .first { AsrModels.modelsExist(at: $0) }
    }

    /// Same rule `diarize` / `batch` use for `--models-dir`: a flat Nemotron
    /// folder, else a pyannote FluidAudio root.
    static func diarizationModelsFromDirectory(
        _ directory: URL,
        environment: [String: String] = [:]
    ) -> (pyannote: URL?, nemotron: URL?) {
        if completeNemotronModels(at: directory, environment: environment) {
            return (fluidAudioRoot(for: directory), directory)
        }
        if let root = fluidAudioRoot(for: directory) {
            return (root, nil)
        }
        return (nil, nil)
    }

    /// Bundle vs HuggingFace cache. Cache is availability only — never a bundle directory.
    static func resolveNemotronPaths(
        bundledResourceDirectories: [URL] = CLIModelPaths.bundledResourceDirectories(),
        cacheDirectory: URL = defaultNemotronCacheDirectory(),
        environment: [String: String] = [:]
    ) -> (bundled: URL?, cache: URL?) {
        (
            bundledNemotronModels(in: bundledResourceDirectories, environment: environment),
            cachedNemotronModels(at: cacheDirectory, environment: environment)
        )
    }

    static func cachedNemotronModels(
        at directory: URL = defaultNemotronCacheDirectory(),
        environment: [String: String] = [:]
    ) -> URL? {
        completeCachedNemotronModels(at: directory, environment: environment) ? directory : nil
    }

    /// HuggingFace layout (`monolithic/v2/…`, older `monolithic/…`, or flat)
    /// for the resolved preset, plus FluidAudio's weights marker. Without the
    /// matching marker FluidAudio deletes the cache and downloads again.
    static func completeCachedNemotronModels(
        at directory: URL,
        environment: [String: String] = [:]
    ) -> Bool {
        guard matchingNemotronCacheMarker(at: directory) else { return false }
        let fm = FileManager.default
        let silenceCandidates = [
            directory.appendingPathComponent(nemotronCacheSilenceName),
            directory.appendingPathComponent("monolithic/\(nemotronCacheSilenceName)"),
            directory.appendingPathComponent("monolithic/v2/\(nemotronCacheSilenceName)")
        ]
        guard silenceCandidates.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            return false
        }
        let file = DiarizationBackend.nemotronModelFileName(preset: resolvedPreset(environment: environment))
        let modelCandidates = [
            "monolithic/v2/\(file)",
            "monolithic/\(file)",
            file
        ]
        return modelCandidates.contains {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func matchingNemotronCacheMarker(at directory: URL) -> Bool {
        let url = directory.appendingPathComponent(nemotronCacheMarkerName)
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return false
        }
        return DiarizationBackend.nemotronCacheHasMatchingMarker(contents: contents)
    }

    /// `--no-download` checks Parakeet plus the engine that will actually run,
    /// including `--diarization-engine app` resolved against the stored preference.
    static func noDownloadError(
        parakeet: URL?,
        diarization: URL?,
        nemotronAvailable: Bool,
        engineChoice: String,
        environment: [String: String] = [:],
        storedPreference: String? = nil
    ) throws -> ValidationError? {
        if parakeet == nil {
            return ValidationError("--no-download requires complete local Parakeet v3 models. Open Transcripted to install models or supply --models-dir.")
        }
        let engine = try CLIDiarization.resolvedEngine(
            choice: engineChoice,
            environment: environment,
            storedPreference: storedPreference
        )
        let trimmed = engineChoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch engine {
        case "pyannote":
            if diarization == nil {
                return ValidationError("--no-download requires complete local pyannote diarization models when that engine is selected. Open Transcripted to install models or supply --diarization-models-dir.")
            }
        case "nemotron":
            if !nemotronAvailable {
                if trimmed == "nemotron" {
                    return ValidationError("--no-download requires local Nemotron models when --diarization-engine is nemotron. Open Transcripted once or omit --no-download.")
                }
                if diarization == nil {
                    return ValidationError("--no-download requires local Nemotron or pyannote diarization models. Open Transcripted to install models, or supply --diarization-models-dir.")
                }
            }
        default:
            break
        }
        return nil
    }

    static func bundledNemotronModels(
        in resourceDirectories: [URL] = CLIModelPaths.bundledResourceDirectories(),
        environment: [String: String] = [:]
    ) -> URL? {
        resourceDirectories.map { $0.appendingPathComponent("nemotron-diarizer-models", isDirectory: true) }
            .first { completeNemotronModels(at: $0, environment: environment) }
    }

    static func completeNemotronModels(
        at directory: URL,
        environment: [String: String] = [:]
    ) -> Bool {
        nemotronRequiredPaths(environment: environment).allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func bundledDiarizationModels(
        in resourceDirectories: [URL] = CLIModelPaths.bundledResourceDirectories()
    ) -> URL? {
        resourceDirectories.map { resources in
            let bundle = resources.appendingPathComponent("offline-diarizer-models", isDirectory: true)
            return bundle
        }.first { completeDiarizationModels(at: $0.appendingPathComponent("speaker-diarization", isDirectory: true)) }
    }

    /// FluidAudio appends `speaker-diarization` to the directory passed to
    /// OfflineDiarizerModels.load(from:). Passing the model folder itself can
    /// create a second folder inside a signed app and invalidate its signature.
    static func fluidAudioRoot(for directory: URL) -> URL? {
        let root = directory.lastPathComponent == "speaker-diarization"
            ? directory.deletingLastPathComponent() : directory
        let models = root.appendingPathComponent("speaker-diarization", isDirectory: true)
        return completeDiarizationModels(at: models) ? root : nil
    }

    static func completeDiarizationModels(at directory: URL) -> Bool {
        diarizationRequiredPaths.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    // Voiceprint resolution lives in MeetingImportVoiceprint.swift.
}
#endif
