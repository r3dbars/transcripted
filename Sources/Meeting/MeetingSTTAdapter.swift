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
    private var requestedModel: TranscriptionModelChoice?
    private var preparedModel: TranscriptionModelChoice?
    private var preparedLeaseModel: TranscriptionModelChoice?
    private var activeJobModel: TranscriptionModelChoice?
    private var preparationGeneration = TranscriptionModelPreparationGeneration()

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
        await prepare(model: model, retainForNextJob: false)
    }

    func prepare(
        model: TranscriptionModelChoice,
        retainForNextJob: Bool
    ) async {
        // A queued job's prepared lease wins over disposable background
        // warmup. The queue will transfer or discard it explicitly.
        if preparedLeaseModel != nil, !retainForNextJob {
            return
        }

        selectPreparedModel(model)
        guard activeJobModel == nil, requestedModel == model else { return }

        let generation = preparationGeneration.begin()
        let resolvedModel: TranscriptionModelChoice
        if retainForNextJob {
            resolvedModel = router.retainModelForForegroundUse(model)
            await router.initialize(model: resolvedModel)
        } else {
            resolvedModel = await router.initialize(model: model)
        }

        guard
            !Task.isCancelled,
            preparationGeneration.isCurrent(generation),
            activeJobModel == nil,
            requestedModel == model,
            router.isModelLoaded(for: resolvedModel)
        else {
            if retainForNextJob {
                router.releaseModelFromForegroundUse(resolvedModel)
            }
            return
        }

        releasePreparedLease()
        preparedModel = resolvedModel
        preparedLeaseModel = retainForNextJob ? resolvedModel : nil
    }

    func hasPreparedLease(for requestedModel: TranscriptionModelChoice) -> Bool {
        guard self.requestedModel == requestedModel, let preparedLeaseModel else {
            return false
        }
        return router.isModelLoaded(for: preparedLeaseModel)
    }

    func selectPreparedModel(_ model: TranscriptionModelChoice) {
        guard activeJobModel == nil else { return }
        guard
            requestedModel != model
                || (preparedLeaseModel == nil && preparedModel != model)
        else { return }

        preparationGeneration.invalidate()
        releasePreparedLease()
        requestedModel = model
        preparedModel = model
    }

    func beginTranscriptionJob() {
        guard activeJobModel == nil else { return }
        preparationGeneration.invalidate()

        if let preparedLeaseModel {
            self.preparedLeaseModel = nil
            activeJobModel = preparedLeaseModel
            preparedModel = preparedLeaseModel
            return
        }

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

    func discardPreparedModel() {
        guard activeJobModel == nil else { return }
        preparationGeneration.invalidate()
        releasePreparedLease()
        requestedModel = nil
        preparedModel = nil
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        let model = activeJobModel ?? preparedModel ?? router.selectedModel
        return try await router.transcribeSegment(samples: samples, source: source, model: model)
    }

    func cleanup() {
        finishTranscriptionJob()
        discardPreparedModel()
    }

    private func releasePreparedLease() {
        guard let preparedLeaseModel else { return }
        self.preparedLeaseModel = nil
        router.releaseModelFromForegroundUse(preparedLeaseModel)
    }
}
