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
        preparedModel = model
        await router.initialize(model: model)
    }

    func selectPreparedModel(_ model: TranscriptionModelChoice) {
        preparedModel = model
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        let model = preparedModel ?? router.selectedModel
        return try await router.transcribeSegment(samples: samples, source: source, model: model)
    }

    func cleanup() {
        preparedModel = nil
    }
}
