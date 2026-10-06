// STTRouter.swift
// Shared STT router for dictation, meetings, and imported audio.

import Combine
import FluidAudio
import Foundation
import TranscriptedCore

@MainActor
class STTRouter: ObservableObject {
    /// The dictation waveform's live meter reading. Kept off this router's
    /// objectWillChange: it ticks ~25-30 times a second while recording, and
    /// the Settings window observes the whole router (see
    /// DictationAudioLevels). The engine that records publishes into it.
    let audioLevels: DictationAudioLevels
    let parakeetEngine: ParakeetEngine
    private let whisperEngine = WhisperEngine()
    private let appleSpeechEngine = AppleSpeechEngine()

    @Published private(set) var selectedModel = TranscriptionModelPreferences.preferredModel()
    @Published private(set) var modelDownloadState: ParakeetModelState = .notLoaded
    /// A meeting language Apple Speech is downloading or failed to download,
    /// for the Meeting language row in Settings.
    @Published private(set) var appleSpeechLanguageDownload: AppleSpeechLanguageDownload?
    @Published var isRecording = false
    /// True while the engine finishes a take or while Transcribe again runs
    /// over a saved dictation file, so a new dictation queues behind either.
    @Published var isTranscribing = false
    /// Transcribe again is running (`transcribeSavedDictation`).
    @Published private(set) var isTranscribingSavedDictation = false
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true
    private(set) var lastEmptyTranscriptionReason: DictationEmptyTranscriptionReason?
    /// Text from the latest dictation that was held back as `.otherLanguage`,
    /// for the Paste Anyway button. Memory only; never logged or sent.
    private(set) var heldBackDictationText: String?

    private var cancellables: Set<AnyCancellable> = []
    private var recordingModelOwnership = TranscriptionRecordingModelOwnership()
    private var warmupOwnership = TranscriptionModelWarmupOwnership()
    private var backgroundWarmupTask: Task<Void, Never>?
    private var backgroundWarmupGeneration = SupersessionEpoch()
    private var isShuttingDown = false

    private var activeRecordingModel: TranscriptionModelChoice? {
        recordingModelOwnership.activeLease?.model
    }

    var recordingModelLease: TranscriptionRecordingModelLease? {
        recordingModelOwnership.activeLease
    }

    private var recordingModel: TranscriptionModelChoice {
        activeRecordingModel
            ?? warmupOwnership.foregroundModel(on: selectedModel.runtime)
            ?? selectedModel
    }

    var isModelLoaded: Bool {
        isModelLoaded(for: selectedModel)
    }

    var isRecordingModelLoaded: Bool {
        isModelLoaded(for: recordingModel)
    }

    var recordingModelDownloadState: ParakeetModelState {
        modelDownloadState(for: recordingModel)
    }

    var inputDeviceName: String { parakeetEngine.inputDeviceName }
    var lastRecordingWasDigitalSilence: Bool { parakeetEngine.lastRecordingWasDigitalSilence }
    var isRecordingFromSharedMeetingMic: Bool { parakeetEngine.isRecordingFromSharedMeetingMic }
    var hasRecoverableRecording: Bool { parakeetEngine.hasRecoverableRecording }

    /// One take, kept across a device-recovery restart within it.
    var dictationRecordingIdentity: UUID { parakeetEngine.recordingIdentity }

    /// Sends a copy of this dictation's mic audio to the island's live
    /// preview, or stops (nil). Every model records through the same engine.
    func setDictationPreviewSink(_ sink: DictationPreviewSampleSink?) {
        parakeetEngine.pendingSamplesLock.withLock { parakeetEngine.previewSink = sink }
    }
    var dictationAudioRouteAnalyticsContext: [String: String] {
        parakeetEngine.currentAudioRouteAnalyticsContext
    }

