import Foundation

/// Connects the meeting prompt detector to the call prompt on the island:
/// where a detected call is shown, and which callback each answer
/// (Record, Not now, Remind soon, timeout) reaches. The app supplies the
/// effects as closures; this type owns only the connections, so a fast test
/// can drive the real detector hook and the real pill controller and see that
/// each one lands where it should.
@MainActor
struct DetectedMeetingPromptWiring {
    /// No prompt before first-run setup is finished.
    var onboardingCompleted: () -> Bool
    /// Replacement detail line for the prompt, or nil to keep the candidate's own.
    var detailOverride: () -> String?
    /// A prompt reached the island.
    var onShown: (MeetingPromptDetector.Candidate) -> Void
    var onRecord: (MeetingPromptDetector.Candidate) -> Void
    var onDismiss: (MeetingPromptDetector.Candidate) -> Void
    var onExpired: (MeetingPromptDetector.Candidate) -> Void
    var onRemind: (MeetingPromptDetector.Candidate) -> Void
    /// Defaults to prompt so existing installs and tests keep today's island.
    var decisionForCandidate: (MeetingPromptDetector.Candidate) -> MeetingAutoRecordPolicy.Decision = { _ in .prompt }
    /// Starts capture through the Record path without showing the prompt.
    /// Return false when kickoff bailed so the island prompt is shown instead.
    var onAutoStart: ((MeetingPromptDetector.Candidate) -> Bool)? = nil

    func install(on detector: MeetingPromptDetector, pill: CapturePillController) {
        pill.onRecord = onRecord
        pill.onDismiss = onDismiss
        pill.onExpired = onExpired
        pill.onRemind = onRemind

        let onboardingCompleted = onboardingCompleted
        let detailOverride = detailOverride
        let onShown = onShown
        let decisionForCandidate = decisionForCandidate
        let onAutoStart = onAutoStart
        let presentPrompt: (MeetingPromptDetector.Candidate) -> MeetingPromptDetector.RequestResult = { [weak pill] candidate in
            guard let pill else { return .skipped }
            let promptTimeout = MeetingPromptHeuristics.promptTimeoutSeconds(
                for: candidate.reason,
                calendarDefault: 30
            )
            let presented = pill.present(
                candidate: candidate,
                timeout: TimeInterval(promptTimeout),
                detailOverride: detailOverride()
            )
            if presented { onShown(candidate) }
            return presented ? .presented : .skipped
        }
        detector.onPromptFallback = { [weak detector] candidate in
            guard onboardingCompleted() else { return .skipped }
            // A kickoff that bailed because capture is already running must
            // not stack Record / Not now on the live recording.
            if detector?.shouldSkipPromptEvaluation?() == true {
                return .skipped
            }
            return presentPrompt(candidate)
        }
        detector.onPromptRequest = { [weak detector] candidate in
            guard onboardingCompleted() else { return .skipped }
            switch decisionForCandidate(candidate) {
            case .none:
                return .skipped
            case .autoStart:
                if onAutoStart?(candidate) == true {
                    return .autoStarted
                }
            case .prompt:
                break
            }
            if detector?.shouldSkipPromptEvaluation?() == true {
                return .skipped
            }
            return presentPrompt(candidate)
        }
    }

    static func autoRecordDecision(
        for candidate: MeetingPromptDetector.Candidate,
        otherCaptureActive: Bool,
        autoRecordEnabled: Bool = AutoRecordDetectedCallsPreferences.isEnabled(),
        microphoneGranted: Bool = TranscriptedPermissionAccess.isGranted(.microphone),
        systemAudioGranted: Bool? = nil,
        liveSystemAudio: (() -> Bool)? = nil,
        cachedSystemAudio: (() -> Bool)? = nil
    ) -> MeetingAutoRecordPolicy.Decision {
        let granted: Bool
        if let systemAudioGranted {
            granted = systemAudioGranted
        } else if autoRecordEnabled {
            granted = liveSystemAudio?() ?? liveSystemAudioGranted()
        } else {
            granted = cachedSystemAudio?() ?? TranscriptedPermissionAccess.systemAudioRecordingGranted()
        }
        return MeetingAutoRecordPolicy.decision(
            for: MeetingAutoRecordPolicy.Request(
                autoRecordEnabled: autoRecordEnabled,
                evidence: candidate.callEvidence,
                provider: candidate.provider,
                reason: candidate.reason,
                microphoneGranted: microphoneGranted,
                systemAudioGranted: granted,
                otherCaptureActive: otherCaptureActive,
                holdsMicrophone: candidate.holdsMicrophone,
                isFocusedFrontWindow: candidate.isFocusedFrontWindow,
                isMeetPreJoin: candidate.isMeetPreJoin,
                evidenceAge: candidate.evidenceAge,
                isPlayingCallAudio: candidate.isPlayingCallAudio,
                borrowedProofSource: candidate.borrowedProofSource,
                nativeProcessHoldsMicrophone: candidate.nativeProcessHoldsMicrophone
            )
        )
    }

    /// Prompt-free live TCC peek. A cached UserDefaults grant is not enough:
    /// auto-start must not raise the macOS box from the background. Does not
    /// rewrite the saved grant.
    static func liveSystemAudioGranted() -> Bool {
        TranscriptedPermissionAccess.peekSystemAudioRecordingStatusFromSystem() == .authorized
    }
}
