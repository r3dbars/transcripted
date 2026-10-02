// MeetingSessionController+CancelAndTermination.swift
// Confirmed discard (cancelRecording), quit-time stop and termination, and the
// bounded waits on a pending start or stop.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    /// Used by the quit-confirmation "Stop Recording" choice: `state ==
    /// .recording` is `stopRecording()`'s own entry guard, so a start still
    /// engaging the mic (`.startingRecording`) would make a bare
    /// `stopRecording()` call silently no-op — and the pending start would
    /// go on to resolve to `.recording` afterward, leaving the meeting
    /// recording despite the user's explicit "stop" choice. Join the
    /// pending start (bounded) first, then stop it.
    func stopRecordingJoiningPendingStart(reason: StopReason) async {
        if isStartingRecording {
            await waitForPendingRecordingStartToResolve()
        }
        await stopRecording(reason: reason)
    }

    /// Cancel capture after an explicit confirmation, without queueing
    /// transcription or saving a transcript.
    func cancelRecording(reason: RecordingCancelReason = .unknown) async {
        guard case .recording = state else { return }
        transition(to: .stoppingRecording, reason: "cancel_requested")
        _ = audioInactivityDetector.stopRecording()
        audioInactivityWarning = nil
        isMicBoostPromptVisible = false
        let recordingSnapshot = makeRecordingStopSnapshot()
        clearActiveRecordingIdentity()

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_cancel_requested",
            message: "Meeting cancellation requested",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(recordingSnapshot.durationMilliseconds)"
                ]
            )
        )

        let stopResult = await capture.stopAndDiscardFiles()
        await capture.flushSharedDictationMicHandler()
        clearSharedDictationMicRelay()
        await sttRouter.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded()
        let files = (micURL: stopResult.micURL, systemURL: stopResult.systemURL)
        let afterStopVolumeContext = capture.routeVolumeDiagnosticsContext(currentPhase: "after")
        var cancelCaptureDiagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            liveAttenuationCueObserved: capture.micAttenuationCueObserved,
            baseContext: meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot, telemetryIdentity: recordingSnapshot.telemetryIdentity),
            afterStopContext: afterStopVolumeContext
        )
        // Mirror stopRecording(): cancelled meetings carry the prompt outcome
        // too, so diagnostics can correlate cancellations with the prompt.
        cancelCaptureDiagnostics["mic_boost_prompt"] = micBoostPromptOutcomeForSavedCapture().rawValue
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
        activeRecordingStartedAt = nil
        restoreStateAfterRecordingEndedWithoutNewWork()
        AppSoundPlayer.shared.play(.dictationCancelled)
        Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "cancelled")
        let cancelDiagnosticsContext = cancelCaptureDiagnostics.merging(
            [
                "trigger": recordingSnapshot.trigger.rawValue,
                "reason": reason.rawValue,
                "duration_ms": "\(recordingSnapshot.durationMilliseconds)",
                "mic_file_present": boolString(files.micURL != nil),
                "system_file_present": boolString(files.systemURL != nil),
                "stop_timed_out": boolString(stopResult.didTimeOut)
            ],
            uniquingKeysWith: { _, new in new }
        )

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_recording_cancelled",
            message: "Meeting recording cancelled",
            context: baseDiagnosticsContext(extra: cancelDiagnosticsContext)
        )
        AnalyticsReporter.track(
            "meeting_recording_cancelled",
            properties: cancelCaptureDiagnostics.merging(
                [
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingSnapshot.durationSeconds),
                    "reason": reason.rawValue,
                    "stop_timed_out": boolString(stopResult.didTimeOut),
                    "system_stream_present": boolString(files.systemURL != nil),
                    "trigger": recordingSnapshot.trigger.rawValue,
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        ProductFrictionTelemetry.track(
            surface: .meeting,
            stage: "meeting_recording",
            result: .cancelled,
            failureKind: reason.rawValue,
            elapsedBucket: AnalyticsReporter.durationBucket(seconds: recordingSnapshot.durationSeconds),
            modelState: state.diagnosticName
        )
        AnalyticsReporter.track(
            "meeting_capture_health_snapshot",
            properties: MeetingCaptureHealthTelemetry.snapshotProperties(
                .init(
                    captureDiagnostics: cancelCaptureDiagnostics,
                    health: captureHealthFacts(from: recordingSnapshot.healthInfo),
                    trigger: recordingSnapshot.trigger.rawValue,
                    reason: reason.rawValue,
                    durationSeconds: recordingSnapshot.durationSeconds,
                    systemStreamPresent: files.systemURL != nil,
                    stopTimedOut: stopResult.didTimeOut,
                    captureOutcome: "cancelled"
                )
            )
        )
    }

    private func restoreStateAfterRecordingEndedWithoutNewWork() {
        guard !hasVisibleBackgroundTranscriptionWork else {
            transition(to: .transcribing, reason: "cancel_completed_background_work_visible")
            return
        }

        switch lastTerminalTranscriptionOutcome {
        case .failed(let message):
            transition(to: .error(message), reason: "cancel_completed_prior_failure")
        case .transcriptSaved, .discarded, .none:
            transition(to: .ready, reason: "cancel_completed")
        }
    }

    func prepareForTermination() async {
        var didPreserveRecording = false
        var recordingTrigger = activeRecordingTrigger
        var stoppedFiles: (micURL: URL?, systemURL: URL?) = (nil, nil)
        var stopTimedOut = false

        if isStartingRecording {
            // Quit-confirm now fires while capture is only engaging the mic
            // (isCaptureSessionActive covers .startingRecording, correctly
            // widening force-quit gating to that window), so "Save Audio and
            // Quit" can land here before startRecording()'s own
            // `await capture.startRecording()` has resolved. Join it
            // (bounded) instead of quitting out from under it: otherwise a
            // recording that was about to succeed would be neither saved
            // nor visibly recorded, breaking the dialog's promise. Once this
            // resolves, `state` is .recording (success) or .error (failure)
            // — startRecording() itself owns that transition synchronously.
            await waitForPendingRecordingStartToResolve()
        }

        if isStoppingRecording {
            await waitForRecordingFinishBeforeTermination()
        }

        if case .recording = state {
            // prepareForTermination() is only reached on the guaranteed-quit
            // path (see applicationShouldTerminate's .saveAudioAndQuit
            // branch) — there is no "back out of stop" case to restore
            // .recording for afterward.
            transition(to: .stoppingRecording, reason: "prepare_for_termination")

            _ = audioInactivityDetector.stopRecording()
            audioInactivityWarning = nil
            isMicBoostPromptVisible = false
            clearActiveRecordingIdentity()
            let skippedSystemAudioTap = !capture.currentRecordingCapturesSystemAudio

            let shutdownFailedTaskId = UUID()
            let files = await capture.stopAndAwaitFiles(
                timedOutOwner: .failedMeeting(shutdownFailedTaskId)
            ) { [weak self] lateResult in
                self?.failedMeetingStore.refreshTimedOutFailedMeetingAudio(
                    id: shutdownFailedTaskId,
                    result: lateResult
                )
            }
            stoppedFiles = (micURL: files.micURL, systemURL: files.systemURL)
            stopTimedOut = files.didTimeOut
            let meetingTitle = activeRecordingSuggestedTitle
            let recordingDate = activeRecordingStartedAt
            activeRecordingTrigger = .unknown
            activeRecordingSuggestedTitle = nil
            activeRecordingStartedAt = nil

            if files.didTimeOut {
                // The late completion may already be buffered even when the
                // timeout snapshot has no URLs, so always give the stable task
                // ID a chance to create its durable failed row.
                didPreserveRecording = failedMeetingStore.preserveTimedOutFailedMeetingForRetry(
                    taskId: shutdownFailedTaskId,
                    micAudioURL: files.micURL,
                    systemAudioURL: files.systemURL,
                    errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from the Meetings page after reopening.",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
                    languageSelection: recordingLanguageSelection,
                    micOnlyByChoice: skippedSystemAudioTap
                )
            } else if files.micURL != nil || files.systemURL != nil {
                didPreserveRecording = failedMeetingStore.preserveFailedMeetingForRetry(
                    taskId: shutdownFailedTaskId,
                    micAudioURL: files.micURL,
                    systemAudioURL: files.systemURL,
                    errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from the Meetings page after reopening.",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
                    languageSelection: recordingLanguageSelection,
                    micOnlyByChoice: skippedSystemAudioTap
                )
            }
        } else {
            recordingTrigger = .unknown
        }

        let queuedPreserved = transcriptionQueue.preserveQueuedTranscriptionJobsForShutdown(
            errorMessage: "Meeting saved before quit. Audio is safe; finish the queued transcript from the Meetings page after reopening."
        )
        let activePreserved = taskManager.preserveActiveTranscriptionsForShutdown(
            errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from the Meetings page after reopening."
        )
        // An active imported pipeline can enqueue speaker review just before
        // committing its transcript. Preserve that task first so review cleanup
        // cannot retire the journal and delete its only scratch copy. Completed
        // pipelines still finalize their typed recovery owner here.
        taskManager.cleanupPendingNaming()
        guard didPreserveRecording || queuedPreserved > 0 || activePreserved > 0 else { return }

        refreshFailedMeetings()
        transition(to: .ready, reason: "prepare_for_termination_preserved_work")
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_recording_saved_for_shutdown",
            message: "Meeting audio was preserved during app termination",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingTrigger.rawValue,
                    "mic_file_present": boolString(stoppedFiles.micURL != nil),
                    "system_file_present": boolString(stoppedFiles.systemURL != nil),
                    "stop_timed_out": boolString(stopTimedOut),
                    "active_preserved": "\(activePreserved)",
                    "queued_preserved": "\(queuedPreserved)"
                ]
            )
        )
    }

    private func waitForRecordingFinishBeforeTermination() async {
        let deadline = Date().addingTimeInterval(TranscriptedConstants.meetingTerminationFinishWaitTimeout)
        while isStoppingRecording && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Bounded wait for an in-flight `startRecording()` call to resolve —
    /// used both by `prepareForTermination()` (join before deciding what to
    /// save) and `stopRecordingJoiningPendingStart(reason:)` (join before
    /// stopping, so an explicit "Stop Recording" during the mic-engage
    /// window can't be silently dropped). The bridge start deadline is 12s
    /// after a known grant, or 120s while a first-run permission prompt may
    /// still be up. Either way it is shorter than this outer bound.
    private func waitForPendingRecordingStartToResolve() async {
        let deadline = Date().addingTimeInterval(TranscriptedConstants.meetingTerminationFinishWaitTimeout)
        while isStartingRecording && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
