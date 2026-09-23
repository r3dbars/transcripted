// AppleSpeechEngine.swift
// macOS 26 on-device speech engine (SpeechAnalyzer + SpeechTranscriber).
// Audio never leaves the Mac. Apple downloads and owns the per-language model
// files; this engine only asks for them and reports progress.

@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio
import Foundation
import Speech
import TranscriptedCore

enum AppleSpeechEngineError: LocalizedError, Equatable {
    case unavailable
    case unsupportedLanguage(String)
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Speech isn't available on this Mac. Choose another model in Settings."
        case .unsupportedLanguage(let languageName):
            return "Apple Speech can't transcribe \(languageName) yet. Choose another meeting language or another model in Settings."
        case .audioConversionFailed:
            return "Apple Speech transcription failed: the audio couldn't be converted for Apple's engine."
        }
    }
}

@MainActor
final class AppleSpeechEngine: ObservableObject {
    @Published private(set) var modelDownloadState: ParakeetModelState = .notLoaded

    static let engineName = "apple_speech"

    private var supportedLocaleIdentifiersCache: [String]?
    /// Locales whose Apple assets this process has confirmed are installed.
    private var installedLocaleIdentifiers: Set<String> = []
    private var localeInstallTasks: [String: Task<Void, Error>] = [:]
    private var initializationTask: Task<Void, Never>?
    private var initializationGeneration = SupersessionEpoch()

    var isModelLoaded: Bool { modelDownloadState.isReady }

    // MARK: - Setup

