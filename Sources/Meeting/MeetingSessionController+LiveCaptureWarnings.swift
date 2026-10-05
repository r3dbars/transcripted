// MeetingSessionController+LiveCaptureWarnings.swift
// Live recording warnings: audio inactivity, the Bluetooth route warning,
// system-audio degradation and unheard playback, the mic-only note and its
// access recheck, Check Access, and the call-audio ask dismissal.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    /// The island's call-audio ask was answered or dismissed.
    func dismissCallAudioAsk() {
        callAudioAsk.dismissed()
    }

    func dismissAudioInactivityWarning() {
        guard audioInactivityWarning != nil else { return }
        applyAudioInactivityEvent(audioInactivityDetector.dismissWarning())
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_audio_inactivity_warning_dismissed",
            message: "Meeting audio inactivity warning dismissed",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
    }

    /// `automatic` is a recovered notice hiding itself, not a user click.
    func acknowledgeSystemAudioDegradationWarning(automatic: Bool = false) {
        guard let warning = systemAudioDegradationWarning,
              warning.shouldPresentPrompt else { return }
        systemAudioDegradationWarning = warning.dismissingPrompt()
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_system_audio_warning_acknowledged",
            message: "System audio degradation warning acknowledged",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))",
                    "warning_phase": warning.phase.diagnosticName,
                    "source": automatic ? "auto" : "user"
                ]
            )
        )
    }

    func dismissAudioRouteWarning() {
        guard audioRouteWarning != nil else { return }
        audioRouteWarning = nil
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_capture_route_warning_dismissed",
            message: "Meeting Bluetooth route warning dismissed",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
    }

    func handleRouteStabilityWarning(
        _ outcome: CaptureRouteStabilizationOutcome
    ) {
        // Audio inactivity and mic-boost prompts belong to the overlay; they
        // leave the session state as .recording. The route outcome is latched
        // here and the overlay restores its priority after those prompts.
        guard case .recording = state else { return }
        guard audioRouteWarning == nil else { return }
        audioRouteWarning = outcome

        let snapshot = capture.pipelineDiagnosticsSnapshot()
        let properties = meetingCaptureAnalyticsProperties(snapshot: snapshot).merging(
            [
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
                "stabilization_outcome": outcome.rawValue,
                "trigger": activeRecordingTrigger.rawValue,
                "warning_kind": "bluetooth_route_unstable",
            ],
            uniquingKeysWith: { _, new in new }
        )
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_capture_route_warning_shown",
            message: "Meeting Bluetooth route instability detected",
            context: baseDiagnosticsContext(extra: properties)
        )
        AnalyticsReporter.track(
            "meeting_capture_route_warning_shown",
            properties: properties
        )
    }

    /// The "Mic only" note on the recording pill was clicked. Shows the macOS
    /// allow box if macOS hasn't asked yet, otherwise opens System Audio
    /// Recording in System Settings, then keeps re-reading macOS's answer so
    /// the note says so once call audio is on. This recording stays mic only
    /// either way (it never built the system-audio tap); the next one won't.
    func turnOnCallAudioFromMicOnlyNotice() async {
        guard state == .recording, micOnlyNotice == .callAudioOff, !micOnlyAccessRequestInFlight else { return }
        micOnlyAccessRequestInFlight = true
        defer { micOnlyAccessRequestInFlight = false }
        let status = TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
        let action = MeetingMicOnlyNoticePolicy.tapAction(for: status)
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_mic_only_notice_clicked",
            message: "Mic only note clicked to turn on call audio",
            context: baseDiagnosticsContext(
                extra: [
                    "permission_tcc_status": status.rawValue,
                    "mic_only_notice_action": Self.micOnlyNoticeActionName(action),
                ]
            )
        )
        switch action {
        case .alreadyOn:
            applyMicOnlyAccessStatus(status)
        case .showMacOSBox:
            if await TranscriptedPermissionAccess.requestSystemAudioCaptureAccess() == nil,
               state == .recording {
                // macOS's request API didn't answer; Settings is the fallback.
                TranscriptedPermissionAccess.openSystemAudioRecordingSettings()
            }
            applyMicOnlyAccessStatus(TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem())
            startMicOnlyAccessRecheck()
        case .openSettings:
            TranscriptedPermissionAccess.openSystemAudioRecordingSettings()
            startMicOnlyAccessRecheck()
        }
    }

    private static func micOnlyNoticeActionName(_ action: MeetingMicOnlyNoticePolicy.TapAction) -> String {
        switch action {
        case .alreadyOn: return "already_on"
        case .showMacOSBox: return "macos_box"
        case .openSettings: return "open_settings"
        }
    }

    private func startMicOnlyAccessRecheck() {
        micOnlyAccessRecheckTask?.cancel()
        guard MeetingMicOnlyNoticePolicy.shouldKeepCheckingAccess(
            notice: micOnlyNotice,
            isRecording: state == .recording
        ) else {
            micOnlyAccessRecheckTask = nil
            return
        }
        micOnlyAccessRecheckTask = Task { @MainActor [weak self] in
            // Bounded: someone who never turns it on shouldn't be polled for
            // a whole meeting. Another click on the note starts it again.
            for _ in 0..<MeetingMicOnlyNoticePolicy.maxAccessRechecks {
                try? await Task.sleep(nanoseconds: MeetingMicOnlyNoticePolicy.accessRecheckIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                guard MeetingMicOnlyNoticePolicy.shouldKeepCheckingAccess(
                    notice: self.micOnlyNotice,
                    isRecording: self.state == .recording
                ) else { return }
                self.applyMicOnlyAccessStatus(
                    TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
                )
            }
        }
    }

    private func applyMicOnlyAccessStatus(_ status: SystemAudioCaptureTCCStatus) {
        guard state == .recording else { return }
        let updated = MeetingMicOnlyNoticePolicy.notice(current: micOnlyNotice, afterStatus: status)
        guard updated != micOnlyNotice else { return }
        micOnlyNotice = updated
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_mic_only_call_audio_turned_on",
            message: "Call audio turned on during a mic-only recording; the next meeting records both sides",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))",
                    "mic_only_notice": updated?.diagnosticName ?? "none",
                ]
            )
        )
    }

    /// Check Access on the mid-meeting "not verified" / "unavailable" system
    /// audio warning. Opens the System Audio Recording pane without starting
    /// a second capture probe: a quiet Mac, a denied tap, and a failed
    /// stream can't be told apart from here, so the permission cache is left
    /// alone and the warning keeps its latch.
    func checkSystemAudioAccessFromWarning() {
        guard let warning = systemAudioDegradationWarning,
              MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(
                for: warning,
                status: TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
              ) else { return }
        acknowledgeSystemAudioDegradationWarning()
        TranscriptedPermissionAccess.openSystemAudioRecordingSettings()
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_system_audio_check_access_clicked",
            message: "Check Access clicked on the system audio warning",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))",
                    "warning_phase": warning.phase.diagnosticName,
                ]
            )
        )
    }

    func endRecordingFromAudioInactivityPrompt(automatic: Bool) async {
        guard let warning = audioInactivityWarning else { return }
        if automatic, !warning.automaticStopAllowed {
            let diagnostics = currentAudioInactivityDiagnostics()
            applyAudioInactivityEvent(audioInactivityDetector.dismissWarning())
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_audio_inactivity_timeout_deferred",
                message: "Meeting audio inactivity auto-stop deferred because capture route looked degraded",
                context: baseDiagnosticsContext(
                    extra: diagnostics.merging(
                        [
                            "duration_ms": "\(Int(recordingDuration * 1000))",
                            "warning_kind": warning.kind.rawValue,
                            "automatic_stop_allowed": boolString(warning.automaticStopAllowed)
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
            )
            return
        }
        let reason: StopReason = automatic ? .audioInactivityTimeout : .audioInactivityPrompt

        DiagnosticsTrail.record(
            level: automatic ? .warning : .info,
            engine: "meeting",
            event: automatic ? "meeting_audio_inactivity_timeout" : "meeting_audio_inactivity_end_requested",
            message: automatic
                ? "Meeting recording ended after audio inactivity countdown"
                : "Meeting recording ended from audio inactivity prompt",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )

        await stopRecording(reason: reason)
    }

    func observeAudioActivity() {
        guard isRecording else { return }
        applyAudioInactivityEvent(
            audioInactivityDetector.observe(
                micLevel: latestMicLevel,
                systemLevel: latestSystemLevel,
                at: recordingDuration
            )
        )
    }

    private func currentAudioInactivityDiagnostics() -> [String: String] {
        let snapshot = capture.pipelineDiagnosticsSnapshot()
        return MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            liveAttenuationCueObserved: capture.micAttenuationCueObserved,
            baseContext: meetingCaptureAnalyticsProperties(snapshot: snapshot),
            afterStopContext: [:]
        )
    }

    func applyAudioInactivityEvent(_ event: MeetingAudioInactivityDetector.Event) {
        switch event {
        case .none:
            return
        case .warningStarted(let warning):
            let diagnostics = currentAudioInactivityDiagnostics()
            let presentedWarning = MeetingAudioInactivityRecoveryPolicy.warning(
                from: warning,
                durationSeconds: recordingDuration,
                diagnostics: diagnostics
            )
            audioInactivityWarning = presentedWarning
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_audio_inactivity_warning_started",
                message: "No meeting audio detected",
                context: baseDiagnosticsContext(
                    extra: diagnostics.merging(
                        [
                            "inactive_ms": "\(Int(warning.inactiveDuration * 1000))",
                            "countdown_seconds": "\(warning.countdownSeconds)",
                            "duration_ms": "\(Int(recordingDuration * 1000))",
                            "warning_kind": presentedWarning.kind.rawValue,
                            "automatic_stop_allowed": boolString(presentedWarning.automaticStopAllowed)
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
            )
        case .warningCleared:
            guard audioInactivityWarning != nil else { return }
            audioInactivityWarning = nil
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_audio_inactivity_warning_cleared",
                message: "Meeting audio inactivity warning cleared",
                context: baseDiagnosticsContext(
                    extra: [
                        "duration_ms": "\(Int(recordingDuration * 1000))"
                    ]
                )
            )
        }
    }

    /// Reads macOS's answer once per recording, only when the notice would
    /// otherwise show. Launch smoke and a missing TCC API read as not
    /// confirmed, which keeps the notice as before.
    func systemAudioAccessConfirmedByMacOS() -> Bool {
        if let confirmed = activeRecordingSystemAudioAccessConfirmed { return confirmed }
        guard state == .recording else { return false }
        let confirmed = TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem() == .authorized
        activeRecordingSystemAudioAccessConfirmed = confirmed
        return confirmed
    }

    /// The same answer for the saved file, read at stop. Only asked when no
    /// system audio was heard and the user didn't choose mic only. Not
    /// `systemAudioAccessConfirmedByMacOS()`, which only reads macOS while
    /// recording; by stop the state has moved on.
    func systemAudioAccessConfirmedAtStop() -> Bool {
        guard !capture.hasObservedSystemAudioSignal, !activeRecordingIsMicOnlyByChoice else { return false }
        return activeRecordingSystemAudioAccessConfirmed
            ?? (TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem() == .authorized)
    }

    func recordUnheardPlaybackWarning() {
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_system_audio_unheard_playback",
            message: "Another app is playing but the system audio tap hears silence",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))",
                    "signal_verified": boolString(capture.hasObservedSystemAudioSignal),
                ]
            )
        )
    }
}
