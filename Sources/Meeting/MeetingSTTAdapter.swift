// MeetingSTTAdapter.swift
// Adapts the app-owned STTRouter to TranscriptedCore's SpeechToTextEngine.

import Combine
import FluidAudio
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingSTTAdapter: ObservableObject, SpeechToTextEngine {

    private let router: STTRouter
    private var preparedModel: TranscriptionModelChoice?
    private var activeJobModel: TranscriptionModelChoice?

    init(router: STTRouter) {
        self.router = router
    }

    // MARK: - SpeechToTextEngine

    var isReady: Bool {
        router.isModelLoaded(for: preparedModel ?? router.selectedModel)
    }

    var selectedModel: TranscriptionModelChoice {
        router.selectedModel
    }

    var transcriptionEngineDescriptor: SpeechTranscriptionEngineDescriptor {
        let model = preparedModel ?? router.selectedModel
        return SpeechTranscriptionEngineDescriptor(
            identifier: model.transcriptionEngineIdentifier,
            displayName: model.transcriptionEngineDisplayName
        )
    }

    func isReady(for model: TranscriptionModelChoice) -> Bool {
        router.isModelLoaded(for: model)
    }

    func initialize() async {
        await prepare(model: selectedModel)
    }

    func prepare(model: TranscriptionModelChoice) async {
        selectPreparedModel(model)
        preparedModel = await router.initialize(model: model)
    }

    func selectPreparedModel(_ model: TranscriptionModelChoice) {
        guard activeJobModel == nil, preparedModel != model else { return }
        preparedModel = model
    }

    func beginTranscriptionJob() {
        guard activeJobModel == nil else { return }
        let model = preparedModel ?? router.selectedModel
        let resolvedModel = router.retainModelForForegroundUse(model)
        activeJobModel = resolvedModel
        preparedModel = resolvedModel
    }

    func finishTranscriptionJob() {
        guard let activeJobModel else { return }
        self.activeJobModel = nil
        router.releaseModelFromForegroundUse(activeJobModel)
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        let model = activeJobModel ?? preparedModel ?? router.selectedModel
        return try await router.transcribeSegment(samples: samples, source: source, model: model)
    }

    func cleanup() {
        finishTranscriptionJob()
        preparedModel = nil
    }
}
