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
    @Published var liveTranscript: String = ""
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true

    private var cancellables: Set<AnyCancellable> = []
    private var activeRecordingModel: TranscriptionModelChoice?

    var isModelLoaded: Bool {
        isModelLoaded(for: selectedModel)
    }

    var inputDeviceName: String { parakeetEngine.inputDeviceName }
    var dictationAudioRouteAnalyticsContext: [String: String] {
        parakeetEngine.currentAudioRouteAnalyticsContext
    }

    init() {
        parakeetEngine.$isRecording.assign(to: &$isRecording)
        parakeetEngine.$isTranscribing.assign(to: &$isTranscribing)
        parakeetEngine.$audioLevel.assign(to: &$audioLevel)
        parakeetEngine.$liveTranscript.assign(to: &$liveTranscript)
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
        selectedModel = TranscriptionModelPreferences.effectiveModel()
        refreshModelDownloadState()
        Task { @MainActor [weak self] in
            await self?.initializeSelectedModel()
        }
    }

    func initializeSelectedModel() async {
        await initialize(model: selectedModel)
    }

    func prefetchSelectedModelFilesForExistingInstall() async {
        guard selectedModel == .parakeetTDTv3 else { return }
        await parakeetEngine.prefetchModelFilesIfNeeded()
        refreshModelDownloadState()
    }

    func initialize(model: TranscriptionModelChoice) async {
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

    func startRecording() async -> Bool {
        activeRecordingModel = selectedModel
        return await parakeetEngine.startRecording()
    }

    func startRecordingRecoveryAttempt() async -> Bool {
        activeRecordingModel = selectedModel
        return await parakeetEngine.startRecording(isRecoveryAttempt: true)
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

    func resetAfterFailedRecordingStart() async {
        activeRecordingModel = nil
        await parakeetEngine.resetAfterFailedRecordingStart()
    }

    func abandonBlockedRecordingStart(reason: String) {
        activeRecordingModel = nil
        parakeetEngine.abandonBlockedRecordingStart(reason: reason)
    }

    func transcribe() async -> String? {
        let model = activeRecordingModel ?? selectedModel
        defer {
            activeRecordingModel = nil
        }

        switch model {
        case .parakeetTDTv3:
            return await parakeetEngine.transcribe()
        case .whisperLargeV3Turbo, .whisperLargeV3:
            await initialize(model: model)
            guard isModelLoaded(for: model) else {
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
                engineName: model.engineName
            ) else {
                return nil
            }

            do {
                defer {
                    parakeetEngine.finishExternalTranscription()
                }
                let text = try await whisperEngine.transcribeSamples(
                    recording.samples16k,
                    source: .microphone,
                    model: model
                )
                return text.isEmpty ? nil : text
            } catch {
                print("❌ WHISPER | dictation failed: \(error.localizedDescription)")
                return nil
            }
        case .nemotronStreaming:
            await initialize(model: model)
            guard isModelLoaded(for: model) else {
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
                engineName: model.engineName
            ) else {
                return nil
            }

            do {
                defer {
                    parakeetEngine.finishExternalTranscription()
                }
                let text = try await nemotronEngine.transcribeSamples(
                    recording.samples16k,
                    source: .microphone
                )
                return text.isEmpty ? nil : text
            } catch {
                print("❌ NEMOTRON | dictation failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    func transcribeSegment(
        samples: [Float],
        source: AudioSource,
        model: TranscriptionModelChoice? = nil
    ) async throws -> String {
        let resolvedModel = model ?? selectedModel
        await initialize(model: resolvedModel)

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
        activeRecordingModel = nil
        parakeetEngine.cancel()
    }

    func cleanup() {
        parakeetEngine.cleanup()
        whisperEngine.cleanup()
        nemotronEngine.cleanup()
    }

    private func refreshModelDownloadState() {
        switch selectedModel {
        case .parakeetTDTv3:
            modelDownloadState = parakeetEngine.modelDownloadState
        case .whisperLargeV3Turbo, .whisperLargeV3:
            modelDownloadState = whisperEngine.modelDownloadState
        case .nemotronStreaming:
            modelDownloadState = nemotronEngine.modelDownloadState
        }
    }
}
