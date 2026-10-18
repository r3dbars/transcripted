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

    func install(on detector: MeetingPromptDetector, pill: CapturePillController) {
        pill.onRecord = onRecord
        pill.onDismiss = onDismiss
        pill.onExpired = onExpired
        pill.onRemind = onRemind

        let onboardingCompleted = onboardingCompleted
        let detailOverride = detailOverride
        let onShown = onShown
        detector.onPromptRequest = { [weak pill] candidate in
            guard onboardingCompleted() else { return false }
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
}
