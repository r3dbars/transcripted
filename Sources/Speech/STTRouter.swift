// STTRouter.swift
// Shared STT router for dictation, meetings, and imported audio.

import Combine
import FluidAudio
import SwiftUI

@MainActor
class STTRouter: ObservableObject {
    let parakeetEngine = ParakeetEngine()
    private let whisperEngine = WhisperEngine()

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

        NotificationCenter.default.publisher(for: .transcriptionModelPreferenceDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.selectedModel = TranscriptionModelPreferences.effectiveModel()
                self.refreshModelDownloadState()
                Task { @MainActor [weak self] in
                    await self?.initializeSelectedModel()
                }
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
        }
    }

    func cancel() {
        activeRecordingModel = nil
        parakeetEngine.cancel()
    }

    func cleanup() {
        parakeetEngine.cleanup()
        whisperEngine.cleanup()
    }

    private func refreshModelDownloadState() {
        switch selectedModel {
        case .parakeetTDTv3:
            modelDownloadState = parakeetEngine.modelDownloadState
        case .whisperLargeV3Turbo, .whisperLargeV3:
            modelDownloadState = whisperEngine.modelDownloadState
        }
    }
}
