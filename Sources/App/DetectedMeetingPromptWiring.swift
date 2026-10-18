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
    var onAutoStart: ((MeetingPromptDetector.Candidate) -> Void)? = nil

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
        detector.onPromptRequest = { [weak pill] candidate in
            guard onboardingCompleted() else { return false }
            switch decisionForCandidate(candidate) {
            case .none:
                return false
            case .autoStart:
                guard let onAutoStart else { break }
                onAutoStart(candidate)
                return true
            case .prompt:
                break
            }
            guard let pill else { return false }
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
            return presented
        }
    }

    static func autoRecordDecision(
        for candidate: MeetingPromptDetector.Candidate,
        otherCaptureActive: Bool,
        autoRecordEnabled: Bool = AutoRecordDetectedCallsPreferences.isEnabled(),
        microphoneGranted: Bool = TranscriptedPermissionAccess.isGranted(.microphone),
        systemAudioGranted: Bool? = nil
    ) -> MeetingAutoRecordPolicy.Decision {
        MeetingAutoRecordPolicy.decision(
            for: MeetingAutoRecordPolicy.Request(
                autoRecordEnabled: autoRecordEnabled,
                evidence: candidate.callEvidence,
                provider: candidate.provider,
                reason: candidate.reason,
                microphoneGranted: microphoneGranted,
                systemAudioGranted: systemAudioGranted ?? liveSystemAudioGranted(),
                otherCaptureActive: otherCaptureActive,
                holdsMicrophone: candidate.holdsMicrophone,
                isFocusedFrontWindow: candidate.isFocusedFrontWindow,
                isMeetPreJoin: candidate.isMeetPreJoin,
                evidenceAge: candidate.evidenceAge
            )
        )
    }

    /// Prompt-free live TCC read. A cached UserDefaults grant is not enough:
    /// auto-start must not raise the macOS box from the background.
    static func liveSystemAudioGranted() -> Bool {
        TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem() == .authorized
    }
}
