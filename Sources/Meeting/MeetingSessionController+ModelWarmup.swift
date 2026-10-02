// MeetingSessionController+ModelWarmup.swift
// Model preparation, its result and recovery telemetry, prepared-model reset on
// selection change, warmup status logging, and the models-warm queries.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    // MARK: - Public API

    /// Load STT + diarization models. Call once before the first recording.
    /// Transitions state: idle → loadingModels → ready, or → error(String).
    ///
    func prepareModels(showLoadingUI: Bool = true) async {
        resetPreparedSpeechModelIfNeeded()

        if case .ready = state, sttAdapter.isReady { return }

        if showLoadingUI, case .loadingModels = state {
            if let task = modelPreparationTask {
                _ = await task.value
                return
            }
        }

        if showLoadingUI {
            shouldSurfaceMeetingWarmupFailure = false
            // prepareModels() is reused by several callers, not all of which
            // synchronously check `state` immediately before calling it —
            // FailedMeetingStore's retry flow in particular can reach here
            // after its own async steps, by which point a completely
            // different recording may have started. Must not stomp that
            // live capture's `state`; the model load itself still proceeds
            // below regardless; warmupStatus (a separate, capture
            // -independent signal) still refreshes.
            if !isCaptureSessionActive {
                transition(to: .loadingModels, reason: "model_preparation_started")
            }
            refreshWarmupStatus()
        }

        if let task = modelPreparationTask {
            let result = await task.value
            applyModelPreparationResult(result, showLoadingUI: showLoadingUI)
            return
        }

        let modelPreparationStartedAt = CFAbsoluteTimeGetCurrent()
        let retrySource = showLoadingUI ? "warmup" : "background_warmup"
        let surface = showLoadingUI ? "meeting" : "runtime"
        WorkflowRecoveryTelemetry.attempted(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: retrySource,
            surface: surface,
            artifactRetained: false
        )
        let task = Task<Result<Void, Error>, Never> { [downloader] in
            do {
                try await TranscriptedConstants.withDetachedTimeout(
                    seconds: TranscriptedConstants.modelLoadWaitBudget
                ) {
                    try await downloader.ensureModelsReady()
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        modelPreparationTask = task
        let result = await task.value
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        applyModelPreparationResult(result, showLoadingUI: showLoadingUI)
        trackModelPreparationRecoveryFinished(
            result,
            retrySource: retrySource,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - modelPreparationStartedAt,
            surface: surface
        )
    }

    private func applyModelPreparationResult(_ result: Result<Void, Error>, showLoadingUI: Bool) {
        switch result {
        case .success:
            shouldSurfaceMeetingWarmupFailure = false
            switch state {
            case .recording, .transcribing, .startingRecording, .stoppingRecording:
                break
            default:
                transition(to: .ready, reason: "model_preparation_succeeded")
            }
        case .failure(let error):
            shouldSurfaceMeetingWarmupFailure = showLoadingUI
            if showLoadingUI {
                // prepareModels() is awaited from user-initiated flows
                // (import, retranscribe, starting a new recording) that can
                // race with a DIFFERENT recording starting concurrently —
                // must not stomp that live capture's `state`.
                reportUnrelatedFailure(error.localizedDescription, reason: "model_preparation_failed")
            }
        }

        refreshWarmupStatus()
    }

    private func trackModelPreparationRecoveryFinished(
        _ result: Result<Void, Error>,
        retrySource: String,
        elapsedSeconds: TimeInterval,
        surface: String
    ) {
        let recoveryResult: String
        switch result {
        case .success:
            recoveryResult = "success"
        case .failure:
            recoveryResult = "failed"
        }
        WorkflowRecoveryTelemetry.finished(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: retrySource,
            result: recoveryResult,
            elapsedSeconds: elapsedSeconds,
            surface: surface,
            artifactRetained: false
        )
    }

    func resetPreparedSpeechModelIfNeeded() {
        let preparedEngine = sttAdapter.transcriptionEngineDescriptor.identifier
        let selectedEngine = sttRouter.selectedModel.transcriptionEngineIdentifier
        guard preparedEngine != selectedEngine else { return }

        switch state {
        case .recording, .transcribing, .startingRecording, .stoppingRecording:
            refreshWarmupStatus()
            return
        case .idle, .loadingModels, .ready, .error:
            break
        }

        modelPreparationTask = nil
        sttAdapter.cleanup()
        if case .ready = state {
            transition(to: .idle, reason: "speech_model_selection_changed")
        }
        refreshWarmupStatus()
    }

    func logWarmupStatusChange(from oldValue: ModelWarmupStatus, to newValue: ModelWarmupStatus) {
        guard warmupDiagnosticsSignature(for: oldValue) != warmupDiagnosticsSignature(for: newValue) else { return }

        DiagnosticsTrail.record(
            level: newValue.title.contains("Couldn’t") ? .warning : .info,
            engine: "meeting",
            event: "warmup_status_changed",
            message: newValue.subtitle,
            context: [
                "title": newValue.title,
                "subtitle": newValue.subtitle,
                "progress_pct": "\(Int(newValue.progress * 100))",
                "dictation_status": newValue.dictationStatus,
                "meetings_status": newValue.meetingsStatus
            ]
        )
    }

    private func warmupDiagnosticsSignature(for status: ModelWarmupStatus) -> String {
        [
            status.title,
            status.subtitle,
            status.dictationStatus,
            status.meetingsStatus,
            "\(Int(status.progress * 10))"
        ].joined(separator: "|")
    }

    var isSpeechModelPreparedForSelection: Bool {
        sttAdapter.transcriptionEngineDescriptor.identifier == sttRouter.selectedModel.transcriptionEngineIdentifier
            && sttAdapter.isReady
    }

    /// True when both the selected speech model and the speaker models are
    /// loaded, so a meeting can be transcribed without any model loading.
    var areMeetingModelsWarm: Bool {
        isSpeechModelPreparedForSelection && diarization.isReady
    }
}
