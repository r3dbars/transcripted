// WhisperEngine.swift
// WhisperKit-backed local STT engine for advanced Transcripted model choices.

import FluidAudio
import Foundation
import TranscriptedCore
@preconcurrency import WhisperKit

@MainActor
final class WhisperEngine: ObservableObject {
    @Published private(set) var modelDownloadState: ParakeetModelState = .notLoaded

    private let modelRepo = "argmaxinc/whisperkit-coreml"
    private var whisperKit: WhisperKit?
    private var loadedModel: TranscriptionModelChoice?
    private var initializingModel: TranscriptionModelChoice?
    private var initializationTask: Task<Void, Never>?
    private var initializationGeneration = SupersessionEpoch()

    func isModelLoaded(for model: TranscriptionModelChoice) -> Bool {
        loadedModel == model && whisperKit != nil && modelDownloadState.isReady
    }

    func initialize(model: TranscriptionModelChoice) async {
        guard model.isWhisper else { return }

        if isModelLoaded(for: model) {
            return
        }

        if let initializationTask, initializingModel == model {
            await initializationTask.value
            return
        }

        initializationTask?.cancel()
        let generation = initializationGeneration.begin()
        initializingModel = model

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.load(model: model, generation: generation)
        }
        initializationTask = task
        await task.value

