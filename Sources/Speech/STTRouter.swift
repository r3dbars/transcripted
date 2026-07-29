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
    private var activeRecordingModel: TranscriptionModelChoice?
    private var warmupOwnership = TranscriptionModelWarmupOwnership()

    var isModelLoaded: Bool {
        isModelLoaded(for: selectedModel)
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

    func initializeSelectedModel() async {
        await initialize(model: selectedModel)
    }

    func initializeSelectedModelInBackground() async {
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

    func initialize(model: TranscriptionModelChoice) async {
        beginForegroundUse(of: model)
        defer { endForegroundUse(of: model) }
        await initializeModel(model)
    }

    func retainModelForForegroundUse(_ model: TranscriptionModelChoice) {
        beginForegroundUse(of: model)
    }

    func releaseModelFromForegroundUse(_ model: TranscriptionModelChoice) {
        endForegroundUse(of: model)
    }

    private func beginForegroundUse(of model: TranscriptionModelChoice) {
        if let obsoleteModel = warmupOwnership.claimForegroundUse(of: model) {
            cancelAndTeardownModel(obsoleteModel)
        }
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
        guard activeRecordingModel != model else { return }
        clearActiveRecordingModel()
        activeRecordingModel = model
        beginForegroundUse(of: model)
    }

    private func clearActiveRecordingModel() {
        guard let model = activeRecordingModel else { return }
        activeRecordingModel = nil
        endForegroundUse(of: model)
    }

    private func scheduleSelectedModelWarmup() {
        Task { @MainActor [weak self] in
            await self?.initializeSelectedModelInBackground()
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
    func waitForModelLoadProgress() async {
        defer { refreshModelDownloadState() }
        if selectedModel == .parakeetTDTv3 {
            var isDownloading = false
            if case .downloading = modelDownloadState { isDownloading = true }
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
        let model = activeRecordingModel ?? selectedModel
        lastEmptyTranscriptionReason = nil
        defer {
            clearActiveRecordingModel()
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
        let resolvedModel = model ?? selectedModel
        beginForegroundUse(of: resolvedModel)
        defer { endForegroundUse(of: resolvedModel) }
        // The meeting pipeline calls this once per diarized segment (hundreds
        // of times for a long recording). Models are loaded once before the
        // pipeline starts (Transcription.ensureModelsReadyForPipeline via
        // MeetingSTTAdapter.prepare), so skip the per-segment initialize
        // round-trip when the engine is already ready; keep it as a safety
        // net for cold callers.
        if !isModelLoaded(for: resolvedModel) {
            await initialize(model: resolvedModel)
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

    func cleanup() {
        warmupOwnership.reset()
        activeRecordingModel = nil
        parakeetEngine.cleanup()
        whisperEngine.cleanup()
        nemotronEngine.cleanup()
    }

    private func refreshModelDownloadState() {
        let refreshed: ParakeetModelState
        switch selectedModel {
        case .parakeetTDTv3:
            refreshed = parakeetEngine.modelDownloadState
        case .whisperLargeV3Turbo, .whisperLargeV3:
            refreshed = whisperEngine.modelDownloadState
        case .nemotronStreaming:
            refreshed = nemotronEngine.modelDownloadState
        }
        // Skip the redundant @Published reassignment when nothing changed.
        // Background meeting transcription refreshes this state repeatedly
        // (per segment / per wait tick), and every reassignment fires
        // objectWillChange into the menubar, warmup-status, and settings
        // subscribers even when the value is identical — thousands of
        // pointless main-actor invalidations across a long meeting.
        guard !Self.modelStatesEqual(refreshed, modelDownloadState) else { return }
        modelDownloadState = refreshed
    }

    /// `ParakeetModelState` is not `Equatable` (it lives with the engine
    /// support types), so compare cases plus associated values manually.
    /// Any pair this switch does not recognize falls through to `false`,
    /// which fails safe by re-publishing.
    private static func modelStatesEqual(
        _ lhs: ParakeetModelState,
        _ rhs: ParakeetModelState
    ) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.cached, .cached),
             (.loading, .loading), (.ready, .ready):
            return true
        case let (.downloading(lhsProgress), .downloading(rhsProgress)):
            return lhsProgress == rhsProgress
        case let (.failed(lhsMessage), .failed(rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}
