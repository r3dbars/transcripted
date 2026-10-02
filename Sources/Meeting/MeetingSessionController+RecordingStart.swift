// MeetingSessionController+RecordingStart.swift
// Start helpers: the shared-dictation mic relay, the start permission decision,
// the system-audio access ask, and background model catch-up at start.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    func installSharedDictationMicRelay() {
        let dictationEngine = sttRouter.parakeetEngine
        capture.setSharedDictationMicHandler { [weak dictationEngine] buffer in
            dictationEngine?.appendSharedMeetingMicBuffer(buffer)
        }
    }

    func clearSharedDictationMicRelay() {
        capture.setSharedDictationMicHandler(nil)
    }

    func resolveStartRecordingPermissionDecision(
        trigger: StartTrigger
    ) async -> MeetingRecordingStartDecision {
        let microphoneGranted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded()
        var systemAudioRecordingGranted = TranscriptedPermissionAccess.isGranted(.systemAudioRecording)
        var startDecision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: microphoneGranted,
            systemAudioRecordingGranted: systemAudioRecordingGranted
        )
        let shouldRevalidateCachedSystemAudioPermission = microphoneGranted && systemAudioRecordingGranted
        let shouldRequestMissingSystemAudioPermission =
            microphoneGranted &&
            !startDecision.canStart &&
            startDecision.failureReason == "system_audio_recording"

        lastSystemAudioPermissionCheck = "none"
        guard shouldRevalidateCachedSystemAudioPermission || shouldRequestMissingSystemAudioPermission else {
            return startDecision
        }

        if let askedDecision = await resolveSystemAudioAccessFromSystem(trigger: trigger) {
            lastSystemAudioPermissionCheck = "system"
            return askedDecision
        }
        lastSystemAudioPermissionCheck = "probe"

        let permissionCheckMode = shouldRevalidateCachedSystemAudioPermission ? "revalidation" : "request"
        DiagnosticsTrail.record(
            engine: "meeting",
            event: shouldRevalidateCachedSystemAudioPermission
                ? "meeting_start_revalidating_system_audio_permission"
                : "meeting_start_requesting_system_audio_permission",
            message: shouldRevalidateCachedSystemAudioPermission
                ? "Meeting start is revalidating cached system audio permission"
                : "Meeting start is requesting system audio permission",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "permission_check": permissionCheckMode
                ]
            )
        )

        let systemAudioAccess = await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
            forceRefresh: shouldRevalidateCachedSystemAudioPermission
        )
        systemAudioRecordingGranted = systemAudioAccess.canProceed
        if !systemAudioAccess.canProceed,
           systemAudioAccess.probeResult?.isIndeterminate == true {
            startDecision = MeetingRecordingStartGate.systemAudioVerificationUnavailable()
        } else {
            startDecision = MeetingRecordingStartGate.evaluate(
                microphoneGranted: microphoneGranted,
                systemAudioRecordingGranted: systemAudioRecordingGranted
            )
            if systemAudioAccess.probeResult?.isIndeterminate == true {
                startDecision = startDecision.markingSystemAudioPermissionCheckInconclusive()
            }
        }

        let permissionProbeResult = systemAudioAccess.probeResult?.diagnosticName ?? "cached_grant"
        let permissionEvent: String
        let permissionMessage: String
        let permissionLevel: EventLevel
        if systemAudioAccess.probeResult?.isIndeterminate == true {
            permissionEvent = systemAudioRecordingGranted
                ? "meeting_start_system_audio_permission_check_inconclusive_continued"
                : "meeting_start_system_audio_permission_check_inconclusive"
            permissionMessage = systemAudioRecordingGranted
                ? "System audio permission check was inconclusive; continuing with unverified access"
                : "System audio permission check was inconclusive without a previously verified grant"
            permissionLevel = .warning
        } else {
            permissionEvent = systemAudioRecordingGranted
                ? "meeting_start_system_audio_permission_granted"
                : "meeting_start_system_audio_permission_missing"
            permissionMessage = systemAudioRecordingGranted
                ? "System audio permission is ready for meeting capture"
                : "System audio permission is still missing for meeting capture"
            permissionLevel = systemAudioRecordingGranted ? .info : .warning
        }

        DiagnosticsTrail.record(
            level: permissionLevel,
            engine: "meeting",
            event: permissionEvent,
            message: permissionMessage,
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "permission_check": permissionCheckMode,
                    "permission_probe_result": permissionProbeResult,
                ]
            )
        )

        return startDecision
    }

    /// Uses macOS's own recorded answer instead of the tap probe, which can't
    /// tell a denial from a quiet Mac. Allowed starts at once; not allowed
    /// asks the user first. Nil = macOS's answer is unavailable, so the
    /// caller falls back to the probe.
    private func resolveSystemAudioAccessFromSystem(
        trigger: StartTrigger
    ) async -> MeetingRecordingStartDecision? {
        let systemStatus = TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
        let outcome: MeetingSystemAudioAccessFlow.Outcome
        switch systemStatus {
        case .unavailable:
            return nil
        case .authorized:
            outcome = .recordBothSides
        case .denied, .notDetermined:
            outcome = await MeetingSystemAudioAccessFlow.resolve(
                isUndetermined: systemStatus == .notDetermined,
                rememberedMicOnly: systemStatus == .denied && MeetingMicOnlyChoicePreference.isRemembered(),
                remembersMicOnly: !systemAudioAccessAsksWhileRecording(),
                ask: systemAudioAccessPrompter,
                requestAccess: { await TranscriptedPermissionAccess.requestSystemAudioCaptureAccess() },
                openSettings: { TranscriptedPermissionAccess.openSystemAudioRecordingSettings() }
            )
        }
        MeetingMicOnlyChoicePreference.reconcile(isDenied: systemStatus == .denied, outcome: outcome)
        // Raised from the outcome, not from inside the prompter, so a
        // first-time macOS Don't Allow asks too. One ask per meeting.
        callAudioAsk.accessResolved(outcome)
        // The status after any macOS box, so logs show the answer, not just
        // the state before the question.
        let systemStatusAfter = systemStatus == .authorized
            ? systemStatus
            : TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
        if systemStatus != .authorized {
            // What people pick on "can't hear the other side of the call",
            // and what macOS says once they have.
            AnalyticsReporter.track(
                "meeting_system_audio_prompt_answered",
                properties: [
                    "outcome": outcome.rawValue,
                    "tcc_status": systemStatus.rawValue,
                    "tcc_status_after": systemStatusAfter.rawValue,
                    "trigger": trigger.rawValue,
                ]
            )
        }

        DiagnosticsTrail.record(
            level: outcome == .recordBothSides ? .info : .warning,
            engine: "meeting",
            event: outcome == .recordBothSides
                ? "meeting_start_system_audio_permission_granted"
                : "meeting_start_system_audio_permission_asked",
            message: outcome == .recordBothSides
                ? "System audio permission is ready for meeting capture"
                : "Asked before starting because macOS says system audio is off",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "permission_check": "system",
                    "permission_tcc_status": systemStatus.rawValue,
                    "permission_tcc_status_after": systemStatusAfter.rawValue,
                    "permission_prompt_outcome": outcome.rawValue,
                ]
            )
        )
        return outcome.startDecision
    }

    /// Capture never waits on model loading. Meeting audio is transcribed
    /// after Stop, and the transcription queue loads (and retries) the models
    /// itself before it runs, so a meeting started while the models are still
    /// warming records right away and they finish loading in the background.
    /// Normally the launch warmup has already loaded them and this is a no-op.
    func catchUpModelsInBackgroundIfNeeded(trigger: StartTrigger) {
        switch state {
        case .idle, .loadingModels, .ready, .error:
            break
        case .transcribing, .recording, .startingRecording, .stoppingRecording:
            // The queue owns model preparation while it is transcribing, and
            // startRecording()'s entry switch already rejects capture states.
            return
        }
        guard !areMeetingModelsWarm else { return }

        // Release a model prepared for a previous selection now, while capture
        // is not live yet; prepareModels() defers that reset during capture.
        resetPreparedSpeechModelIfNeeded()
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_start_models_catching_up",
            message: "Meeting started while models were still loading; they finish in the background",
            context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
        )
        Task { @MainActor [weak self] in
            await self?.prepareModels(showLoadingUI: false)
        }
    }
}