        if initializationGeneration.finishIfCurrent(generation) {
            initializationTask = nil
            initializingModel = nil
        }
    }

    func transcribeSamples(
        _ samples: [Float],
        source: AudioSource,
        model: TranscriptionModelChoice,
        languageCode: String? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        guard model.isWhisper else {
            throw NSError(domain: "WhisperEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not a Whisper model."
            ])
        }

        if !isModelLoaded(for: model) {
            await initialize(model: model)
        }

        try Task.checkCancellation()
        guard let whisperKit, isModelLoaded(for: model) else {
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "asr_manager_unavailable",
                message: "WhisperKit model is not loaded",
                context: ["model": model.rawValue]
            )
            throw NSError(domain: "WhisperEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not loaded."
            ])
        }

        guard !samples.isEmpty else { return "" }

        let sourceDescription = source == .microphone ? "microphone" : "system"
        guard TranscriptedConstants.hasMinimumParakeetAudioSamples(samples.count) else {
            let duration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            EventReporter.shared.capture(
                level: .warning,
                engine: model.engineName,
                event: "segment_too_short",
                message: "Skipped short audio segment before Whisper transcription",
                context: [
                    "audio_duration_s": String(format: "%.2f", duration),
                    "minimum_duration_s": String(format: "%.2f", TranscriptedConstants.parakeetMinimumAudioDuration),
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                    "model": model.rawValue,
                ]
            )
            return ""
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: DecodingOptions(
                    task: .transcribe,
                    language: languageCode,
                    temperature: 0,
                    detectLanguage: languageCode == nil,
                    skipSpecialTokens: true,
                    withoutTimestamps: true,
                    concurrentWorkerCount: 1
                )
            )
            try Task.checkCancellation()
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0

            AppLogger.transcription.info("WHISPER | \(model.title) transcribed \(sourceDescription) in \(String(format: "%.2f", elapsed))s, chars=\(trimmed.count)")
            EventReporter.shared.capture(
                level: .info,
                engine: model.engineName,
                event: source == .microphone ? "dictation_transcribed" : "meeting_segment_transcribed",
                message: "Whisper segment transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "model": model.rawValue,
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.2f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(trimmed.count)",
                    "source": sourceDescription,
                ]
            )

            // Apply the user's custom dictionary, mirroring ParakeetEngine.
            // Without this, proper-noun corrections silently fail on the Whisper
            // path. The processor is a no-op when the dictionary is empty.
            return CustomDictionaryTextProcessor.apply(to: trimmed)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "transcription_failed",
                message: error.localizedDescription,
                context: [
                    "model": model.rawValue,
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                    "elapsed": String(format: "%.2f", elapsed),
                ]
            )
            throw error
        }
    }

    /// Detection is local, bounded, and job-scoped. Never store its result on
    /// this shared engine: dictation and the next meeting must stay independent.
    func resolveLanguage(
        representativeSamples: [[Float]],
        selection: TranscriptionLanguageSelection,
        model: TranscriptionModelChoice
    ) async throws -> TranscriptionLanguageContext {
        try Task.checkCancellation()
        let supportedCodes = Set(Constants.languages.values)
        if case let .explicit(code) = selection {
            guard supportedCodes.contains(code) else {
                throw NSError(domain: "WhisperEngine", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "That transcription language is not supported by Whisper. Choose Auto or another language."
                ])
            }
            return TranscriptionLanguageContext(selection: selection, languageCode: code, resolution: .explicit)
        }

        if !isModelLoaded(for: model) { await initialize(model: model) }
        try Task.checkCancellation()
        guard let whisperKit, isModelLoaded(for: model) else {
            throw NSError(domain: "WhisperEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not loaded."
            ])
        }

        var observations: [String?] = []
        for samples in representativeSamples.prefix(3) {
            try Task.checkCancellation()
            // Core supplies speech-selected windows. Keep a second bound at
            // the engine seam for direct callers and reject invalid PCM.
            let bounded = Array(samples.prefix(160_000))
            guard bounded.count >= 32_000, bounded.allSatisfy({ $0.isFinite }) else {
                observations.append(nil)
                continue
            }
            do {
                // `detectLangauge` is the spelling in pinned WhisperKit 0.18.
                // langProbs contains log probabilities, usually only the winner.
                let detected = try await whisperKit.detectLangauge(audioArray: bounded)
                try Task.checkCancellation()
                observations.append(MeetingLanguageDetectionPolicy.confidentLanguage(
                    code: detected.language,
                    logProbability: detected.langProbs[detected.language],
                    supportedCodes: supportedCodes
                ))
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Detection is advisory. An unavailable/ambiguous result must
                // not discard a recording; retain the existing per-window Auto.
                observations.append(nil)
            }
        }
        switch MeetingLanguageDetectionPolicy.resolve(observations) {
        case .multilingual:
            return TranscriptionLanguageContext(selection: selection, languageCode: nil, resolution: .multilingual)
        case let .detected(code):
            return TranscriptionLanguageContext(selection: selection, languageCode: code, resolution: .detected)
        case .uncertain:
            return TranscriptionLanguageContext(selection: selection, languageCode: nil, resolution: .automaticUncertain)
        }
    }

    func cleanup() {
        initializationGeneration.invalidate()
        initializationTask?.cancel()
        initializationTask = nil
        initializingModel = nil
        let pipe = whisperKit
        whisperKit = nil
        loadedModel = nil
        modelDownloadState = .notLoaded
        Task {
            await pipe?.unloadModels()
        }
    }

    private func load(model: TranscriptionModelChoice, generation: SupersessionEpoch.Token) async {
        guard let variant = model.whisperKitModelName else { return }
        guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }

        if loadedModel != model {
            let existing = whisperKit
            whisperKit = nil
            loadedModel = nil
            await existing?.unloadModels()
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
        }

        modelDownloadState = .downloading(progress: 0)
        AppLogger.transcription.info("WHISPER | preparing \(model.title) (\(variant))...")

        do {
            let downloadBase = FileManager.default.transcriptedWhisperModelsDir
            let modelFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                useBackgroundSession: false,
                from: modelRepo
            ) { [weak self] progress in
                Task { @MainActor in
                    guard
                        let self,
                        self.initializationGeneration.isCurrent(generation),
                        self.initializingModel == model
                    else { return }
                    self.modelDownloadState = .downloading(progress: progress.fractionCompleted)
                }
            }

            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
            modelDownloadState = .loading
            AppLogger.transcription.info("WHISPER | loading \(model.title) from \(modelFolder.path)")

            let config = WhisperKitConfig(
                model: variant,
                downloadBase: downloadBase,
                modelRepo: modelRepo,
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false,
                useBackgroundDownloadSession: false
            )
            let pipe = try await WhisperKit(config)

            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else {
                await pipe.unloadModels()
                return
            }

            whisperKit = pipe
            loadedModel = model
            modelDownloadState = .ready
            EventReporter.shared.capture(
                level: .info,
                engine: model.engineName,
                event: "model_ready",
                message: "\(model.title) initialized successfully",
                context: [
                    "model": model.rawValue,
                    "variant": variant,
                    "repo": modelRepo,
                    "model_path": modelFolder.lastPathComponent,
                ]
            )
        } catch {
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
            let friendlyMessage = "Couldn't load \(model.title): \(error.localizedDescription)"
            AppLogger.transcription.error("WHISPER | \(friendlyMessage)")
            modelDownloadState = .failed(friendlyMessage)
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "model_init_failed",
                message: friendlyMessage,
                context: [
                    "model": model.rawValue,
                    "variant": variant,
                    "repo": modelRepo,
                ]
            )
        }
    }
}
