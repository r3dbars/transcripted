import Foundation

/// What Home reports when a meeting is copied for an agent or expanded for
/// preview. Each list is picked by how the action ended, so a habit-loop or
/// agent-prompt success can't go out before the transcript read resolves. The
/// view tracks its `trackSettingsAction` click right away, then emits the list
/// for the outcome, in order, once it knows it.
enum HomeMeetingActionTelemetry {
    enum Event: Equatable {
        /// `ProductUsageTelemetry.trackResult` for the meeting.
        case savedResult(action: ProductUsageTelemetry.Action, succeeded: Bool)
        /// `ActivationTelemetry.trackArtifactAction` for a meeting preview.
        case artifactPreview(result: ActivationTelemetry.ArtifactActionResult)
        /// `ActivationTelemetry.trackHabitLoopAction` for the meeting.
        case habitLoop(ActivationTelemetry.HabitLoopActionKind, result: ActivationTelemetry.HabitLoopResult)
        /// `ActivationTelemetry.trackAgentPromptAction`, copied for the local agent.
        case agentPrompt(ActivationTelemetry.AgentPromptKind, result: ActivationTelemetry.AgentPromptResult)
    }

    enum CopyOutcome: Equatable {
        /// No transcript on disk for the row.
        case missingFile
        /// The transcript exists but couldn't be read.
        case readFailure
        /// The transcript resolved and the clipboard write ran. Its
        /// saved-result event comes from `ProductUsageTelemetry.copy`, which
        /// wraps the write itself, so it isn't in this list.
        case resolved(usedBundle: Bool, copied: Bool)
    }

    static func copyEvents(for outcome: CopyOutcome) -> [Event] {
        switch outcome {
        case .missingFile, .readFailure:
            return [
                .savedResult(action: .copy, succeeded: false),
                .habitLoop(.whatDidIPromise, result: .failed),
                .agentPrompt(.meetingBundle, result: .failed),
            ]
        case let .resolved(usedBundle, copied):
            return [
                .habitLoop(.whatDidIPromise, result: copied ? .success : .failed),
                .agentPrompt(
                    usedBundle ? .meetingBundle : .meetingMarkdown,
                    result: copied ? (usedBundle ? .success : .fallbackCopied) : .failed
                ),
            ]
        }
    }

    /// The expanded row's Markdown read either loaded or failed.
    static func previewEvents(loaded: Bool) -> [Event] {
        [
            .savedResult(action: .preview, succeeded: loaded),
            .artifactPreview(result: loaded ? .success : .failed),
            .habitLoop(.openRecentMeeting, result: loaded ? .success : .failed),
        ]
    }

    static func emit(_ events: [Event], artifactDate: Date?) {
        for event in events {
            switch event {
            case let .savedResult(action, succeeded):
                ProductUsageTelemetry.trackResult(
                    kind: .meeting,
                    action: action,
                    surface: .meetings,
                    succeeded: succeeded,
                    artifactDate: artifactDate
                )
            case let .artifactPreview(result):
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .meeting,
                    actionKind: .preview,
                    surface: .homeRow,
                    artifactDate: artifactDate,
                    result: result
                )
            case let .habitLoop(actionKind, result):
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: actionKind,
                    surface: .homeRow,
                    artifactKind: .meeting,
                    artifactDate: artifactDate,
                    result: result
                )
            case let .agentPrompt(promptKind, result):
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: promptKind,
                    actionKind: .copied,
                    agentTarget: .localAgent,
                    surface: .homeRow,
                    result: result,
                    artifactKind: .meeting
                )
            }
        }
    }
}

/// What Home reports after a failed meeting row is cleaned up. Clearing a
/// failed row deletes its saved audio, so it's reported as a deletion, never
/// as a dismissal.
enum HomeFailedMeetingCleanupTelemetry {
    static let workflowKind: ActivationTelemetry.WorkflowKind = .failedMeetingRetry
    static let stage = "retry_available"
    static let reasonKind: ActivationTelemetry.WorkflowAbandonmentReasonKind = .deleted

    static func priorReadyState(canRetry: Bool) -> String {
        canRetry ? "retry_ready" : "retry_blocked"
    }
}
