// MeetingSessionController+MicBoost.swift
// The in-meeting Boost Mic prompt: attenuation cue, present, accept/decline,
// arm result, stale-action guard, and the saved outcome.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    func handleMicAttenuationCue() {
        guard case .recording = state,
              let activeRecordingIdentity else { return }
        // A call app launched during this meeting is probably joining a call.
        guard shouldPresentMicBoostPrompt(
            microphoneSharingRequired: capture.callAppLaunchedDuringRecording
        ) else { return }
        guard capture.audio.voiceProcessingSuppressedForMicrophoneSharing else {
            presentMicBoostPrompt(for: activeRecordingIdentity)
            return
        }
        // A call app was open at start. Only one that is actually on the mic
        // takes Boost away; Teams left open during a browser call does not.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let callAppOnMic = await self.capture.callAppIsUsingMicrophone()
            guard case .recording = self.state,
                  self.activeRecordingIdentity == activeRecordingIdentity,
                  self.shouldPresentMicBoostPrompt(
                      microphoneSharingRequired: callAppOnMic || self.capture.callAppLaunchedDuringRecording
                  ) else { return }
            self.presentMicBoostPrompt(for: activeRecordingIdentity)
        }
    }

    private func shouldPresentMicBoostPrompt(microphoneSharingRequired: Bool) -> Bool {
        // What this meeting actually runs, not the saved mode: a Home "Boost
        // mic next meeting" already boosted it, while a Settings choice that
        // an open call app overrode at start did not.
        let meetingHasVoiceProcessing = capture.audio.enableVoiceProcessing
            && !capture.audio.voiceProcessingSuppressedForMicrophoneSharing
        return MeetingMicBoostPromptPolicy.shouldPresent(
            isRecording: isRecording,
            voiceProcessingPreferenceEnabled: meetingHasVoiceProcessing,
            currentOutcome: micBoostPromptOutcome,
            microphoneSharingRequired: microphoneSharingRequired,
            recordsThroughPinnedMicrophone: capture.audio.isRecordingThroughPinnedMicrophone
        )
    }

    private func presentMicBoostPrompt(for activeRecordingIdentity: UUID) {
        micBoostPromptOutcome = .shown
        micBoostPromptRecordingIdentity = activeRecordingIdentity
        isMicBoostPromptVisible = true
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_mic_boost_prompt_shown",
            message: "Mic attenuated by another app's voice processing; offering boost",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_mic_boost_prompt_shown",
            properties: [
                "trigger": activeRecordingTrigger.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
            ]
        )
    }

    func acceptMicBoostPrompt() {
        guard shouldApplyMicBoostPromptAction() else {
            clearStaleMicBoostPrompt()
            return
        }
        micBoostPromptOutcome = .accepted
        isMicBoostPromptVisible = false
        micBoostPromptRecordingIdentity = nil
        let boostedRecordingIdentity = activeRecordingIdentity
        micBoostArmPendingIdentity = boostedRecordingIdentity
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.capture.armVoiceProcessingForActiveRecording()
            self.handleMicBoostArmResult(result, recordingIdentity: boostedRecordingIdentity)
        }
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_mic_boost_prompt_actioned",
            message: "Mic boost prompt accepted; arming VPIO mid-recording",
            context: baseDiagnosticsContext(
                extra: [
                    "action": "accepted",
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_mic_boost_prompt_actioned",
            properties: [
                "action": "accepted",
                "trigger": activeRecordingTrigger.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
            ]
        )
    }

    /// An accepted Boost still waiting to arm when the meeting ended never
    /// applied, since stop ends the arm's retries.
    func micBoostPromptOutcomeForSavedCapture() -> MeetingMicBoostPromptOutcome {
        if micBoostPromptOutcome == .accepted, micBoostArmPendingIdentity != nil { return .shown }
        return micBoostPromptOutcome
    }

    /// A Boost that never applied (a call app is on the mic, or the mic kept
    /// recovering) must not be saved as accepted: the Home row would hide its
    /// "Boost mic next meeting" hint for a meeting that was never boosted.
    private func handleMicBoostArmResult(
        _ result: MeetingCaptureBridge.MicBoostArmResult,
        recordingIdentity: UUID?
    ) {
        guard let recordingIdentity, micBoostArmPendingIdentity == recordingIdentity else { return }
        micBoostArmPendingIdentity = nil
        guard result != .armed, micBoostPromptOutcome == .accepted else { return }
        micBoostPromptOutcome = .shown
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_mic_boost_not_applied",
            message: "Mic boost was accepted but could not be applied to this recording",
            context: baseDiagnosticsContext(
                extra: [
                    "reason": result.rawValue,
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
    }

    func declineMicBoostPrompt() {
        guard shouldApplyMicBoostPromptAction() else {
            clearStaleMicBoostPrompt()
            return
        }
        micBoostPromptOutcome = .declined
        isMicBoostPromptVisible = false
        micBoostPromptRecordingIdentity = nil
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_mic_boost_prompt_actioned",
            message: "Mic boost prompt declined",
            context: baseDiagnosticsContext(
                extra: [
                    "action": "declined",
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_mic_boost_prompt_actioned",
            properties: [
                "action": "declined",
                "trigger": activeRecordingTrigger.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
            ]
        )
    }

    private func shouldApplyMicBoostPromptAction() -> Bool {
        guard case .recording = state,
              let activeRecordingIdentity,
              let micBoostPromptRecordingIdentity,
              micBoostPromptRecordingIdentity == activeRecordingIdentity else {
            return false
        }
        // A call app launched after the prompt appeared is probably joining a
        // call, so a stale accept must not undo its latch. One that was only
        // open at start is checked when the boost applies: the bridge
        // refuses it only while a call app is actually on the mic.
        return MeetingMicBoostPromptPolicy.shouldApplyPromptAction(
            isPromptVisible: isMicBoostPromptVisible,
            isRecording: isRecording,
            microphoneSharingRequired: capture.callAppLaunchedDuringRecording,
            recordsThroughPinnedMicrophone: capture.audio.isRecordingThroughPinnedMicrophone
        )
    }

    private func clearStaleMicBoostPrompt() {
        isMicBoostPromptVisible = false
        micBoostPromptRecordingIdentity = nil
    }
}
