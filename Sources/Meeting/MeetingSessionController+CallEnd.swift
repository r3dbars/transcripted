import Foundation

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    /// Binds before a permission dialog can yield to another start or source.
    /// Ambiguous browser activity and camera-only detection remain manual.
    func callEndFamilies(for candidate: MeetingPromptDetector.Candidate?) -> Set<String>? {
        guard let candidate else { return nil }
        return latestCallActivity.sourceFamilies(detectedPrompt: true, provider: candidate.provider,
            isBrowserCall: candidate.isBrowserCall, cameraOnly: candidate.reason == .cameraInput,
            sampledAt: latestCallActivityAt, now: ProcessInfo.processInfo.systemUptime)
    }

    func observeCallActivity(_ snapshot: MeetingCallActivitySnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        latestCallActivity = snapshot
        latestCallActivityAt = snapshot.sampledAt
        guard isRecording, var tracking = callEndTracking,
              tracking.recordingIdentity == activeRecordingIdentity else { return }
        // The snapshot carries when the audio system was actually read, which can
        // be seconds before this delivery. A read with no usable sampling time,
        // or one that is stale or from the future, is unknown: it must never look
        // like a released stream or hold up a countdown.
        let sampledAt = snapshot.sampledAt
        let activity: MeetingEndDetectionPolicy.Activity
        if let sampledAt, sampledAt <= now, now - sampledAt <= 12 {
            activity = snapshot.activity(in: tracking.families, cameraInUse: freshCallCameraActivity(at: now))
        } else {
            activity = .unknown
        }
        let event = tracking.policy.observe(activity, sampledAt: sampledAt ?? now, at: now)
        callEndTracking = tracking
        applyCallEndEvent(event, tracking: tracking)
    }

    private func applyCallEndEvent(_ event: MeetingEndDetectionPolicy.Event,
                                   tracking: MeetingCallEndTracking) {
        switch event {
        case .none:
            break
        case .warningStarted:
            audioInactivityWarning = MeetingAudioInactivityWarning(inactiveDuration: 10,
                countdownSeconds: 30, kind: .callEnded, recordingIdentity: tracking.recordingIdentity)
        case .warningCleared:
            clearCallEndWarning()
        case .stop:
            let warning = audioInactivityWarning
            Task { @MainActor [weak self] in
                guard let self, let warning, warning.kind == .callEnded else { return }
                await self.endRecordingFromAudioInactivityPrompt(automatic: true, expectedWarning: warning)
            }
        }
    }

    func updateCallCameraInUse(_ inUse: Bool?, sampledAt: TimeInterval) {
        callCameraInUse = inUse
        callCameraSampledAt = sampledAt
        if inUse != false, var tracking = callEndTracking {
            // A camera is not attributable to an app. Treat it conservatively
            // as a veto, never as proof that a particular call ended.
            _ = tracking.policy.observe(inUse == true ? .active : .unknown, sampledAt: sampledAt,
                                        at: ProcessInfo.processInfo.systemUptime)
            callEndTracking = tracking
            clearCallEndWarning()
        }
    }

    func disableCallEndDetection() {
        callEndTracking = nil
        latestCallActivity = .unknown
        latestCallActivityAt = nil
        clearCallEndWarning()
    }

    func keepRecordingAfterCallEnd() {
        callEndTracking?.policy.keepRecording()
        _ = audioInactivityDetector.dismissWarning()
        clearCallEndWarning()
    }

    func canAutomaticallyStopEndedCall(_ warning: MeetingAudioInactivityWarning) -> Bool {
        guard isRecording, let tracking = callEndTracking else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        return tracking.canStop(currentIdentity: activeRecordingIdentity, warningIdentity: warning.recordingIdentity,
            activity: latestCallActivity.activity(in: tracking.families, cameraInUse: freshCallCameraActivity(at: now)),
            at: now)
    }

    private func freshCallCameraActivity(at now: TimeInterval) -> Bool? {
        guard let sampledAt = callCameraSampledAt, now >= sampledAt, now - sampledAt <= 12 else { return nil }
        return callCameraInUse
    }

    private func clearCallEndWarning() {
        if audioInactivityWarning?.kind == .callEnded {
            audioInactivityWarning = nil
            if let fallback = audioInactivityDetector.warning { applyAudioInactivityEvent(.warningStarted(fallback)) }
        }
    }
}
