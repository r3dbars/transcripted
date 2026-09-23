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
    case unsupportedMacLanguage(String)
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Speech isn't available on this Mac. Choose another model in Settings."
        case .unsupportedLanguage(let languageName):
            return "Apple Speech can't transcribe \(languageName) yet. Choose another meeting language or another model in Settings."
        case .unsupportedMacLanguage(let languageName):
            return "Apple Speech can't transcribe your Mac's language (\(languageName)) yet. Choose another model in Settings."
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

    /// Confirms Apple's engine runs on this Mac and installs the language
    /// dictation uses (the Mac's language). A different saved meeting language
    /// then downloads quietly in the background so the first meeting doesn't
    /// wait on it. Any other language installs when a recording asks for it.
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
            let locale = try await resolveDictationLocale()
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
            prefetchMeetingLanguage(skipping: locale)
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

    /// Not awaited: initialize() callers (a dictation stop, a meeting start)
    /// shouldn't wait on a language they may not use. A meeting that does
    /// need it joins the same install task.
    private func prefetchMeetingLanguage(skipping installed: Locale) {
        guard let meetingLanguage = explicitMeetingLanguageCode() else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let locale = try? await self.resolveLocale(forLanguageCode: meetingLanguage),
                  locale.identifier != installed.identifier
            else { return }
            try? await self.ensureAssetsInstalled(for: locale)
        }
    }

    private func explicitMeetingLanguageCode() -> String? {
        let code = TranscriptionLanguagePreferences.preferredLanguageCode()
        return code == TranscriptionLanguagePreferences.automaticValue ? nil : code
    }

    /// Dictation has no language setting, so it uses the Mac's language. When
    /// Apple can't transcribe that, a saved meeting language Apple supports is
    /// the next best guess at what the person speaks.
    private func resolveDictationLocale() async throws -> Locale {
        do {
            return try await resolveLocale(forLanguageCode: nil)
        } catch AppleSpeechEngineError.unsupportedLanguage(_) {
            if let meetingLanguage = explicitMeetingLanguageCode(),
               let locale = try? await resolveLocale(forLanguageCode: meetingLanguage) {
                return locale
            }
            throw AppleSpeechEngineError.unsupportedMacLanguage(Self.languageDisplayName(for: Self.macLanguageCode))
        }
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
        // The Mac's language entry ("zh-Hant-TW") says more than its region
        // setting, which can be anywhere.
        let macLanguage = Locale.preferredLanguages.first ?? ""
        guard let identifier = AppleSpeechLocalePolicy.bestLocaleIdentifier(
            languageCode: wanted,
            preferredRegion: AppleSpeechLocalePolicy.regionCode(ofIdentifier: macLanguage)
                ?? Locale.current.region?.identifier,
            preferredScript: AppleSpeechLocalePolicy.scriptCode(ofIdentifier: macLanguage),
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
            // Auto means "the Mac's language", not an acoustic detection, so
            // this isn't `.detected`. Unlike Whisper's uncertain result it
            // carries a code: every segment needs one locale. Retries read the
            // saved selection (Auto), not this resolved code, so a later run
            // follows the Mac's language at that time.
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
            clearInstallTask(task, forKey: key)
            installedLocaleIdentifiers.insert(key)
        } catch {
            clearInstallTask(task, forKey: key)
            throw error
        }
    }

    /// cleanup() can replace the map while an install is in flight; only clear
    /// the entry this caller created.
    private func clearInstallTask(_ task: Task<Void, Error>, forKey key: String) {
        if localeInstallTasks[key] == task {
            localeInstallTasks[key] = nil
        }
    }

    private func installAssets(for locale: Locale) async throws {
        let transcriber = Self.makeTranscriber(locale: locale)
        // nil means Apple already has everything this locale needs.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }

        AppLogger.transcription.info("APPLE SPEECH | downloading language files for \(locale.identifier)")
        // Once the engine is ready, a later language downloads quietly.
        // Publishing .downloading then would flip isModelLoaded to false and
        // make dictation wait on a meeting language it doesn't use.
        let reportsProgress = !modelDownloadState.isReady
        let previousState = modelDownloadState
        var progressTask: Task<Void, Never>?
        if reportsProgress {
            modelDownloadState = .downloading(progress: 0)
            let progress = request.progress
            progressTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if case .downloading = self.modelDownloadState {
                        self.modelDownloadState = .downloading(progress: progress.fractionCompleted)
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        defer { progressTask?.cancel() }

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
            if reportsProgress, case .downloading = modelDownloadState { modelDownloadState = previousState }
            throw error
        }
        if reportsProgress, case .downloading = modelDownloadState { modelDownloadState = previousState }
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

        let locale: Locale
        if let languageCode {
            locale = try await resolveLocale(forLanguageCode: languageCode)
        } else {
            locale = try await resolveDictationLocale()
        }
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
    /// engines. The meeting pipeline calls this once per diarized segment, so
    /// `.lingering` asks Apple to keep the model loaded between analyzers
    /// instead of reloading it for every segment (the default, `.whileInUse`,
    /// may unload it as soon as each analyzer finishes).
    private static func transcribe(samples: [Float], locale: Locale) async throws -> String {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )

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
