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
            sampledAt: latestCallActivity.sampledAt, now: ProcessInfo.processInfo.systemUptime)
    }

    func observeCallActivity(_ snapshot: MeetingCallActivitySnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        latestCallActivity = snapshot
        if isRecording, callEndTracking == nil, let pending = pendingCallEndCandidate,
           pending.identity == activeRecordingIdentity,
           let families = callEndFamilies(for: pending.candidate) {
            armCallEndTracking(identity: pending.identity, families: families, late: true)
        }
        guard isRecording, let tracking = callEndTracking,
              tracking.recordingIdentity == activeRecordingIdentity else { return }
        // The snapshot carries when the audio system was actually read, which can
        // be seconds before this delivery. A read with no usable sampling time,
        // or one that is stale or from the future, is unknown: it must never look
        // like a released stream or hold up a countdown.
        let sampledAt = snapshot.sampledAt
        let activity: MeetingEndDetectionPolicy.Activity
        if let sampledAt, sampledAt <= now, now - sampledAt <= tracking.policy.maximumSampleGap {
            activity = snapshot.activity(in: tracking.families, cameraInUse: freshCallCameraActivity(at: now))
        } else {
            activity = .unknown
        }
        observeCallEnd(activity, sampledAt: sampledAt ?? now, at: now)
    }

    func updateCallCameraInUse(_ inUse: Bool?, sampledAt: TimeInterval) {
        callCameraInUse = inUse
        callCameraSampledAt = sampledAt
        // A camera is not attributable to an app. In use is a conservative
        // veto; a failed read only holds. Neither is proof a call ended.
        guard inUse != false, callEndTracking != nil else { return }
        observeCallEnd(inUse == true ? .active : .unknown, sampledAt: sampledAt,
                       at: ProcessInfo.processInfo.systemUptime)
    }

    private func observeCallEnd(_ activity: MeetingEndDetectionPolicy.Activity,
                                sampledAt: TimeInterval, at now: TimeInterval) {
        guard var tracking = callEndTracking else { return }
        let event = tracking.policy.observe(activity, sampledAt: sampledAt, at: now)
        if event == .warningStarted || event == .warningCleared {
            tracking.heardAudioDuringWarning = false
        }
        callEndTracking = tracking
        switch event {
        case .none, .stop:
            // Only the visible countdown reaching zero stops the recording
            // (resolveCallEndCountdownExpiry), so a poll can't stop it early
            // or a few seconds after the prompt already said 0.
            break
        case .warningStarted:
            audioInactivityWarning = MeetingAudioInactivityWarning(
                inactiveDuration: tracking.policy.inactivityInterval,
                countdownSeconds: Int(tracking.policy.countdownInterval),
                kind: .callEnded,
                recordingIdentity: tracking.recordingIdentity
            )
            recordCallEndDiagnostic("meeting_call_end_warning_started", "Call app stopped using audio; call-end countdown shown")
        case .warningCleared:
            clearCallEndWarning()
        }
    }

    /// Room speech or other playback while "Call ended" is up. It doesn't
    /// clear the warning, but it vetoes the automatic stop.
    func noteAudioLevelsForCallEnd(micLevel: Float, systemLevel: Float) {
        guard audioInactivityWarning?.kind == .callEnded,
              callEndTracking?.heardAudioDuringWarning == false else { return }
        let threshold = MeetingAudioInactivityDetector.Configuration.default.activeLevelThreshold
        guard micLevel > threshold || systemLevel > threshold else { return }
        callEndTracking?.heardAudioDuringWarning = true
    }

    /// The visible countdown reached zero. Read the call app's audio right now
    /// rather than waiting up to a poll for the next scheduled read, so the
    /// recording stops at 0 and a call that came back in the last seconds is
    /// still seen. If it can't safely stop (room audio, a failed read), the
    /// prompt stays with Continue / Stop and no countdown.
    func resolveCallEndCountdownExpiry(_ warning: MeetingAudioInactivityWarning) async {
        guard warning.kind == .callEnded, audioInactivityWarning == warning, isRecording else { return }
        if let snapshot = await freshCallActivitySnapshot() {
            observeCallActivity(snapshot)
        }
        // A returning call clears the warning; a manual answer replaces it.
        guard audioInactivityWarning == warning, isRecording else { return }
        if canAutomaticallyStopEndedCall(warning) {
            await endRecordingFromAudioInactivityPrompt(automatic: true, expectedWarning: warning)
            return
        }
        let heardAudio = callEndTracking?.heardAudioDuringWarning == true
        audioInactivityWarning = MeetingAudioInactivityWarning(
            inactiveDuration: warning.inactiveDuration,
            countdownSeconds: warning.countdownSeconds,
            kind: .callEnded,
            automaticStopAllowed: false,
            recordingIdentity: warning.recordingIdentity
        )
        recordCallEndDiagnostic("meeting_call_end_auto_stop_held",
                                "Call-end countdown expired; left for the user to decide",
                                extra: ["hold_reason": heardAudio ? "audio_heard" : "unconfirmed_read"])
    }

    private func freshCallActivitySnapshot() async -> MeetingCallActivitySnapshot? {
        guard let sampler = callActivitySampler else { return nil }
        let once = CallActivitySampleOnce()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            sampler { snapshot in once.resume(snapshot) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { once.resume(nil) }
            }
        }
    }

    /// Arms call-end detection for a detected-prompt start. When the call app
    /// is not using audio yet (the prompt was accepted before joining), the
    /// candidate is remembered and bound by a later activity snapshot for this
    /// recording. Manual starts never arm.
    func armCallEndDetection(callFamilies: Set<String>?,
                             detectedPrompt: Bool,
                             candidate: MeetingPromptDetector.Candidate?) {
        guard AutoCallDetectionPreferences.isEnabled(), let identity = activeRecordingIdentity else { return }
        if let callFamilies {
            armCallEndTracking(identity: identity, families: callFamilies, late: false)
        } else if detectedPrompt, let candidate {
            pendingCallEndCandidate = (identity, candidate)
        }
    }

    func armCallEndTracking(identity: UUID, families: Set<String>, late: Bool) {
        pendingCallEndCandidate = nil
        callEndTracking = MeetingCallEndTracking(recordingIdentity: identity, families: families)
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_call_end_detection_armed",
            message: "Call-end detection armed",
            context: baseDiagnosticsContext(extra: [
                "late": "\(late)",
                "families": families.sorted().joined(separator: ",")
            ])
        )
    }

    func disableCallEndDetection(restoringSilenceWarning: Bool = true) {
        pendingCallEndCandidate = nil
        callEndTracking = nil
        latestCallActivity = .unknown
        clearCallEndWarning(restoringSilenceWarning: restoringSilenceWarning)
    }

    func keepRecordingAfterCallEnd() {
        callEndTracking?.policy.keepRecording()
        _ = audioInactivityDetector.dismissWarning()
        recordCallEndDiagnostic("meeting_call_end_kept", "Call-end warning answered with Continue")
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
        guard let sampledAt = callCameraSampledAt, now >= sampledAt,
              now - sampledAt <= MeetingEndDetectionPolicy.sampleFreshness else { return nil }
        return callCameraInUse
    }

    private func clearCallEndWarning(restoringSilenceWarning: Bool = true) {
        if audioInactivityWarning?.kind == .callEnded {
            audioInactivityWarning = nil
            // Stop and cancel pass false: a pending "No sound" must not flash
            // up while the recording is ending.
            if restoringSilenceWarning, let fallback = audioInactivityDetector.warning {
                applyAudioInactivityEvent(.warningStarted(fallback))
            }
        }
    }

    private func recordCallEndDiagnostic(_ event: String, _ message: String, extra: [String: String] = [:]) {
        DiagnosticsTrail.record(engine: "meeting", event: event, message: message,
                                context: baseDiagnosticsContext(extra: extra))
    }
}

/// Resumes a fresh-sample wait exactly once: the sample or the timeout.
@MainActor
private final class CallActivitySampleOnce {
    var continuation: CheckedContinuation<MeetingCallActivitySnapshot?, Never>?

    func resume(_ snapshot: MeetingCallActivitySnapshot?) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
