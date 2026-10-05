// MeetingSessionController+TranscriptionOutcomes.swift
// Transcription outcomes: the coordinator outcome API, the task manager display
// status mirror, the accidental-start discard, failure telemetry contexts, and
// detected-prompt outcome bookkeeping.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    // MARK: - Outcome reporting (for TranscriptionQueueCoordinator)
    //
    // TranscriptionQueueCoordinator no longer drives `state`/`displayStatus`
    // directly (the old `setState`/`setDisplayStatus` seam). It reports what
    // happened; the handlers below own translating that into a transition.

    /// A queued transcription job began preparing/running.
    func transcriptionJobDidStart() {
        if !isCaptureSessionActive {
            transition(to: .transcribing, reason: "transcription_job_started")
        }
        updateDisplayStatus(.gettingReady, source: .controllerPhase)
    }

    /// A queued job failed before it could start (bounded model-recovery
    /// retry gave up). This job is not necessarily the active recording's
    /// own job — a completely different meeting can still be capturing live
    /// while an earlier queued transcript fails in the background — so this
    /// must not force `state` to `.error` while capture is live; see
    /// `MeetingSessionStateMachine.mayReportUnrelatedFailureAsError`.
    /// `displayStatus` still updates unconditionally: it is a separate,
    /// capture-independent "background work progress" signal.
    func transcriptionJobFailedToPrepare(message: String) {
        reportUnrelatedFailure(message, reason: "transcription_job_prepare_failed")
        updateDisplayStatus(.failed(message: message), source: .controllerPhase)
    }

    /// Background transcription work is still visible and capture isn't
    /// active — keep showing the transcribing state.
    func transcriptionWorkContinues() {
        guard !isCaptureSessionActive else { return }
        transition(to: .transcribing, reason: "transcription_work_continues")
    }

    /// The transcription queue has nothing left running or queued — settle
    /// `state` onto the terminal outcome of the last job that finished.
    func transcriptionQueueSettled() {
        guard let settled = MeetingSessionStateMachine.settledTransition(
            after: lastTerminalTranscriptionOutcome,
            current: state
        ) else { return }
        transition(to: settled.state, reason: settled.reason)
    }

    func handleDisplayStatusChange(from previousStatus: DisplayStatus, to status: DisplayStatus) {
        switch status {
        case .transcriptSaved:
            lastTerminalTranscriptionOutcome = .transcriptSaved
            let completedJobID = activeQueuedTranscriptionJobID
            if let stoppedAudioRecovery = activeStoppedAudioRecovery {
                activeStoppedAudioRecovery = nil
                Task.detached(priority: .utility) {
                    MeetingStoppedAudioCheckpointPolicy.finish(
                        stoppedAudioRecovery,
                        after: .transcriptSaved
                    )
                }
            }
            if let completedJobID {
                _ = stoppedAudioRecoveryRetryRegistry.remove(for: completedJobID)
            }
            let transcriptionTrigger = activeTranscriptionTrigger
            let promptTelemetryProperties = activeDetectedPromptTranscriptionTelemetryProperties
            let promptRecordingStartedAt = activeDetectedPromptTranscriptionRecordingStartedAt
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_transcript_saved",
                message: "Meeting transcript saved",
                context: baseDiagnosticsContext(
                    extra: [
                        "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                        "trigger": transcriptionTrigger.rawValue
                    ]
                )
            )
            var savedTranscriptProperties = [
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count),
                "trigger": transcriptionTrigger.rawValue,
            ]
            // Saved-task ownership is captured before async metadata reads or
            // queue advancement. A different meeting may already be recording.
            savedTranscriptProperties.merge(
                MeetingProcessingTelemetry.savedArtifactIdentityProperties(
                    savedTaskID: taskManager.lastSavedTranscriptTaskId,
                    queuedTaskID: completedJobID,
                    captureDiagnostics: activeTranscriptionCaptureDiagnostics
                ),
                uniquingKeysWith: { _, new in new }
            )
            if let timings = taskManager.lastPipelineTimings {
                savedTranscriptProperties.merge(
                    MeetingProcessingTelemetry.properties(for: Self.processingTelemetryTimings(timings)),
                    uniquingKeysWith: { current, _ in current }
                )
            }
            // Activation belongs to the confirmed save, not to a later metadata
            // read: a dictation can save while this meeting waits for restyling.
            ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                artifactKind: .meeting,
                surface: .meetingSave,
                trigger: transcriptionTrigger.rawValue,
                correlationID: savedTranscriptProperties["correlation_id"],
                saveID: savedTranscriptProperties["save_id"]
            )
            trackSavedTranscriptAnalyticsInBackground(
                baseProperties: savedTranscriptProperties,
                promptTelemetryProperties: promptTelemetryProperties,
                promptRecordingStartedAt: promptRecordingStartedAt
            )
            clearDetectedPromptTelemetry()
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcript_saved")
            AppSoundPlayer.shared.play(.meetingTranscriptComplete)
            activeQueuedTranscriptionJobID = nil
            activeTranscriptionCaptureDiagnostics = nil
        case .discardedAccidentalStart:
            handleAccidentalStartDiscarded()
        case .failed(let message):
            lastTerminalTranscriptionOutcome = .failed(message)
            // A failed import must retain its original stopped-audio checkpoint.
            if let failedJobID = activeQueuedTranscriptionJobID,
               let stoppedAudioRecovery = activeStoppedAudioRecovery {
                stoppedAudioRecoveryRetryRegistry.retain(
                    stoppedAudioRecovery,
                    for: failedJobID
                )
            }
            activeStoppedAudioRecovery = nil
            let transcriptionTrigger = activeTranscriptionTrigger
            let diagnosticMessage = taskManager.lastFailureDiagnosticMessage ?? message
            // Only trust the typed kind when it was captured alongside the diagnostic
            // message actually being classified below — not when this fell back to
            // the raw overlay `message`, which never had a typed kind computed for it.
            let errorKind = taskManager.lastFailureDiagnosticMessage != nil ? taskManager.lastFailureErrorKind : nil
            let failureKind = MeetingFailureKind.classify(errorKind: errorKind, message: diagnosticMessage)
            if failureKind.shouldReportAsSkippedTranscript {
                activeQueuedTranscriptionJobID = nil
                let failureTelemetryContext = meetingFailureTelemetryContext(
                    failureKind: failureKind,
                    transcriptionTrigger: transcriptionTrigger
                )
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_transcript_skipped",
                    message: "Meeting transcription skipped because the recording had no transcriptable speech",
                    context: baseDiagnosticsContext(
                        extra: [
                            "failure_kind": failureKind.rawValue,
                            "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                            "trigger": transcriptionTrigger.rawValue
                        ]
                    )
                )
                AnalyticsReporter.track(
                    "meeting_transcript_skipped",
                    properties: failureTelemetryContext
                )
                trackDetectedPromptOutcome(
                    .transcriptSkipped,
                    elapsedSeconds: detectedPromptRecordingElapsedSeconds(),
                    promptProperties: activeDetectedPromptTranscriptionTelemetryProperties
                )
                clearDetectedPromptTelemetry()
                ProductFrictionTelemetry.track(
                    surface: .meeting,
                    stage: "meeting_transcription",
                    result: .giveUp,
                    failureKind: failureKind.rawValue,
                    modelState: state.diagnosticName
                )
                // taskManager runs one job at a time, but that job can be an
                // earlier meeting's queued transcript finishing in the
                // background while a different meeting is actively
                // recording live right now — must not stomp that capture.
                let skipped = MeetingSessionStateMachine.skippedTranscript(
                    diagnosticMessage: diagnosticMessage,
                    while: state
                )
                lastTerminalTranscriptionOutcome = skipped.terminalOutcome
                if let visibleState = skipped.visibleState {
                    transition(to: visibleState, reason: "transcript_skipped")
                }
                activeTranscriptionCaptureDiagnostics = nil
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: failureKind.rawValue)
                transcriptionQueue.handleBackgroundTranscriptionWorkChanged()
                return
            }

            if failureKind == .speakerFinalizationFailed || failureKind == .speakerNameFinalizationFailed {
                activeQueuedTranscriptionJobID = nil
                let queueDepthBucket = AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count)
                // Read inside this synchronous sink: the task manager publishes the
                // coarse cause just before the failed status that got us here.
                let failureTelemetryContext = meetingFailureTelemetryContext(failureKind: failureKind, transcriptionTrigger: transcriptionTrigger)
                    .merging(
                        speakerFinalizationFailureTelemetryContext(taskManager.lastSpeakerFinalizationFailure),
                        uniquingKeysWith: { current, _ in current }
                    )
                DiagnosticsTrail.record(
                    level: .error,
                    engine: "meeting",
                    event: "speaker_finalization_failed",
                    message: "Meeting speaker naming finalization failed",
                    context: baseDiagnosticsContext(
                        extra: failureTelemetryContext.merging([
                            "failure_kind": failureKind.rawValue,
                            "session_stage": "save",
                            "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                            "queue_depth_bucket": queueDepthBucket,
                            "trigger": transcriptionTrigger.rawValue
                        ], uniquingKeysWith: { current, _ in current })
                    )
                )
                AnalyticsReporter.track(
                    "meeting_speaker_finalization_failed",
                    properties: failureTelemetryContext
                )
                trackDetectedPromptOutcome(
                    .speakerFinalizationFailed,
                    elapsedSeconds: detectedPromptRecordingElapsedSeconds(),
                    promptProperties: activeDetectedPromptTranscriptionTelemetryProperties
                )
                clearDetectedPromptTelemetry()
                ProductFrictionTelemetry.track(
                    surface: .meeting,
                    stage: "speaker_finalization",
                    result: .failed,
                    failureKind: failureKind.rawValue,
                    modelState: state.diagnosticName,
                    context: failureTelemetryContext
                )
                activeTranscriptionCaptureDiagnostics = nil
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "speaker_finalization_failed")
                transcriptionQueue.handleBackgroundTranscriptionWorkChanged()
                return
            }

            activeQueuedTranscriptionJobID = nil
            let failureTelemetryContext = meetingFailureTelemetryContext(
                failureKind: failureKind,
                transcriptionTrigger: transcriptionTrigger
            )
            let failureDiagnosticsContext = failureTelemetryContext.merging(
                [
                    "error": message,
                    "diagnostic_error": diagnosticMessage,
                    "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                ],
                uniquingKeysWith: { _, new in new }
            )
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcript_failed",
                message: "Meeting transcription failed",
                context: baseDiagnosticsContext(extra: failureDiagnosticsContext)
            )
            AnalyticsReporter.track(
                "meeting_transcript_failed",
                properties: failureTelemetryContext
            )
            trackDetectedPromptOutcome(
                .transcriptFailed,
                elapsedSeconds: detectedPromptRecordingElapsedSeconds(),
                promptProperties: activeDetectedPromptTranscriptionTelemetryProperties
            )
            clearDetectedPromptTelemetry()
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "meeting_transcription",
                result: .failed,
                failureKind: failureKind.rawValue,
                modelState: state.diagnosticName,
                context: failureTelemetryContext
            )
            activeTranscriptionCaptureDiagnostics = nil
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcript_failed")
            transcriptionQueue.handleBackgroundTranscriptionWorkChanged()
        case .gettingReady:
            if previousStatus.diagnosticName != status.diagnosticName {
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_pipeline_phase",
                    message: "Meeting pipeline getting ready",
                    context: baseDiagnosticsContext(extra: ["phase": "getting_ready"])
                )
            }
        case .transcribing(let progress):
            // Compare raw pipeline progress on both sides; `previousStatus.progress`
            // is the UI-mapped value and would log on nearly every tick.
            let previousTranscribingProgress: Double?
            if case .transcribing(let previousProgress) = previousStatus {
                previousTranscribingProgress = previousProgress
            } else {
                previousTranscribingProgress = nil
            }
            if MeetingPipelinePhaseCadence.shouldRecord(
                previousTranscribingProgress: previousTranscribingProgress,
                progress: progress
            ) {
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_pipeline_phase",
                    message: "Meeting transcription in progress",
                    context: baseDiagnosticsContext(
                        extra: [
                            "phase": "transcribing",
                            "progress_pct": "\(Int(progress * 100))"
                        ]
                    )
                )
            }
        case .finishing:
            if previousStatus.diagnosticName != status.diagnosticName {
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_pipeline_phase",
                    message: "Meeting transcription finishing",
                    context: baseDiagnosticsContext(extra: ["phase": "finishing"])
                )
            }
        default:
            break
        }
    }

    /// Core threw away a very short, speechless recording (a mis-click or a
    /// start that was stopped right away). To the person this is a cancel:
    /// no "Saved", no failed row on Home, no "No speech found". Telemetry
    /// still counts it, as `accidental_start`, so the product numbers keep
    /// seeing how often it happens without calling it a failure.
    private func handleAccidentalStartDiscarded() {
        lastTerminalTranscriptionOutcome = .discarded
        if let completedJobID = activeQueuedTranscriptionJobID {
            _ = stoppedAudioRecoveryRetryRegistry.remove(for: completedJobID)
        }
        activeQueuedTranscriptionJobID = nil
        // Only live recordings are discarded, and those never carry a stopped
        // dictation checkpoint; leave any file alone rather than delete it.
        activeStoppedAudioRecovery = nil
        let transcriptionTrigger = activeTranscriptionTrigger
        let failureKind = Self.accidentalStartFailureKind
        let telemetryContext = TelemetryContext.enrich(
            event: "meeting_transcript_skipped",
            properties: (activeTranscriptionCaptureDiagnostics ?? [:]).merging(
                [
                    "failure_stage": "transcription",
                    "failure_kind": failureKind,
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count),
                    "trigger": transcriptionTrigger.rawValue,
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_transcript_skipped",
            message: "Meeting recording discarded as an accidental start",
            context: baseDiagnosticsContext(
                extra: [
                    "failure_kind": failureKind,
                    "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                    "trigger": transcriptionTrigger.rawValue
                ]
            )
        )
        AnalyticsReporter.track("meeting_transcript_skipped", properties: telemetryContext)
        trackDetectedPromptOutcome(
            .transcriptSkipped,
            elapsedSeconds: detectedPromptRecordingElapsedSeconds(),
            promptProperties: activeDetectedPromptTranscriptionTelemetryProperties
        )
        clearDetectedPromptTelemetry()
        ProductFrictionTelemetry.track(
            surface: .meeting,
            stage: "meeting_transcription",
            result: .cancelled,
            failureKind: failureKind,
            modelState: state.diagnosticName
        )
        // An earlier queued meeting can be discarded while a new one is
        // recording; a "cancelled" sound then would sound like the live one.
        if !isCaptureSessionActive {
            AppSoundPlayer.shared.play(.dictationCancelled)
        }
        activeTranscriptionCaptureDiagnostics = nil
        Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: failureKind)
        transcriptionQueue.handleBackgroundTranscriptionWorkChanged()
    }

    private func meetingFailureTelemetryContext(
        failureKind: MeetingFailureKind,
        transcriptionTrigger: StartTrigger
    ) -> [String: String] {
        TelemetryContext.enrich(event: "meeting_transcript_failed", properties: (activeTranscriptionCaptureDiagnostics ?? [:]).merging(
            [
                "failure_stage": failureKind == .speakerFinalizationFailed || failureKind == .speakerNameFinalizationFailed ? "speaker_finalization" : "transcription",
                "failure_kind": failureKind.rawValue,
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count),
                "trigger": transcriptionTrigger.rawValue,
            ],
            uniquingKeysWith: { _, new in new }
        ))
    }

    /// Coarse, privacy-safe cause of a speaker review save failure. Empty when
    /// the task manager published none, so older paths just omit the keys.
    private func speakerFinalizationFailureTelemetryContext(
        _ failure: SpeakerFinalizationFailure?
    ) -> [String: String] {
        guard let failure else { return [:] }
        return [
            "finalization_reason": failure.reason.rawValue,
            "review_mode": failure.reviewMode.rawValue,
            "is_retry": boolString(failure.isRetry),
        ]
    }

    func trackDetectedPromptOutcome(
        _ outcomeKind: MeetingPromptTelemetry.OutcomeKind,
        elapsedSeconds: TimeInterval? = nil,
        promptProperties: [String: String]?
    ) {
        // No implicit fallback here: a nil `promptProperties` means this call
        // site has no detected-prompt properties to attribute (e.g. a
        // manual/hotkey-triggered recording), so tracking is skipped rather
        // than mislabeling the outcome with an unrelated detected-prompt
        // meeting that happens to be transcribing in the background. Callers
        // that legitimately want the currently-transcribing job's properties
        // must pass `activeDetectedPromptTranscriptionTelemetryProperties`
        // explicitly.
        guard let properties = MeetingPromptTelemetry.sessionOutcomeProperties(
            promptProperties: promptProperties,
            outcomeKind: outcomeKind,
            elapsedSeconds: elapsedSeconds
        ) else { return }
        AnalyticsReporter.track("meeting_prompt_outcome_recorded", properties: properties)
    }

    private func detectedPromptRecordingElapsedSeconds() -> TimeInterval? {
        guard let activeDetectedPromptTranscriptionRecordingStartedAt else {
            return nil
        }
        return Date().timeIntervalSince(activeDetectedPromptTranscriptionRecordingStartedAt)
    }

    private func clearDetectedPromptTelemetry() {
        activeDetectedPromptTranscriptionTelemetryProperties = nil
        activeDetectedPromptTranscriptionRecordingStartedAt = nil
    }

    func clearDetectedPromptRecordingTelemetry() {
        activeDetectedPromptRecordingTelemetryProperties = nil
        activeDetectedPromptRecordingStartedAt = nil
    }
}