    init() {
        let audioLevels = DictationAudioLevels()
        self.audioLevels = audioLevels
        parakeetEngine = ParakeetEngine(audioLevels: audioLevels)
        parakeetEngine.$isRecording.assign(to: &$isRecording)
        parakeetEngine.$isTranscribing
            .combineLatest($isTranscribingSavedDictation)
            .map { $0 || $1 }
            .removeDuplicates()
            .assign(to: &$isTranscribing)
        parakeetEngine.$recordingInterrupted.assign(to: &$recordingInterrupted)
        parakeetEngine.$isRecovering.assign(to: &$isRecovering)
        parakeetEngine.$inputFormatReady.assign(to: &$inputFormatReady)

        parakeetEngine.$modelDownloadState
            .sink { [weak self] state in
                guard let self else { return }
                // @Published emits before storage changes. Forward the emitted
                // value only when it belongs to the selected concrete variant.
                self.refreshModelDownloadState(
                    publishedState: self.selectedModel.parakeetVariant == self.parakeetEngine.modelVariant
                        ? state : nil
                )
            }
            .store(in: &cancellables)

        whisperEngine.$modelDownloadState
            .sink { [weak self] state in
                guard let self else { return }
                self.refreshModelDownloadState(publishedState: self.selectedModel.isWhisper ? state : nil)
            }
            .store(in: &cancellables)

        appleSpeechEngine.$modelDownloadState
            .sink { [weak self] state in
                guard let self else { return }
                self.refreshModelDownloadState(publishedState: self.selectedModel.isAppleSpeech ? state : nil)
            }
            .store(in: &cancellables)

        appleSpeechEngine.$languageDownload
            .removeDuplicates()
            .sink { [weak self] download in
                self?.appleSpeechLanguageDownload = download
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .transcriptionModelPreferenceDidChange)
            .sink { [weak self] _ in
                self?.handleModelSelectionChange()
            }
            .store(in: &cancellables)

        refreshModelDownloadState()
    }

    func isModelLoaded(for model: TranscriptionModelChoice) -> Bool {
        switch model {
        case .parakeetTDTv2:
            return parakeetEngine.isModelLoaded(for: .v2)
        case .parakeetTDTv3:
            return parakeetEngine.isModelLoaded(for: .v3)
        case .parakeetUltraExperimental:
            return parakeetEngine.isModelLoaded(for: .ultra)
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return whisperEngine.isModelLoaded(for: model)
        case .appleSpeech:
            return appleSpeechEngine.isModelLoaded
        }
    }

    private func handleModelSelectionChange() {
        let nextModel = TranscriptionModelPreferences.preferredModel()
        guard nextModel != selectedModel else { return }
        let previousModel = selectedModel

        if let obsoleteModel = warmupOwnership.takeBackgroundWarmup(
            whenSwitchingFrom: previousModel
        ) {
            cancelAndTeardownModel(obsoleteModel)
        } else if !warmupOwnership.hasForegroundUse(on: previousModel.runtime) {
            cancelAndTeardownModel(previousModel)
        }
        selectedModel = nextModel
        refreshModelDownloadState()
        scheduleSelectedModelWarmup()
    }

    private func cancelAndTeardownModel(_ model: TranscriptionModelChoice) {
        switch model {
        case .parakeetTDTv2, .parakeetTDTv3, .parakeetUltraExperimental:
            parakeetEngine.cancelModelWork()
            parakeetEngine.teardownModel()
        case .whisperLargeV3Turbo, .whisperLargeV3:
            whisperEngine.cleanup()
        case .appleSpeech:
            appleSpeechEngine.cleanup()
        }
    }

    func initializeRecordingModel() async {
        await initialize(model: recordingModel)
    }

    func initializeSelectedModelInBackground() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        let model = selectedModel
        guard !isModelLoaded(for: model) else {
            refreshModelDownloadState()
            return
        }

        // Joining the same model is safe. A different model sharing the runtime
        // (Parakeet or Whisper variants) must wait until active foreground use ends.
        if warmupOwnership.hasForegroundUse(on: model.runtime) {
            if warmupOwnership.hasForegroundUse(of: model) {
                await initializeModel(model)
            }
            return
        }

