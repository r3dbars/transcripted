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
    private var pendingModelOwnership = TranscriptionPendingModelOwnership()

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
        if !retainForNextJob,
           preparedLeaseModel != nil || pendingModelOwnership.activeLease != nil {
            return
        }

        selectPreparedModel(model)
        guard activeJobModel == nil, requestedModel == model else { return }

        let generation = preparationGeneration.begin()
        let resolvedModel: TranscriptionModelChoice
        let pendingLease: TranscriptionPendingModelLease?
        if retainForNextJob {
            resolvedModel = router.retainModelForForegroundUse(model)
            let replacement = pendingModelOwnership.replace(
                with: resolvedModel,
                generation: generation
            )
            pendingLease = replacement.lease
            if let replacedModel = replacement.replacedModel {
                router.releaseModelFromForegroundUse(replacedModel)
            }
            await router.initializeRetainedModel(resolvedModel)
        } else {
            pendingLease = nil
            resolvedModel = await router.initialize(model: model)
        }

        guard
            !Task.isCancelled,
            preparationGeneration.isCurrent(generation),
            activeJobModel == nil,
            requestedModel == model,
            router.isModelLoaded(for: resolvedModel)
        else {
            if let pendingLease {
                releasePendingLease(ifMatching: pendingLease)
            }
            return
        }

        if let pendingLease {
            guard let promotedModel = pendingModelOwnership.take(ifMatching: pendingLease) else {
                return
            }
            releasePreparedLease()
            preparedModel = promotedModel
            preparedLeaseModel = promotedModel
            return
        }

        releasePreparedLease()
        preparedModel = resolvedModel
        preparedLeaseModel = nil
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
        releasePendingLease()
        releasePreparedLease()
        requestedModel = model
        preparedModel = model
    }

    func beginTranscriptionJob() {
        guard activeJobModel == nil else { return }
        preparationGeneration.invalidate()
        releasePendingLease()

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
        releasePendingLease()
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

    private func releasePendingLease(
        ifMatching lease: TranscriptionPendingModelLease? = nil
    ) {
        let model: TranscriptionModelChoice?
        if let lease {
            model = pendingModelOwnership.take(ifMatching: lease)
        } else {
            model = pendingModelOwnership.takeActiveModel()
        }
        guard let model else { return }
        router.releaseModelFromForegroundUse(model)
    }
}
