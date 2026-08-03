// STTRouter.swift
// Shared STT router for dictation, meetings, and imported audio.

import Combine
import FluidAudio
import Foundation

@MainActor
class STTRouter: ObservableObject {
    let parakeetEngine = ParakeetEngine()
    private let whisperEngine = WhisperEngine()
    private let nemotronEngine = NemotronEngine()

    @Published private(set) var selectedModel = TranscriptionModelPreferences.effectiveModel()
    @Published private(set) var modelDownloadState: ParakeetModelState = .notLoaded
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true
    private(set) var lastEmptyTranscriptionReason: DictationEmptyTranscriptionReason?

    private var cancellables: Set<AnyCancellable> = []
    private var recordingModelOwnership = TranscriptionRecordingModelOwnership()
    private var warmupOwnership = TranscriptionModelWarmupOwnership()
    private var backgroundWarmupTask: Task<Void, Never>?
    private var backgroundWarmupGeneration: UInt64 = 0
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

    /// True when the selected model's files are already on disk, so dictation
    /// can open the microphone immediately and load the model concurrently
    /// instead of blocking recording on the load.
    var selectedModelFilesAvailableLocally: Bool {
        switch selectedModel {
        case .parakeetTDTv3:
            return parakeetEngine.modelFilesAvailableLocally
        case .whisperLargeV3Turbo, .whisperLargeV3:
            // Whisper does not expose a files-on-disk signal; keep the
            // conservative wait-for-load start path.
            return false
        case .nemotronStreaming:
            // Beta streaming engine; no files-on-disk signal either, so it
            // also keeps the conservative wait-for-load start path.
            return false
        }
    }

    var inputDeviceName: String { parakeetEngine.inputDeviceName }
    var isRecordingFromSharedMeetingMic: Bool { parakeetEngine.isRecordingFromSharedMeetingMic }
    var hasRecoverableRecording: Bool { parakeetEngine.hasRecoverableRecording }
    var dictationAudioRouteAnalyticsContext: [String: String] {
        parakeetEngine.currentAudioRouteAnalyticsContext
    }

    init() {
        parakeetEngine.$isRecording.assign(to: &$isRecording)
        parakeetEngine.$isTranscribing.assign(to: &$isTranscribing)
        parakeetEngine.$audioLevel.assign(to: &$audioLevel)
        parakeetEngine.$recordingInterrupted.assign(to: &$recordingInterrupted)
        parakeetEngine.$isRecovering.assign(to: &$isRecovering)
        parakeetEngine.$inputFormatReady.assign(to: &$inputFormatReady)

        parakeetEngine.$modelDownloadState
            .sink { [weak self] _ in
                self?.refreshModelDownloadState()
            }
            .store(in: &cancellables)

        whisperEngine.$modelDownloadState
            .sink { [weak self] _ in
                self?.refreshModelDownloadState()
            }
            .store(in: &cancellables)

        nemotronEngine.$modelDownloadState
            .sink { [weak self] _ in
                self?.refreshModelDownloadState()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .transcriptionModelPreferenceDidChange)
            .sink { [weak self] _ in
                self?.handleModelSelectionChange()
            }
            .store(in: &cancellables)

        // The Nemotron beta gate feeds effectiveModel(): turning the beta off
        // while Nemotron is selected must self-heal back to the default model.
        NotificationCenter.default.publisher(for: .speechModelBetaPreferencesDidChange)
            .sink { [weak self] _ in
                self?.handleModelSelectionChange()
            }
            .store(in: &cancellables)

        refreshModelDownloadState()
    }

    func isModelLoaded(for model: TranscriptionModelChoice) -> Bool {
        switch model {
        case .parakeetTDTv3:
            return parakeetEngine.isModelLoaded
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return whisperEngine.isModelLoaded(for: model)
        case .nemotronStreaming:
            return nemotronEngine.isModelLoaded
        }
    }