        guard let lease = warmupOwnership.beginBackgroundWarmup(for: model) else { return }
        await initializeModel(model)
        warmupOwnership.finishBackgroundWarmup(
            lease,
            modelIsLoaded: isModelLoaded(for: model)
        )
    }

    func prefetchSelectedModelFilesForExistingInstall() async {
        guard let variant = selectedModel.parakeetVariant else { return }
        guard !warmupOwnership.hasForegroundUse(on: .parakeet) else { return }
        await parakeetEngine.prefetchModelFilesIfNeeded(variant: variant)
        refreshModelDownloadState()
    }

    @discardableResult
    func initialize(model: TranscriptionModelChoice) async -> TranscriptionModelChoice {
        guard !isShuttingDown else { return model }
        let resolvedModel = beginForegroundUse(of: model)
        defer { endForegroundUse(of: resolvedModel) }
        await initializeModel(resolvedModel)
        return resolvedModel
    }

    func initializeRetainedModel(_ model: TranscriptionModelChoice) async {
        guard !isShuttingDown else { return }
        await initializeModel(model)
    }

    @discardableResult
    func retainModelForForegroundUse(
        _ model: TranscriptionModelChoice
    ) -> TranscriptionModelChoice {
        beginForegroundUse(of: model)
    }

    func releaseModelFromForegroundUse(_ model: TranscriptionModelChoice) {
        endForegroundUse(of: model)
    }

    private func beginForegroundUse(
        of model: TranscriptionModelChoice
    ) -> TranscriptionModelChoice {
        let claim = warmupOwnership.claimForegroundUse(of: model)
        if let obsoleteModel = claim.obsoleteBackgroundModel {
            cancelAndTeardownModel(obsoleteModel)
        }
        return claim.model
    }

    private func endForegroundUse(of model: TranscriptionModelChoice) {
        guard warmupOwnership.releaseForegroundUse(of: model) else { return }

        if model != selectedModel {
            cancelAndTeardownModel(model)
        }
        if !isModelLoaded(for: selectedModel) {
            scheduleSelectedModelWarmup()
        }
    }

    private func setActiveRecordingModel(_ model: TranscriptionModelChoice) {
        let resolvedModel = beginForegroundUse(of: model)
        if let variant = resolvedModel.parakeetVariant {
            // Cached-model fast start may beat its async warmup task. Select
            // the leased variant before isRecording protects that identity.
            parakeetEngine.prepareModelVariantForRecording(variant)
        }
        let replacement = recordingModelOwnership.replace(with: resolvedModel)
        if let replacedModel = replacement.replacedModel {
            endForegroundUse(of: replacedModel)
        }
    }

    private func clearActiveRecordingModel(
        ifMatching lease: TranscriptionRecordingModelLease? = nil
    ) {
        let model: TranscriptionModelChoice?
        if let lease {
            model = recordingModelOwnership.release(ifMatching: lease)
        } else {
            model = recordingModelOwnership.takeActiveModel()
        }
        guard let model else { return }
        endForegroundUse(of: model)
    }

    private func scheduleSelectedModelWarmup() {
        guard !isShuttingDown else { return }
        let generation = backgroundWarmupGeneration.begin()
        backgroundWarmupTask?.cancel()
        backgroundWarmupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
            await self.initializeSelectedModelInBackground()
            guard self.backgroundWarmupGeneration.finishIfCurrent(generation) else { return }
            self.backgroundWarmupTask = nil
        }
    }

    private func initializeModel(_ model: TranscriptionModelChoice) async {
        guard !isModelLoaded(for: model) else {
            refreshModelDownloadState()
            return
        }

        switch model {
        case .parakeetTDTv2:
            await parakeetEngine.initialize(variant: .v2)
        case .parakeetTDTv3:
            await parakeetEngine.initialize(variant: .v3)
        case .parakeetUltraExperimental:
            await parakeetEngine.initialize(variant: .ultra)
        case .whisperLargeV3Turbo, .whisperLargeV3:
            await whisperEngine.initialize(model: model)
        case .appleSpeech:
            await appleSpeechEngine.initialize()
        }
        refreshModelDownloadState()
    }

    /// Starts the shared, deduplicated load without tying a UI waiter's deadline
    /// or cancellation to the model's lifetime.
    func requestRecordingModelInitialization() {
        let model = recordingModel
        Task { @MainActor [weak self] in
            await self?.initialize(model: model)
        }
    }

    /// Wait for a state transition, caller cancellation, or the caller's deadline.
    /// Ready models return immediately; a stalled native load cannot strand the UI.
    func waitForRecordingModelLoadProgress(until deadline: TimeInterval) async {
        guard !isRecordingModelLoaded, !Task.isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else { return }
        let changes: AnyPublisher<Void, Never>
        switch recordingModel.runtime {
        case .parakeet:
            changes = parakeetEngine.$modelDownloadState.dropFirst().map { _ in () }.eraseToAnyPublisher()
        case .appleSpeech:
            changes = appleSpeechEngine.$modelDownloadState.dropFirst().map { _ in () }.eraseToAnyPublisher()
        case .whisper:
            changes = whisperEngine.$modelDownloadState.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        await ModelLoadProgressWaiter.wait(for: changes, until: deadline)
        refreshModelDownloadState()
    }

    func startRecording() async -> Bool {
        setActiveRecordingModel(selectedModel)
        // A take that never reached transcription must not be scored as this one.
        parakeetEngine.pendingPinnedSpeedPathTake = nil
        return await parakeetEngine.startRecording()
    }

    func startRecordingRecoveryAttempt() async -> Bool {
        setActiveRecordingModel(selectedModel)
        return await parakeetEngine.startRecording(isRecoveryAttempt: true)
    }

    func startRecordingFromSharedMeetingMic(claim: SharedMeetingMicClaim) -> Bool {
        setActiveRecordingModel(selectedModel)
        parakeetEngine.pendingPinnedSpeedPathTake = nil
        return parakeetEngine.startSharedMeetingMicRecording(claim: claim)
    }

    func resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded() async {
        await parakeetEngine.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded()
    }

    func refreshInputReadiness() async {
        await parakeetEngine.prewarm()
    }

    func forceInputReadinessRecovery(reason: String) async {
        await parakeetEngine.forceInputReadinessRecovery(reason: reason)
    }

    func stopRecording() async {
        await parakeetEngine.stopRecording()
    }

    func snapshotRecordedSamplesForPersistence() async -> RecordedSpeechSamples? {
        await parakeetEngine.snapshotRecordedSamplesForPersistence()
    }

    func resetAfterFailedRecordingStart() async {
        clearActiveRecordingModel()
        await parakeetEngine.resetAfterFailedRecordingStart()
    }

    func abandonBlockedRecordingStart(reason: String) {
        clearActiveRecordingModel()
        parakeetEngine.abandonBlockedRecordingStart(reason: reason)
    }

    func transcribe(preparedRecording: RecordedSpeechSamples? = nil) async -> String? {
        let model = recordingModelOwnership.activeLease?.model ?? selectedModel
        heldBackDictationText = nil
        let text = await transcribeWithRecordingModel(preparedRecording: preparedRecording)
        // Words (even held back ones) or an empty take score the pinned
        // recorder's speed-only use of this mic.
        defer {
            parakeetEngine.scorePendingPinnedSpeedPathTake(text: text, emptyReason: lastEmptyTranscriptionReason)
        }
        // The policy reads the person's languages (a Carbon keyboard lookup)
        // only when the text is nearly all one non-Latin script.
        guard let text, !Task.isCancelled,
              let script = DictationLanguageScriptPolicy.unexpectedScript(
                  in: text,
                  userLanguageCodes: { DictationUserLanguages.current() }
              ) else { return text }
        // A multilingual model probably guessed a language this person doesn't
        // use (Russian for an English speaker). Don't paste it unasked; the
        // message offers Paste Anyway in case the text is right.
        heldBackDictationText = text
        lastEmptyTranscriptionReason = .otherLanguage
        EventReporter.shared.capture(
            level: .warning,
            engine: "dictation",
            event: "dictation_output_language_mismatch",
            message: "Dictation text was in a writing system none of the Mac's languages use",
            context: ["model": model.rawValue, "script": script.rawValue]
        )
        return nil
    }

    private func transcribeWithRecordingModel(preparedRecording: RecordedSpeechSamples?) async -> String? {
        let recordingLease = recordingModelOwnership.activeLease
        let model = recordingLease?.model ?? selectedModel
        lastEmptyTranscriptionReason = nil
        defer {
            if let recordingLease {
                clearActiveRecordingModel(ifMatching: recordingLease)
            }
        }

        switch model {
        case .parakeetTDTv2, .parakeetTDTv3, .parakeetUltraExperimental:
            guard isModelLoaded(for: model) else {
                lastEmptyTranscriptionReason = .modelFailure
                EventReporter.shared.capture(
                    level: .error,
                    engine: "parakeet",
                    event: "asr_manager_unavailable",
                    message: "Requested Parakeet model is not available for transcription",
                    context: ["model": model.rawValue]
                )
                return nil
            }
            let text = await parakeetEngine.transcribe(preparedRecording: preparedRecording)
            if !Task.isCancelled {
                lastEmptyTranscriptionReason = text == nil ? parakeetEngine.lastEmptyTranscriptionReason : nil
            }
            return text
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return await transcribeUsingExternalEngine(
                model: model,
                preparedRecording: preparedRecording
            ) { [self] recording in
                try await whisperEngine.transcribeSamples(
                    recording.samples16k,
                    source: .microphone,
                    model: model
                )
            }
        case .appleSpeech:
            // Dictation has no language setting; Apple Speech uses the Mac's language.
            return await transcribeUsingExternalEngine(
                model: model,
                preparedRecording: preparedRecording
            ) { [self] recording in
                try await appleSpeechEngine.transcribeSamples(
                    recording.samples16k,
                    source: .microphone,
                    languageCode: nil
                )
            }
        }
    }

    /// Shared drain/transcribe/report flow for the non-Parakeet dictation
    /// engines (Whisper, Apple Speech), which transcribe already-recorded Parakeet samples
    /// rather than owning the audio graph themselves.
    private func transcribeUsingExternalEngine(
        model: TranscriptionModelChoice,
        preparedRecording: RecordedSpeechSamples?,
        transcribe: (RecordedSpeechSamples) async throws -> String
    ) async -> String? {
        await initialize(model: model)
        guard !Task.isCancelled else { return nil }
        guard isModelLoaded(for: model) else {
            lastEmptyTranscriptionReason = .modelFailure
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "dictation_model_unavailable",
                message: "\(model.title) was selected but is not loaded",
                context: ["model": model.rawValue]
            )
            return nil
        }

        guard let recording = await parakeetEngine.drainRecordedSamplesForExternalTranscription(
            engineName: model.engineName,
            preparedRecording: preparedRecording
        ) else {
            if !Task.isCancelled { lastEmptyTranscriptionReason = parakeetEngine.lastEmptyTranscriptionReason }
            return nil
        }

        guard let transcriptionOwner = parakeetEngine.currentRecordedTranscriptionLease else { return nil }
        let consumedRevision = parakeetEngine.currentRecordedSamplesRevision
        return await ExternalEngineTranscription.run(
            lease: transcriptionOwner,
            release: { lease in
                parakeetEngine.finishExternalTranscription(
                    ownedBy: lease,
                    expectedRevision: consumedRevision
                )
            },
            model: {
                let text = try await transcribe(recording)
                try Task.checkCancellation()
                return text
            },
            accept: { text in
                guard parakeetEngine.ownsRecordedTranscription(
                    transcriptionOwner,
                    expectedRevision: consumedRevision
                ) else { return nil }
                if let emptyReason = DictationEmptyInferencePolicy.externalEngineEmptyReason(
                    text: text,
                    samples16k: recording.samples16k
                ) {
                    lastEmptyTranscriptionReason = emptyReason
                    return nil
                }
                return text
            },
            classify: { error in
                guard let failureReason = DictationEmptyInferencePolicy.externalEngineFailureReason(
                    for: error,
                    taskCancelled: Task.isCancelled
                ) else { return }
                guard parakeetEngine.ownsRecordedTranscription(
                    transcriptionOwner,
                    expectedRevision: consumedRevision
                ) else { return }
                lastEmptyTranscriptionReason = failureReason
                EventReporter.shared.capture(
                    level: .error,
                    engine: model.engineName,
                    event: "dictation_transcription_failed",
                    message: error.localizedDescription,
                    context: ["model": model.rawValue]
                )
            }
        )
    }

    /// Transcribe again: 16 kHz mono samples decoded from a saved dictation
    /// file. Uses the dictation model and the live take's language context
    /// (none: dictation follows the model's own detection, like
    /// `transcribe(preparedRecording:)`). Never opens an input device. While
    /// it runs `isTranscribing` is true, so a new dictation press queues
    /// behind it the way it queues behind a finishing take, and saved-audio
    /// re-transcription stays unavailable. One at a time.
    func transcribeSavedDictation(samples: [Float]) async throws -> String {
        guard !isTranscribingSavedDictation, !isRecording, !isTranscribing else {
            throw NSError(domain: "STTRouter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Transcription is busy",
            ])
        }
        isTranscribingSavedDictation = true
        defer { isTranscribingSavedDictation = false }
        return try await transcribeSegment(
            samples: samples,
            source: .microphone,
            model: selectedModel,
            language: nil
        )
    }

    func transcribeSegment(
        samples: [Float],
        source: AudioSource,
        model: TranscriptionModelChoice? = nil,
        language: TranscriptionLanguageContext? = nil
    ) async throws -> String {
        let resolvedModel = beginForegroundUse(of: model ?? selectedModel)
        defer { endForegroundUse(of: resolvedModel) }
        // The meeting pipeline calls this once per diarized segment (hundreds
        // of times for a long recording). Models are loaded once before the
        // pipeline starts (Transcription.ensureModelsReadyForPipeline via
        // MeetingSTTAdapter.prepare), so skip the per-segment initialize
        // round-trip when the engine is already ready; keep it as a safety
        // net for cold callers.
        if !isModelLoaded(for: resolvedModel) {
            await initializeModel(resolvedModel)
        }

        switch resolvedModel {
        case .parakeetTDTv2, .parakeetTDTv3, .parakeetUltraExperimental:
            if let language, case .explicit = language.selection {
                throw TranscriptionLanguageModelErrors.savedLanguageNeedsLanguageModel()
            }
            guard isModelLoaded(for: resolvedModel) else {
                throw NSError(domain: "STTRouter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(resolvedModel.title) is not loaded"
                ])
            }
            return try await parakeetEngine.transcribeSamples(samples, source: source)
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return try await whisperEngine.transcribeSamples(
                samples,
                source: source,
                model: resolvedModel,
                languageCode: language?.languageCode
            )
        case .appleSpeech:
            return try await appleSpeechEngine.transcribeSamples(
                samples,
                source: source,
                languageCode: language?.languageCode
            )
        }
    }

    /// Batch limit for meeting segments, or nil when `model` transcribes them
    /// one call each. Parakeet packs a batch into its fixed 15 s window; one
    /// encoder frame (80 ms) of headroom keeps a pack inside it. Whisper
    /// decodes a batch's segments side by side instead, so its limit is one
    /// 30 s window per worker.
    func packedSegmentWindowSamples(for model: TranscriptionModelChoice) -> Int? {
        switch model {
        case .parakeetTDTv2, .parakeetTDTv3:
            return ASRConstants.maxModelSamples - ASRConstants.samplesPerEncoderFrame
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return Self.whisperWindowSamples * WhisperEngine.meetingBatchWorkerCount
        case .parakeetUltraExperimental, .appleSpeech:
            return nil
        }
    }

    /// Whisper's fixed input window: 30 s at 16 kHz.
    private static let whisperWindowSamples = 480_000

    /// Transcribes a batch of meeting segments side by side with Whisper, one
    /// text per segment; nil when `model` isn't Whisper (the caller falls back).
    func transcribeWhisperMeetingSegments(
        _ segments: [[Float]],
        source: AudioSource,
        model: TranscriptionModelChoice,
        language: TranscriptionLanguageContext?
    ) async throws -> [String]? {
        let resolvedModel = beginForegroundUse(of: model)
        defer { endForegroundUse(of: resolvedModel) }
        guard resolvedModel.isWhisper else { return nil }
        return try await whisperEngine.transcribeMeetingSegments(
            segments,
            source: source,
            model: resolvedModel,
            languageCode: language?.languageCode
        )
    }

    /// One call over packed meeting segments, returning timed tokens; nil
    /// when this model or language can't pack (the caller falls back).
    func transcribePackedTokens(
        samples: [Float],
        model: TranscriptionModelChoice,
        language: TranscriptionLanguageContext?
    ) async throws -> [TimedTranscriptToken]? {
        let resolvedModel = beginForegroundUse(of: model)
        defer { endForegroundUse(of: resolvedModel) }
        // Whisper batches go through `transcribeWhisperMeetingSegments`;
        // only Parakeet can split one packed call back into segments.
        guard resolvedModel.parakeetVariant != nil,
              packedSegmentWindowSamples(for: resolvedModel) != nil else { return nil }
        if let language, case .explicit = language.selection { return nil }
        if !isModelLoaded(for: resolvedModel) {
            await initializeModel(resolvedModel)
        }
        guard isModelLoaded(for: resolvedModel) else { return nil }
        return try await parakeetEngine.transcribePackedSamplesWithTokenTimes(samples)
    }

    func resolveLanguage(
        representativeSamples: [[Float]],
        selection: TranscriptionLanguageSelection,
        model: TranscriptionModelChoice
    ) async throws -> TranscriptionLanguageContext {
        let resolvedModel = beginForegroundUse(of: model)
        defer { endForegroundUse(of: resolvedModel) }
        try Task.checkCancellation()
        if resolvedModel.isAppleSpeech {
            do {
                return try await appleSpeechEngine.resolveLanguage(selection: selection)
            } catch AppleSpeechEngineError.unsupportedLanguage(let languageName) {
                // Auto saved no language (it failed on the Mac's), so it
                // rethrows the engine error, which gets the pipeline's generic
                // copy; setup usually fails first there.
                guard let settingsFix = TranscriptionLanguageModelErrors.appleSpeechUnsupportedLanguage(
                    languageName: languageName,
                    isExplicitSelection: selection != .automatic
                ) else { throw AppleSpeechEngineError.unsupportedLanguage(languageName) }
                throw settingsFix
            }
        }
        guard resolvedModel.isWhisper else {
            if case .explicit = selection { throw TranscriptionLanguageModelErrors.savedLanguageNeedsLanguageModel() }
            // Parakeet's native multilingual decoder remains automatic. Its
            // optional Language API only filters scripts, not spoken languages.
            return TranscriptionLanguageContext(selection: selection, languageCode: nil, resolution: .unsupported)
        }
        return try await whisperEngine.resolveLanguage(
            representativeSamples: representativeSamples,
            selection: selection,
            model: resolvedModel
        )
    }

    func cancel() {
        clearActiveRecordingModel()
        parakeetEngine.cancel()
    }

    func finishRecordingModelUse(_ lease: TranscriptionRecordingModelLease?) {
        guard let lease else { return }
        clearActiveRecordingModel(ifMatching: lease)
    }

    /// Settings calls this when the Meeting language changes, so Apple Speech
    /// downloads the new language now (with progress shown there) instead of
    /// silently inside the next meeting's transcription.
    func prefetchAppleSpeechMeetingLanguage() {
        guard selectedModel.isAppleSpeech else { return }
        appleSpeechEngine.prefetchSavedMeetingLanguage()
    }

    func cleanup() {
        isShuttingDown = true
        backgroundWarmupGeneration.invalidate()
        backgroundWarmupTask?.cancel()
        backgroundWarmupTask = nil
        warmupOwnership.reset()
        recordingModelOwnership.reset()
        parakeetEngine.cleanup()
        whisperEngine.cleanup()
        appleSpeechEngine.cleanup()
    }

    private func refreshModelDownloadState(publishedState: ParakeetModelState? = nil) {
        let refreshed = publishedState ?? modelDownloadState(for: selectedModel)
        // Skip the redundant @Published reassignment when nothing changed.
        // Background meeting transcription refreshes this state repeatedly
        // (per segment / per wait tick), and every reassignment fires
        // objectWillChange into the menubar, warmup-status, and settings
        // subscribers even when the value is identical — thousands of
        // pointless main-actor invalidations across a long meeting.
        guard refreshed != modelDownloadState else { return }
        modelDownloadState = refreshed
    }

    private func modelDownloadState(
        for model: TranscriptionModelChoice
    ) -> ParakeetModelState {
        switch model {
        case .parakeetTDTv2:
            return parakeetEngine.modelDownloadState(for: .v2)
        case .parakeetTDTv3:
            return parakeetEngine.modelDownloadState(for: .v3)
        case .parakeetUltraExperimental:
            return parakeetEngine.modelDownloadState(for: .ultra)
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return whisperEngine.modelDownloadState
        case .appleSpeech:
            return appleSpeechEngine.modelDownloadState
        }
    }

}