    /// Confirms Apple's engine runs on this Mac and installs the language most
    /// likely to be used next: an explicit meeting language when one is saved
    /// and supported, otherwise the Mac's own language. Other languages are
    /// installed on demand when a recording asks for them.
    func initialize() async {
        if isModelLoaded { return }
        if let initializationTask {
            await initializationTask.value
            return
        }

        let generation = initializationGeneration.begin()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareDefaultLanguage(generation: generation)
        }
        initializationTask = task
        await task.value
        if initializationGeneration.finishIfCurrent(generation) {
            initializationTask = nil
        }
    }

    func cleanup() {
        initializationGeneration.invalidate()
        initializationTask?.cancel()
        initializationTask = nil
        for task in localeInstallTasks.values { task.cancel() }
        localeInstallTasks.removeAll()
        modelDownloadState = .notLoaded
    }

    private func prepareDefaultLanguage(generation: SupersessionEpoch.Token) async {
        modelDownloadState = .loading
        do {
            let locale = try await defaultLocale()
            try await ensureAssetsInstalled(for: locale)
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
            modelDownloadState = .ready
            EventReporter.shared.capture(
                level: .info,
                engine: Self.engineName,
                event: "model_ready",
                message: "Apple Speech is ready",
                context: ["locale": locale.identifier]
            )
        } catch {
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
            let message = error.localizedDescription
            modelDownloadState = .failed(message)
            EventReporter.shared.capture(
                level: .error,
                engine: Self.engineName,
                event: "model_init_failed",
                message: message,
                context: [:]
            )
        }
    }

    private func defaultLocale() async throws -> Locale {
        let meetingLanguage = TranscriptionLanguagePreferences.preferredLanguageCode()
        if meetingLanguage != TranscriptionLanguagePreferences.automaticValue,
           let locale = try? await resolveLocale(forLanguageCode: meetingLanguage) {
            return locale
        }
        return try await resolveLocale(forLanguageCode: nil)
    }

    // MARK: - Languages

    /// The Mac's first preferred language, not the app's UI localization.
    static var macLanguageCode: String {
        let preferred = Locale.preferredLanguages.first.map(AppleSpeechLocalePolicy.languageCode(ofIdentifier:))
        if let preferred, !preferred.isEmpty { return preferred }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Bare language codes (like "es") Apple's engine can transcribe on this Mac.
    static func supportedLanguageCodes() async -> Set<String> {
        let identifiers = await SpeechTranscriber.supportedLocales.map(\.identifier)
        return AppleSpeechLocalePolicy.supportedLanguageCodes(supportedIdentifiers: identifiers)
    }

    static func languageDisplayName(for code: String) -> String {
        let catalogName = TranscriptionLanguagePreferences.displayName(for: code)
        if catalogName != "Auto" { return catalogName }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private func supportedLocaleIdentifiers() async -> [String] {
        if let supportedLocaleIdentifiersCache { return supportedLocaleIdentifiersCache }
        let identifiers = await SpeechTranscriber.supportedLocales.map(\.identifier)
        if !identifiers.isEmpty {
            supportedLocaleIdentifiersCache = identifiers
        }
        return identifiers
    }

    /// nil means Auto, which for Apple's engine is the Mac's language: the
    /// engine can't detect the spoken language on its own.
    private func resolveLocale(forLanguageCode languageCode: String?) async throws -> Locale {
        let supported = await supportedLocaleIdentifiers()
        guard !supported.isEmpty else { throw AppleSpeechEngineError.unavailable }
        let wanted = languageCode ?? Self.macLanguageCode
        guard let identifier = AppleSpeechLocalePolicy.bestLocaleIdentifier(
            languageCode: wanted,
            preferredRegion: Locale.current.region?.identifier,
            supportedIdentifiers: supported
        ) else {
            throw AppleSpeechEngineError.unsupportedLanguage(Self.languageDisplayName(for: wanted))
        }
        return Locale(identifier: identifier)
    }

    /// Job-scoped: never stored on the engine, so dictation and the next
    /// meeting stay independent.
    func resolveLanguage(selection: TranscriptionLanguageSelection) async throws -> TranscriptionLanguageContext {
        try Task.checkCancellation()
        switch selection {
        case .explicit(let code):
            let locale = try await resolveLocale(forLanguageCode: code)
            try await ensureAssetsInstalled(for: locale)
            return TranscriptionLanguageContext(selection: selection, languageCode: code, resolution: .explicit)
        case .automatic:
            let locale = try await resolveLocale(forLanguageCode: nil)
            try await ensureAssetsInstalled(for: locale)
            // Auto means "the Mac's language", not an acoustic detection.
            return TranscriptionLanguageContext(
                selection: selection,
                languageCode: AppleSpeechLocalePolicy.languageCode(ofIdentifier: locale.identifier),
                resolution: .automaticUncertain
            )
        }
    }

    // MARK: - Assets

    private func ensureAssetsInstalled(for locale: Locale) async throws {
        let key = locale.identifier
        if installedLocaleIdentifiers.contains(key) { return }
        if let existing = localeInstallTasks[key] {
            try await existing.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.installAssets(for: locale)
        }
        localeInstallTasks[key] = task
        do {
            try await task.value
            localeInstallTasks[key] = nil
            installedLocaleIdentifiers.insert(key)
        } catch {
            localeInstallTasks[key] = nil
            throw error
        }
    }

    private func installAssets(for locale: Locale) async throws {
        let transcriber = Self.makeTranscriber(locale: locale)
        // nil means Apple already has everything this locale needs.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }

        AppLogger.transcription.info("APPLE SPEECH | downloading language files for \(locale.identifier)")
        let previousState = modelDownloadState
        modelDownloadState = .downloading(progress: 0)
        let progress = request.progress
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if case .downloading = self.modelDownloadState {
                    self.modelDownloadState = .downloading(progress: progress.fractionCompleted)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { progressTask.cancel() }

        do {
            try await request.downloadAndInstall()
        } catch {
            EventReporter.shared.capture(
                level: .error,
                engine: Self.engineName,
                event: "asset_install_failed",
                message: error.localizedDescription,
                context: ["locale": locale.identifier]
            )
            if case .downloading = modelDownloadState { modelDownloadState = previousState }
            throw error
        }
        if case .downloading = modelDownloadState { modelDownloadState = previousState }
    }

    // MARK: - Transcription

    func transcribeSamples(
        _ samples: [Float],
        source: AudioSource,
        languageCode: String?
    ) async throws -> String {
        try Task.checkCancellation()
        guard !samples.isEmpty else { return "" }

        let sourceDescription = source == .microphone ? "microphone" : "system"
        guard TranscriptedConstants.hasMinimumParakeetAudioSamples(samples.count) else {
            let duration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            EventReporter.shared.capture(
                level: .warning,
                engine: Self.engineName,
                event: "segment_too_short",
                message: "Skipped short audio segment before Apple Speech transcription",
                context: [
                    "audio_duration_s": String(format: "%.2f", duration),
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                ]
            )
            return ""
        }

        let locale = try await resolveLocale(forLanguageCode: languageCode)
        try await ensureAssetsInstalled(for: locale)
        try Task.checkCancellation()

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let text = try await Self.transcribe(samples: samples, locale: locale)
            try Task.checkCancellation()
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0

            AppLogger.transcription.info("APPLE SPEECH | transcribed \(sourceDescription) in \(String(format: "%.2f", elapsed))s, chars=\(text.count)")
            EventReporter.shared.capture(
                level: .info,
                engine: Self.engineName,
                event: source == .microphone ? "dictation_transcribed" : "meeting_segment_transcribed",
                message: "Apple Speech segment transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "locale": locale.identifier,
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.2f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(text.count)",
                    "source": sourceDescription,
                ]
            )

            // Apply the user's custom dictionary, mirroring the other engines.
            return CustomDictionaryTextProcessor.apply(to: text)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            EventReporter.shared.capture(
                level: .error,
                engine: Self.engineName,
                event: "transcription_failed",
                message: error.localizedDescription,
                context: [
                    "locale": locale.identifier,
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                ]
            )
            throw error
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // No volatile results: only finalized text is collected.
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    /// One analyzer per segment keeps segments independent, like the other
    /// engines. Apple keeps the model itself resident between analyzers.
    private static func transcribe(samples: [Float], locale: Locale) async throws -> String {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let inputBuffer = makePCMBuffer(samples: samples) else {
            throw AppleSpeechEngineError.audioConversionFailed
        }
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let buffer: AVAudioPCMBuffer
        if let analyzerFormat {
            buffer = try convert(inputBuffer, to: analyzerFormat)
        } else {
            buffer = inputBuffer
        }

        let collector = Task { () throws -> [String] in
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            }
            return parts
        }

        do {
            let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            inputBuilder.finish()
            if let lastSampleTime = try await analyzer.analyzeSequence(inputSequence) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let parts = try await collector.value
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio

    private static func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: TranscriptedConstants.parakeetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw AppleSpeechEngineError.audioConversionFailed
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AppleSpeechEngineError.audioConversionFailed
        }

        var consumedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            throw AppleSpeechEngineError.audioConversionFailed
        }
        return output
    }
}
