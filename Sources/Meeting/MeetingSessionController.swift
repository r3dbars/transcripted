// MeetingSessionController.swift
// The meeting recording lifecycle: startRecording, stopRecording, the unexpected
// capture stop, the stop snapshot, and system-audio signal verification.
// The class itself (stored state, init, the single state writers) is declared
// in MeetingSessionController+State.swift; the other +*.swift files hold the rest.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    private enum CaptureOutcome: String {
        case complete
        case micOnly = "mic_only"
        case systemOnly = "system_only"
        case noAudio = "no_audio"
        case timedOut = "timed_out"
        /// "Record Just My Mic": the mic is everything the user asked for.
        /// Distinct from `complete` so dashboards can tell it from a call.
        case micOnlyByChoice = "mic_only_by_choice"

        init(micURL: URL?, systemURL: URL?, didTimeOut: Bool) {
            if didTimeOut {
                self = .timedOut
            } else {
                switch (micURL != nil, systemURL != nil) {
                case (true, true): self = .complete
                case (true, false): self = .micOnly
                case (false, true): self = .systemOnly
                case (false, false): self = .noAudio
                }
            }
        }
    }

    /// Begin a new meeting recording. Safe to call from UI buttons. If a prior
    /// meeting is still transcribing, the new capture starts immediately and
    /// the older transcript continues in the background.
    @discardableResult
    func startRecording(
        trigger: StartTrigger = .unknown,
        suggestedTitle: String? = nil,
        promptTelemetryProperties: [String: String]? = nil
    ) async -> Bool {
        let admission = MeetingSessionStateMachine.startAdmission(
            startCallInFlight: startRecordingCallInFlight,
            state: state
        )
        switch admission {
        case .ignoredStartInFlight:
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_start_ignored",
                message: "Meeting start ignored because another start is already in progress",
                context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
            )
            // The caller did not start a recording. Returning false keeps a
            // prompt action from treating a competing start as accepted.
            return admission.acceptsRecord
        case .ignoredActiveCapture:
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_start_ignored",
                message: "Meeting start ignored because another meeting flow is active",
                context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
            )
            // The caller did not start a recording. Returning false keeps a
            // prompt or menu action from treating an already-active capture
            // as an accepted Record.
            return admission.acceptsRecord
        case .accepted:
            break
        }

        // `state` cannot carry this reentrancy guard on its own: the
        // permission-check preamble below awaits while `state` still holds
        // a "free" value (.idle/.ready/.error, and a background model
        // prepare can move it between those), so a second concurrent call
        // would see one of those values and slip past a `state`-only guard. `.startingRecording` is used
        // further down for the narrower, unambiguous "capture.startRecording()
        // is actually engaging the mic" window instead.
        startRecordingCallInFlight = true
        meetingActionIdentity = UUID()
        defer { startRecordingCallInFlight = false }
        // The call-audio ask belongs to this start: a start that ends without
        // recording drops it, so the next meeting never shows a stale one.
        callAudioAsk.startAttemptBegan()
        defer {
            let isRecordingNow: Bool
            if case .recording = state { isRecordingNow = true } else { isRecordingNow = false }
            callAudioAsk.startAttemptEnded(recording: isRecordingNow)
        }
        recordingSTTModel = sttRouter.selectedModel
        recordingLanguageSelection = TranscriptionLanguageSelection(
            rawValue: TranscriptionLanguagePreferences.effectiveLanguageCode(for: recordingSTTModel)
        ) ?? .automatic
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "start_requested")
        activeDetectedPromptRecordingTelemetryProperties = trigger == .detectedPrompt ? promptTelemetryProperties : nil
        activeDetectedPromptRecordingStartedAt = nil
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_start_requested",
            message: "Meeting start requested",
            context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
        )

        let startDecision = await resolveStartRecordingPermissionDecision(trigger: trigger)
        guard startDecision.canStart else {
            let permissionCheckWasInconclusive = startDecision.systemAudioPermissionCheckWasInconclusive
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "permission_start",
                result: .blocked,
                failureKind: startDecision.failureReason ?? "permissions",
                modelState: state.diagnosticName
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: permissionCheckWasInconclusive
                    ? "meeting_start_permission_check_inconclusive"
                    : "meeting_start_blocked_permission",
                message: permissionCheckWasInconclusive
                    ? "Meeting recording blocked because system audio access could not be verified"
                    : "Meeting recording blocked because a required permission is missing",
                context: baseDiagnosticsContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "failure_reason": startDecision.failureReason ?? "permissions",
                        "missing_permissions": startDecision.missingPermissions.joined(separator: ",")
                    ]
                )
            )
            // A permission miss on a new start must not hide a live queued or
            // active transcription. `reportUnrelatedFailure` already refuses
            // to stomp capture; skip `.transcribing` here as well.
            switch state {
            case .transcribing:
                break
            default:
                reportUnrelatedFailure(
                    startDecision.errorMessage
                        ?? "Turn on the required permissions in System Settings before recording a meeting.",
                    reason: "start_blocked_permission",
                    systemAudioPermissionRecoveryNeeded: MeetingRecordingStartGate.shouldOfferSystemAudioPermissionRecovery(
                        missingPermissions: startDecision.missingPermissions
                    )
                )
            }
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "start_blocked_permission")
            trackDetectedPromptOutcome(
                .recordingStartFailed,
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
            clearDetectedPromptRecordingTelemetry()
            return false
        }

        meetingModelsWarmAtStart = areMeetingModelsWarm
        catchUpModelsInBackgroundIfNeeded(trigger: trigger)

        let resolvedMeetingTitle = MeetingRecordingTitlePolicy.resolve(
            explicitTitle: suggestedTitle,
            calendarTitle: calendarSuggestedTitleProvider?()
        )
        activeRecordingTrigger = trigger
        activeRecordingIdentity = UUID()
        micBoostPromptRecordingIdentity = nil
        micBoostPromptOutcome = .notShown
        micBoostArmPendingIdentity = nil
        isMicBoostPromptVisible = false
        audioRouteWarning = nil
        systemAudioDegradationWarning = nil
        unheardPlaybackWarningStartedAt = nil
        activeRecordingIsMicOnlyByChoice = startDecision.recordsMicOnlyByChoice
        activeRecordingSystemAudioAccessConfirmed = nil
        clearMicOnlyNotice()
        micOnlyNotice = MeetingMicOnlyNoticePolicy.initialNotice(
            capturesSystemAudio: startDecision.capturesSystemAudio
        )
        activeRecordingSuggestedTitle = resolvedMeetingTitle
        installSharedDictationMicRelay()

        transition(to: .startingRecording, reason: "capture_start_requested")
        // A first-run or inconclusive System Audio check can still be sitting
        // on the macOS dialog. Use the permission-prompt budget then; keep
        // the 12s streaming deadline once access is already known.
        let startTimeout = startDecision.systemAudioPermissionCheckWasInconclusive
            || startDecision.mayRaiseSystemAudioPermissionPrompt
            ? TranscriptedConstants.systemAudioPermissionRequestTimeout
            : TranscriptedConstants.meetingStartTimeout
        let started = await capture.startRecording(
            timeout: startTimeout,
            languageSelection: recordingLanguageSelection,
            capturesSystemAudio: startDecision.capturesSystemAudio
        )
        guard started else {
            let failedStartIdentity = activeRecordingIdentity
            await capture.flushSharedDictationMicHandler()
            clearSharedDictationMicRelay()
            activeRecordingTrigger = .unknown
            clearActiveRecordingIdentity()
            activeRecordingSuggestedTitle = nil
            activeRecordingStartedAt = nil
            let rawFailureMessage = capture.errorMessage ?? "Meeting audio didn't start. Check your audio devices, then try again."
            let failureMessage = MeetingRecordingStartGate.captureFailureMessage(
                rawFailureMessage,
                systemAudioPermissionCheckWasInconclusive: startDecision.systemAudioPermissionCheckWasInconclusive,
                explicitSystemAudioPermissionDenialObserved: capture.systemAudioStartPermissionExplicitlyDenied
            )
            let pipelineSnapshot = capture.pipelineDiagnosticsSnapshot(
                overrideSystemAudioStatus: capture.startFailureStage == .systemAudio ? .failed : nil
            )
            let failureProperties = TelemetryContext.enrich(event: "meeting_recording_start_failed", properties: meetingCaptureAnalyticsProperties(snapshot: pipelineSnapshot, telemetryIdentity: failedStartIdentity).merging(
                [
                    "failure_kind": meetingStartFailureKind(
                        from: failureMessage,
                        stage: capture.startFailureStage.rawValue
                    ),
                    "start_failure_stage": capture.startFailureStage.rawValue,
                    "trigger": trigger.rawValue,
                ],
                uniquingKeysWith: { _, new in new }
            ))
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_start_failed",
                message: failureMessage,
                context: baseDiagnosticsContext(extra: failureProperties)
            )
            AnalyticsReporter.track(
                "meeting_recording_start_failed",
                properties: failureProperties
            )
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "meeting_start",
                result: .failed,
                failureKind: failureProperties["failure_kind"],
                modelState: state.diagnosticName,
                context: failureProperties
            )
            transition(
                to: .error(failureMessage),
                reason: "capture_start_failed",
                systemAudioPermissionRecoveryNeeded: MeetingCaptureHealthEvidence.make(capture: capture)
                    .systemAudioPermissionRecoveryNeeded
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "start_failed")
            trackDetectedPromptOutcome(
                .recordingStartFailed,
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
            clearDetectedPromptRecordingTelemetry()
            return false
        }

        activeRecordingStartedAt = Date()
        unexpectedCaptureStopEvidence = nil
        if trigger == .detectedPrompt {
            activeDetectedPromptRecordingStartedAt = activeRecordingStartedAt
            trackDetectedPromptOutcome(
                .recordingStarted,
                elapsedSeconds: 0,
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
        }
        transition(to: .recording, reason: "capture_start_confirmed")
        refreshSystemAudioSignalVerification(shouldWarn: startDecision.systemAudioPermissionCheckWasInconclusive)
        if startDecision.mayRaiseSystemAudioPermissionPrompt {
            micOnlyNotice = MeetingMicOnlyNoticePolicy.noticeAfterStart(
                current: micOnlyNotice,
                mayHaveRaisedMacOSBox: true,
                status: TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
            )
        }
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "recording")
        let pipelineSnapshot = capture.pipelineDiagnosticsSnapshot()
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_recording_started",
            message: "Meeting recording started",
            context: baseDiagnosticsContext(
                extra: meetingCaptureAnalyticsProperties(snapshot: pipelineSnapshot).merging(
                    ["trigger": trigger.rawValue],
                    uniquingKeysWith: { _, new in new }
                )
            )
        )
        AnalyticsReporter.track(
            "meeting_recording_started",
            properties: meetingCaptureAnalyticsProperties(snapshot: pipelineSnapshot).merging(
                [
                    "trigger": trigger.rawValue,
                    // #1768: a chosen mic-only meeting is not a call-audio failure.
                    "mic_only_by_choice": activeRecordingIsMicOnlyByChoice ? "true" : "false",
                    "system_permission_check": lastSystemAudioPermissionCheck,
                    // #1773: were the models already loaded when capture began?
                    "models_warm": meetingModelsWarmAtStart ? "true" : "false",
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        return true
    }

    /// Stop capture and queue the finished meeting for background transcription.
    /// Returns once the finished audio has either started transcribing or been
    /// placed behind the current background task.
    func stopRecording(reason: StopReason = .unknown) async {
        guard case .recording = state else { return }
        transition(to: .stoppingRecording, reason: "stop_requested")
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "stop_requested")
        let recordingSnapshot = makeRecordingStopSnapshot()
        _ = audioInactivityDetector.stopRecording()
        audioInactivityWarning = nil
        isMicBoostPromptVisible = false
        audioRouteWarning = nil
        clearActiveRecordingIdentity()

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_stop_requested",
            message: "Meeting stop requested",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(recordingSnapshot.durationMilliseconds)"
                ]
            )
        )

        let stopTimeoutFailedTaskId = UUID()
        let stopResult = await capture.stopAndAwaitFiles(
            timedOutOwner: .failedMeeting(stopTimeoutFailedTaskId)
        ) { [weak self] lateResult in
            self?.failedMeetingStore.refreshTimedOutFailedMeetingAudio(
                id: stopTimeoutFailedTaskId,
                result: lateResult
            )
        }
        // Read before any further suspension while this session still owns
        // the stopping state. Core retains this attempt's drained-tail signal;
        // a successor recording must not supply evidence for its predecessor.
        let stopEvidence = MeetingCaptureHealthEvidence.make(capture: capture)
        let observedSystemSignal = recordingSnapshot.healthInfo.systemAudioSignalVerified == true
            || stopEvidence.systemAudioSignalVerified
        let finalizedSystemSignalVerified = recordingSnapshot.systemSignalEvidence(observed: observedSystemSignal)
        let systemAudioFinalizationFailed = stopEvidence.systemAudioFinalizationFailed
        await capture.flushSharedDictationMicHandler()
        clearSharedDictationMicRelay()
        await sttRouter.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded()
        // "Record Just My Mic" never builds the system tap. Stand in the silent
        // track the old always-on tap left, so speaker review, re-transcribe
        // and retries still see a two-track meeting.
        var stopSystemURL = stopResult.systemURL
        if recordingSnapshot.skippedSystemAudioTap,
           stopSystemURL == nil,
           !stopResult.didTimeOut,
           let micURL = stopResult.micURL {
            stopSystemURL = await capture.writeSilentSystemTrack(matching: micURL)
        }
        let files = (micURL: stopResult.micURL, systemURL: stopSystemURL)
        // Telemetry's system_file_present / system_stream_present below read
        // `stopResult.systemURL`: the stand-in track is not captured audio.
        // With or without that track, a mic file is everything the user asked
        // for: not a partial capture, and saved with a "Mic only" marker.
        let systemAudioSkippedByChoice = recordingSnapshot.skippedSystemAudioTap
            && files.micURL != nil
        let rawCaptureOutcome = CaptureOutcome(
            micURL: files.micURL,
            systemURL: files.systemURL,
            didTimeOut: stopResult.didTimeOut
        )
        let captureOutcome = systemAudioSkippedByChoice && !stopResult.didTimeOut
            ? CaptureOutcome.micOnlyByChoice.rawValue
            : MeetingCaptureHealthTelemetry.finalizedOutcome(
                rawCaptureOutcome.rawValue,
                recordingSnapshot.systemSignalEvidence(observed: observedSystemSignal, forTelemetry: true)
            )
        let afterStopVolumeContext = capture.routeVolumeDiagnosticsContext(currentPhase: "after")
        var stopCaptureDiagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            liveAttenuationCueObserved: capture.micAttenuationCueObserved,
            baseContext: meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot, telemetryIdentity: recordingSnapshot.telemetryIdentity),
            afterStopContext: afterStopVolumeContext
        )
        // Read the prompt outcome before any state mutations below; it is only
        // reset at the NEXT recording start, so the value is stable through stop.
        let micAttenuatedByCallApp = MeetingCaptureVolumeDiagnostics.isVoiceProcessedUnrecovered(in: stopCaptureDiagnostics)
        let micBoostOutcome = micBoostPromptOutcomeForSavedCapture()
        stopCaptureDiagnostics["mic_boost_prompt"] = micBoostOutcome.rawValue
        var finalizedHealthInfo = recordingSnapshot.healthInfo
        if systemAudioSkippedByChoice {
            finalizedHealthInfo = finalizedHealthInfo.markingSystemAudioSkippedByChoice()
        }
        if let finalizedSystemSignalVerified {
            finalizedHealthInfo = finalizedHealthInfo.markingSystemAudioSignalVerified(finalizedSystemSignalVerified)
        }
        if systemAudioFinalizationFailed {
            finalizedHealthInfo = finalizedHealthInfo.markingSystemAudioDegraded()
        }
        if micAttenuatedByCallApp {
            finalizedHealthInfo = finalizedHealthInfo.markingMicAttenuatedByCallApp(
                micBoostPrompt: micBoostOutcome.rawValue
            )
        }
        if files.systemURL == nil {
            finalizedHealthInfo = finalizedHealthInfo.markingSystemAudioMissing()
        }
        if files.micURL == nil, files.systemURL != nil {
            finalizedHealthInfo = finalizedHealthInfo.markingMicrophoneAudioUnusable()
        }
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
        activeRecordingStartedAt = nil
        // Stay in `.stoppingRecording` until timeout / missing-files / enqueue
        // decides the outcome. Moving to `.transcribing` here used to hide a
        // failed stop behind a saving state the user could not recover from.
        let stopDiagnosticsContext = stopCaptureDiagnostics.merging(
            [
                "trigger": recordingSnapshot.trigger.rawValue,
                "reason": reason.rawValue,
                "duration_ms": "\(recordingSnapshot.durationMilliseconds)",
                "mic_file_present": boolString(files.micURL != nil),
                "system_file_present": boolString(stopResult.systemURL != nil),
                "stop_timed_out": boolString(stopResult.didTimeOut),
                "capture_outcome": captureOutcome,
                "capture_quality": finalizedHealthInfo.captureQuality.rawValue,
                "quality_reason": finalizedHealthInfo.qualityReason.rawValue,
                "audio_gaps": "\(finalizedHealthInfo.audioGaps)",
                "device_switches": "\(finalizedHealthInfo.deviceSwitches)"
            ],
            uniquingKeysWith: { _, new in new }
        )

        DiagnosticsTrail.record(
            level: recordingSnapshot.systemAudioStatus.isWarning
                || (files.systemURL == nil && !systemAudioSkippedByChoice)
                || files.micURL == nil ? .warning : .info,
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: baseDiagnosticsContext(extra: stopDiagnosticsContext)
        )
        AnalyticsReporter.track(
            "meeting_recording_stopped",
            properties: stopCaptureDiagnostics.merging(
                [
                    "capture_quality": finalizedHealthInfo.captureQuality.rawValue,
                    "capture_outcome": captureOutcome,
                    "quality_reason": finalizedHealthInfo.qualityReason.rawValue,
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingSnapshot.durationSeconds),
                    "gap_count_bucket": AnalyticsReporter.countBucket(finalizedHealthInfo.audioGaps),
                    "reason": reason.rawValue,
                    "route_change_count_bucket": AnalyticsReporter.countBucket(finalizedHealthInfo.deviceSwitches),
                    "system_stream_present": boolString(stopResult.systemURL != nil),
                    "stop_timed_out": boolString(stopResult.didTimeOut),
                    "trigger": recordingSnapshot.trigger.rawValue,
                ],
                uniquingKeysWith: { _, new in new }
            ),
            usageDurationSeconds: recordingSnapshot.durationSeconds
        )
        var healthSnapshotProperties = MeetingCaptureHealthTelemetry.snapshotProperties(
                .init(
                    captureDiagnostics: stopCaptureDiagnostics,
                    health: captureHealthFacts(from: finalizedHealthInfo),
                    trigger: recordingSnapshot.trigger.rawValue,
                    reason: reason.rawValue,
                    durationSeconds: recordingSnapshot.durationSeconds,
                    systemStreamPresent: stopResult.systemURL != nil,
                    stopTimedOut: stopResult.didTimeOut
                )
            )
        healthSnapshotProperties["capture_outcome"] = captureOutcome
        AnalyticsReporter.track(
            "meeting_capture_health_snapshot",
            properties: healthSnapshotProperties
        )
        // Every timed-out stop keeps the preallocated task ID used by its late
        // completion callback. Handle this before partial-source recovery so an
        // initially absent mic URL cannot create an unrelated failed row.
        // Timeout and no-audio are the canonical Sentry issues; degraded
        // capture is reported only when some audio survived (one issue a stop).
        let terminal = MeetingStopSequence.stopTerminal(stopResult: stopResult, files: files, onTimeout: {
            Self.runtimeDiagnosticsRecorder?.recordStall(
                kind: "meeting",
                stage: "recording_stop_timeout",
                durationSeconds: recordingSnapshot.durationSeconds,
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue
                ]
            )
            let preserved = failedMeetingStore.preserveTimedOutFailedMeetingForRetry(
                taskId: stopTimeoutFailedTaskId,
                micAudioURL: files.micURL,
                systemAudioURL: files.systemURL,
                errorMessage: "Recording stop timed out before audio files were finalized.",
                meetingTitle: recordingSnapshot.suggestedTitle,
                recordingDate: recordingSnapshot.recordingStartedAt,
                splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
                languageSelection: recordingSnapshot.languageSelection,
                micOnlyByChoice: recordingSnapshot.skippedSystemAudioTap
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_recording_stop_timeout_failed",
                message: "Meeting routed to failed queue due to stop timeout",
                context: baseDiagnosticsContext(
                    extra: [
                        "capture_outcome": captureOutcome,
                        "reason": reason.rawValue,
                        "preserved_for_retry": boolString(preserved)
                    ]
                )
            )
            transition(to: .error("Recording didn't close cleanly. Open the Meetings page to retry."), reason: "stop_timeout")
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "stop_timeout")
            trackDetectedPromptOutcome(
                .transcriptFailed,
                elapsedSeconds: activeDetectedPromptRecordingStartedAt.map { Date().timeIntervalSince($0) },
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
            clearDetectedPromptRecordingTelemetry()
        }, onNoAudio: {
            let preserved = failedMeetingStore.preserveFailedMeetingForRetry(
                micAudioURL: files.micURL,
                systemAudioURL: files.systemURL,
                errorMessage: "No meeting audio was captured.",
                meetingTitle: recordingSnapshot.suggestedTitle,
                recordingDate: recordingSnapshot.recordingStartedAt,
                splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
                languageSelection: recordingSnapshot.languageSelection
            )
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_recording_missing_audio",
                message: "Meeting recording stopped without any audio files",
                context: baseDiagnosticsContext(
                    extra: [
                        "capture_outcome": captureOutcome,
                        "reason": reason.rawValue,
                        "system_file_present": boolString(false),
                        "preserved_for_retry": boolString(preserved)
                    ]
                )
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(
                kind: "meeting",
                outcome: "no_audio_captured"
            )
            transition(to: .error("No meeting audio was captured."), reason: "stop_missing_audio")
        }, report: {
            reportCaptureHealthIfNeeded(
                snapshot: recordingSnapshot.pipelineSnapshot,
                captureDiagnostics: stopCaptureDiagnostics,
                healthInfo: finalizedHealthInfo,
                trigger: recordingSnapshot.trigger,
                reason: reason,
                durationSeconds: recordingSnapshot.durationSeconds,
                files: files,
                stopTimedOut: stopResult.didTimeOut
            )
        })
        guard terminal == .continueToTranscription else { return }

        if files.micURL == nil {
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_recording_missing_mic_audio_system_only",
                message: "Meeting recording will continue through the system-audio-only recovery pipeline",
                context: baseDiagnosticsContext(
                    extra: [
                        "capture_outcome": captureOutcome,
                        "reason": reason.rawValue,
                        "system_file_present": boolString(true),
                        "partial_output": boolString(true)
                    ]
                )
            )
        }

        if files.systemURL == nil, !systemAudioSkippedByChoice {
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_recording_missing_system_audio_mic_only",
                message: "Meeting recording will continue through the mic-only recovery pipeline",
                context: baseDiagnosticsContext(
                    extra: [
                        "capture_outcome": captureOutcome,
                        "reason": reason.rawValue,
                        "mic_file_present": boolString(true),
                        "partial_output": boolString(true)
                    ]
                )
            )
        }

        let outcome = transcriptionQueue.enqueueTranscriptionJob(
            micURL: files.micURL,
            systemURL: files.systemURL,
            healthInfo: finalizedHealthInfo,
            captureDiagnostics: stopCaptureDiagnostics,
            meetingTitle: recordingSnapshot.suggestedTitle,
            recordingDate: recordingSnapshot.recordingStartedAt ?? Date(),
            startTrigger: recordingSnapshot.trigger,
            languageSelection: recordingSnapshot.languageSelection,
            sttModel: recordingSnapshot.sttModel,
            promptTelemetryProperties: recordingSnapshot.trigger == .detectedPrompt
                ? activeDetectedPromptRecordingTelemetryProperties
                : nil,
            promptRecordingStartedAt: recordingSnapshot.trigger == .detectedPrompt
                ? activeDetectedPromptRecordingStartedAt
                : nil,
            sessionLength: Self.recordingSessionLength(
                timerSeconds: recordingSnapshot.durationSeconds,
                startedAt: recordingSnapshot.recordingStartedAt
            )
        )
        clearDetectedPromptRecordingTelemetry()
        transition(to: .transcribing, reason: "stop_completed")
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")

        let queueDepth = transcriptionQueue.queuedTranscriptionJobs.count
        DiagnosticsTrail.record(
            engine: "meeting",
            event: outcome == .startedImmediately ? "meeting_transcription_started" : "meeting_transcription_queued",
            message: outcome == .startedImmediately
                ? "Meeting transcription started"
                : "Meeting queued behind an earlier transcription",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(recordingSnapshot.durationMilliseconds)",
                    "queue_depth": "\(queueDepth)"
                ]
            )
        )
    }

    func handleUnexpectedCaptureStop(_ stopResult: CaptureStopResult) async {
        // `state` alone now distinguishes this from an app-initiated stop:
        // stopRecording()/cancelRecording()/prepareForTermination() move
        // state to .stoppingRecording before capture ever tears down, so by
        // the time capture reports an unexpected completion, state is only
        // ever still .recording when nothing else asked for the stop.
        // Leaves `.recording` before any await so stop/cancel can't interleave.
        let handled = await MeetingStopSequence.unexpectedStop(
            state: state,
            transition: { transition(to: $0, reason: $1) },
            quietLiveWarnings: {
                _ = audioInactivityDetector.stopRecording()
                audioInactivityWarning = nil
                isMicBoostPromptVisible = false
            },
            capture: capture,
            clearRelay: { clearSharedDictationMicRelay() },
            resumeDictation: { await sttRouter.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded() }
        )
        guard handled else { return }

        let recordingSnapshot = makeRecordingStopSnapshot()
        let snapshotTakenAt = Date()
        unexpectedCaptureStopEvidence = nil
        let files = (micURL: stopResult.micURL, systemURL: stopResult.systemURL)
        let failureMessage = capture.errorMessage
            ?? "Recording stopped unexpectedly. Open the Meetings page to retry the saved audio."

        clearActiveRecordingIdentity()
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
        activeRecordingStartedAt = nil

        let preserved = await archiveUnexpectedStoppedRecording(
            files: files, failureMessage: failureMessage, snapshot: recordingSnapshot
        )

        let failureOutcome = CaptureOutcome(micURL: files.micURL, systemURL: files.systemURL, didTimeOut: stopResult.didTimeOut)
        let failureContext = TelemetryContext.enrich(event: "meeting_capture_stopped_under_controller", properties:
            meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot, telemetryIdentity: recordingSnapshot.telemetryIdentity).merging([
                "failure_kind": files.micURL == nil && files.systemURL == nil ? "no_audio" : "unexpected_capture_stop",
                "failure_stage": "capture_stop", "capture_outcome": failureOutcome.rawValue,
                "trigger": recordingSnapshot.trigger.rawValue,
            ], uniquingKeysWith: { _, new in new }), isFailure: true)
        DiagnosticsTrail.record(
            level: .error,
            engine: "meeting",
            event: "meeting_capture_stopped_under_controller",
            message: "Meeting capture stopped before the app stop path ran",
            context: baseDiagnosticsContext(
                extra: failureContext.merging([
                    "mic_file_present": boolString(files.micURL != nil),
                    "system_file_present": boolString(files.systemURL != nil),
                    "preserved_for_retry": boolString(preserved),
                    "capture_quality": recordingSnapshot.healthInfo.captureQuality.rawValue,
                    "quality_reason": recordingSnapshot.healthInfo.qualityReason.rawValue,
                    "audio_gaps": "\(recordingSnapshot.healthInfo.audioGaps)",
                    "device_switches": "\(recordingSnapshot.healthInfo.deviceSwitches)"
                ], uniquingKeysWith: { _, new in new })
            )
        )

        let healthProperties = MeetingCaptureHealthTelemetry.snapshotProperties(
                .init(
                    captureDiagnostics: failureContext,
                    health: captureHealthFacts(from: recordingSnapshot.healthInfo),
                    trigger: recordingSnapshot.trigger.rawValue,
                    reason: "internal_stop",
                    durationSeconds: MeetingCaptureHealthTelemetry.unexpectedStopDurationSeconds(
                        mirroredDuration: recordingSnapshot.durationSeconds,
                        recordingStartedAt: recordingSnapshot.recordingStartedAt,
                        now: snapshotTakenAt
                    ),
                    systemStreamPresent: files.systemURL != nil,
                    stopTimedOut: stopResult.didTimeOut,
                    captureOutcome: failureOutcome.rawValue
                )
            )
        AnalyticsReporter.track("meeting_capture_stopped_under_controller", properties: healthProperties)
        AnalyticsReporter.track("meeting_capture_health_snapshot", properties: healthProperties)

    }

    // preserveQueuedTranscriptionJobsForShutdown moved to
    // TranscriptionQueueCoordinator.swift (audit 2026-07-08 wave 2, W2-B).

    func makeRecordingStopSnapshot() -> RecordingStopSnapshot {
        let evidence = MeetingCaptureHealthTelemetry.stopSnapshotEvidence(
            liveStatus: capture.systemAudioStatus,
            unknown: .unknown,
            liveWarning: systemAudioDegradationWarning,
            liveUnheardWarningStartedAt: unheardPlaybackWarningStartedAt,
            atCaptureStop: unexpectedCaptureStopEvidence,
            now: Date()
        )
        let systemAudioStatus = evidence.systemAudioStatus
        let durationSeconds = recordingDuration
        var baseHealthInfo = capture.healthInfo(overrideSystemAudioStatus: systemAudioStatus)
        let accessConfirmedByMacOS = systemAudioAccessConfirmedAtStop()
        if let signalEvidence = MeetingMicOnlyRecordingPolicy.systemAudioSignalEvidence(
            observed: capture.hasObservedSystemAudioSignal, micOnlyByChoice: activeRecordingIsMicOnlyByChoice,
            accessConfirmedByMacOS: accessConfirmedByMacOS
        ) {
            baseHealthInfo = baseHealthInfo.markingSystemAudioSignalVerified(signalEvidence)
        }
        // Only an interruption or failure warning latches degraded metadata.
        // A silence warning is legitimate (the remote side went quiet, or the
        // call ended before Stop was pressed) and used to stamp most saved
        // meetings degraded even when system audio finished healthy.
        let healthInfo: RecordingHealthInfo
        if MeetingSystemAudioDegradationPolicy.degradesSavedCaptureAtStop(
            evidence.degradationWarning,
            didLosePlayback: capture.systemAudioDidLosePlayback,
            unheardSeconds: evidence.unheardSeconds
        ) {
            healthInfo = baseHealthInfo.markingSystemAudioDegraded()
        } else {
            healthInfo = baseHealthInfo
        }
        return RecordingStopSnapshot(
            telemetryIdentity: activeRecordingIdentity,
            trigger: activeRecordingTrigger,
            systemAudioStatus: systemAudioStatus,
            durationSeconds: durationSeconds,
            healthInfo: healthInfo,
            pipelineSnapshot: capture.pipelineDiagnosticsSnapshot(
                overrideSystemAudioStatus: systemAudioStatus
            ),
            suggestedTitle: activeRecordingSuggestedTitle,
            recordingStartedAt: activeRecordingStartedAt,
            languageSelection: recordingLanguageSelection,
            sttModel: recordingSTTModel,
            isMicOnlyByChoice: activeRecordingIsMicOnlyByChoice,
            skippedSystemAudioTap: !capture.currentRecordingCapturesSystemAudio,
            systemAudioAccessConfirmedByMacOS: accessConfirmedByMacOS
        )
    }

    /// Snapshot capture health before the stop call, since the system-audio
    /// backend can clean up buffer counters before file-close completion resumes.
    func refreshSystemAudioSignalVerification(shouldWarn: Bool) {
        // Mic-only was the user's call at start; system-audio banners would
        // only repeat what they already chose.
        if activeRecordingIsMicOnlyByChoice {
            if systemAudioDegradationWarning != nil { systemAudioDegradationWarning = nil }
            return
        }
        let signalVerified = MeetingCaptureHealthEvidence.make(capture: capture).systemAudioSignalVerified
        let verified = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: systemAudioDegradationWarning,
            signalVerified: signalVerified,
            shouldWarn: shouldWarn && !signalVerified && !systemAudioAccessConfirmedByMacOS(),
            isRecording: state == .recording
        )
        let updated = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: verified,
            notHearingPlayback: capture.systemAudioNotHearingPlayback,
            playbackLossConfirmed: capture.systemAudioDidLosePlayback,
            isRecording: state == .recording
        )
        if updated != systemAudioDegradationWarning {
            let isUnheard = updated?.cause == .unheardPlayback && updated?.phase != .recovered
            let wasUnheard = systemAudioDegradationWarning?.cause == .unheardPlayback
                && systemAudioDegradationWarning?.phase != .recovered
            if isUnheard, !wasUnheard {
                // The report comes after about a minute of hearing nothing.
                unheardPlaybackWarningStartedAt = Date().addingTimeInterval(-MeetingCaptureBridge.systemAudioUnheardReportSeconds)
                recordUnheardPlaybackWarning()
            } else if !isUnheard {
                unheardPlaybackWarningStartedAt = nil
            }
            systemAudioDegradationWarning = updated
        }
    }
}