    private func handleModelSelectionChange() {
        let nextModel = TranscriptionModelPreferences.effectiveModel()
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
        case .parakeetTDTv3:
            parakeetEngine.cancelModelWork()
            parakeetEngine.teardownModel()
        case .whisperLargeV3Turbo, .whisperLargeV3:
            whisperEngine.cleanup()
        case .nemotronStreaming:
            nemotronEngine.cleanup()
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
        // (the two Whisper variants) must wait until active foreground use ends.
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
        guard selectedModel == .parakeetTDTv3 else { return }
        await parakeetEngine.prefetchModelFilesIfNeeded()
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
        backgroundWarmupGeneration &+= 1
        let generation = backgroundWarmupGeneration
        backgroundWarmupTask?.cancel()
        backgroundWarmupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
            await self.initializeSelectedModelInBackground()
            guard generation == self.backgroundWarmupGeneration else { return }
            self.backgroundWarmupTask = nil
        }
    }

    private func initializeModel(_ model: TranscriptionModelChoice) async {
        guard !isModelLoaded(for: model) else {
            refreshModelDownloadState()
            return
        }

        switch model {
        case .parakeetTDTv3:
            await parakeetEngine.initialize()
        case .whisperLargeV3Turbo, .whisperLargeV3:
            await whisperEngine.initialize(model: model)
        case .nemotronStreaming:
            await nemotronEngine.initialize()
        }
        refreshModelDownloadState()
    }

    /// Wait for the next observable model-load transition. Joins the engine's
    /// in-flight initialization when one exists — resuming the moment the load
    /// settles instead of on a polling interval — and falls back to a short
    /// poll sleep while a download is publishing progress or no
    /// initialization handle exists (Whisper). Callers own the overall
    /// timeout and must re-check `isModelLoaded` after each wait.
    func waitForRecordingModelLoadProgress() async {
        let model = recordingModel
        defer { refreshModelDownloadState() }
        if model == .parakeetTDTv3 {
            var isDownloading = false
            if case .downloading = recordingModelDownloadState { isDownloading = true }
            if !isDownloading, await parakeetEngine.joinModelInitialization() {
                return
            }
        }
        try? await Task.sleep(nanoseconds: TranscriptedConstants.modelLoadPollInterval)
    }

    func startRecording() async -> Bool {
        setActiveRecordingModel(selectedModel)
        return await parakeetEngine.startRecording()
    }

    func startRecordingRecoveryAttempt() async -> Bool {
        setActiveRecordingModel(selectedModel)
        return await parakeetEngine.startRecording(isRecoveryAttempt: true)
    }

    func startRecordingFromSharedMeetingMic() -> Bool {
        setActiveRecordingModel(selectedModel)
        return parakeetEngine.startSharedMeetingMicRecording()
    }

    func resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded() async {
        await parakeetEngine.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded()
    }

    func updateSharedMeetingMicAudioLevel(_ level: Float) {
        parakeetEngine.updateSharedMeetingMicAudioLevel(level)
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
        let recordingLease = recordingModelOwnership.activeLease
        let model = recordingLease?.model ?? selectedModel
        lastEmptyTranscriptionReason = nil
        defer {
            if let recordingLease {
                clearActiveRecordingModel(ifMatching: recordingLease)
            }
        }

        switch model {
        case .parakeetTDTv3:
            let text = await parakeetEngine.transcribe(preparedRecording: preparedRecording)
            lastEmptyTranscriptionReason = text == nil ? parakeetEngine.lastEmptyTranscriptionReason : nil
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
        case .nemotronStreaming:
            return await transcribeUsingExternalEngine(
                model: model,
                preparedRecording: preparedRecording
            ) { [self] recording in
                try await nemotronEngine.transcribeSamples(
                    recording.samples16k,
                    source: .microphone
                )
            }
        }
    }

    /// Shared drain/transcribe/report flow for the non-Parakeet dictation
    /// engines (Whisper, Nemotron), which both transcribe already-recorded
    /// Parakeet samples rather than owning the audio graph themselves.
    private func transcribeUsingExternalEngine(
        model: TranscriptionModelChoice,
        preparedRecording: RecordedSpeechSamples?,
        transcribe: (RecordedSpeechSamples) async throws -> String
    ) async -> String? {
        await initialize(model: model)
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
            lastEmptyTranscriptionReason = parakeetEngine.lastEmptyTranscriptionReason
            return nil
        }

        do {
            defer {
                parakeetEngine.finishExternalTranscription()
            }
            let text = try await transcribe(recording)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lastEmptyTranscriptionReason = .noSpeech
                return nil
            }
            return text
        } catch {
            lastEmptyTranscriptionReason = .modelFailure
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "dictation_transcription_failed",
                message: error.localizedDescription,
                context: ["model": model.rawValue]
            )
            return nil
        }
    }

    func transcribeSegment(
        samples: [Float],
        source: AudioSource,
        model: TranscriptionModelChoice? = nil
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
        case .parakeetTDTv3:
            return try await parakeetEngine.transcribeSamples(samples, source: source)
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return try await whisperEngine.transcribeSamples(
                samples,
                source: source,
                model: resolvedModel
            )
        case .nemotronStreaming:
            return try await nemotronEngine.transcribeSamples(samples, source: source)
        }
    }

    func cancel() {
        clearActiveRecordingModel()
        parakeetEngine.cancel()
    }

    func finishRecordingModelUse(_ lease: TranscriptionRecordingModelLease?) {
        guard let lease else { return }
        clearActiveRecordingModel(ifMatching: lease)
    }

    func cleanup() {
        isShuttingDown = true
        backgroundWarmupGeneration &+= 1
        backgroundWarmupTask?.cancel()
        backgroundWarmupTask = nil
        warmupOwnership.reset()
        recordingModelOwnership.reset()
        parakeetEngine.cleanup()
        whisperEngine.cleanup()
        nemotronEngine.cleanup()
    }

    private func refreshModelDownloadState() {
        let refreshed = modelDownloadState(for: selectedModel)
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
        case .parakeetTDTv3:
            return parakeetEngine.modelDownloadState
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return whisperEngine.modelDownloadState
        case .nemotronStreaming:
            return nemotronEngine.modelDownloadState
        }
    }

}
