import Foundation

private func habitLoopResults(
    _ events: [HomeMeetingActionTelemetry.Event]
) -> [ActivationTelemetry.HabitLoopResult] {
    events.compactMap { event in
        if case let .habitLoop(_, result) = event { return result }
        return nil
    }
}

func testHomeMeetingActionTelemetry() {
    runSuite("Copy for agent reports habit-loop once, with the result the copy actually had") {
        let outcomes: [(HomeMeetingActionTelemetry.CopyOutcome, ActivationTelemetry.HabitLoopResult)] = [
            (.missingFile, .failed),
            (.readFailure, .failed),
            (.resolved(usedBundle: true, copied: true), .success),
            (.resolved(usedBundle: false, copied: true), .success),
            (.resolved(usedBundle: true, copied: false), .failed),
            (.resolved(usedBundle: false, copied: false), .failed),
        ]
        for (outcome, expected) in outcomes {
            assertEqual(
                habitLoopResults(HomeMeetingActionTelemetry.copyEvents(for: outcome)),
                [expected],
                "\(outcome) should report exactly one habit-loop action, \(expected)"
            )
        }
    }

    runSuite("A copy that never reached the clipboard reports nothing but failures") {
        for outcome: HomeMeetingActionTelemetry.CopyOutcome in [.missingFile, .readFailure] {
            assertEqual(
                HomeMeetingActionTelemetry.copyEvents(for: outcome),
                [
                    .savedResult(action: .copy, succeeded: false),
                    .habitLoop(.whatDidIPromise, result: .failed),
                    .agentPrompt(.meetingBundle, result: .failed),
                ],
                "\(outcome) should report a failed copy, habit-loop and agent prompt"
            )
        }
    }

    runSuite("A resolved copy reports the bundle, the Markdown fallback, or the failed write") {
        assertEqual(
            HomeMeetingActionTelemetry.copyEvents(for: .resolved(usedBundle: true, copied: true)),
            [.habitLoop(.whatDidIPromise, result: .success), .agentPrompt(.meetingBundle, result: .success)],
            "a copied bundle should report success"
        )
        assertEqual(
            HomeMeetingActionTelemetry.copyEvents(for: .resolved(usedBundle: false, copied: true)),
            [.habitLoop(.whatDidIPromise, result: .success), .agentPrompt(.meetingMarkdown, result: .fallbackCopied)],
            "copying the plain Markdown should report the fallback"
        )
        assertEqual(
            HomeMeetingActionTelemetry.copyEvents(for: .resolved(usedBundle: true, copied: false)),
            [.habitLoop(.whatDidIPromise, result: .failed), .agentPrompt(.meetingBundle, result: .failed)],
            "a clipboard write that failed should report failure"
        )
        // The saved-result event for a resolved copy comes from
        // ProductUsageTelemetry.copy around the write itself.
        assertFalse(
            HomeMeetingActionTelemetry.copyEvents(for: .resolved(usedBundle: true, copied: true))
                .contains { if case .savedResult = $0 { return true } else { return false } },
            "a resolved copy shouldn't report its saved result twice"
        )
    }

    runSuite("Meeting preview reports one habit-loop action, after the Markdown read") {
        assertEqual(
            HomeMeetingActionTelemetry.previewEvents(loaded: true),
            [
                .savedResult(action: .preview, succeeded: true),
                .artifactPreview(result: .success),
                .habitLoop(.openRecentMeeting, result: .success),
            ],
            "a preview that loaded should report success"
        )
        assertEqual(
            HomeMeetingActionTelemetry.previewEvents(loaded: false),
            [
                .savedResult(action: .preview, succeeded: false),
                .artifactPreview(result: .failed),
                .habitLoop(.openRecentMeeting, result: .failed),
            ],
            "a preview whose read failed should report failure"
        )
    }

    runSuite("Clearing a failed meeting row is reported as a deletion") {
        assertEqual(
            HomeFailedMeetingCleanupTelemetry.reasonKind,
            .deleted,
            "clearing a failed row deletes its audio, so it's a deletion, not a dismissal"
        )
        assertEqual(HomeFailedMeetingCleanupTelemetry.workflowKind, .failedMeetingRetry, "it ends the failed-meeting retry workflow")
        assertEqual(HomeFailedMeetingCleanupTelemetry.priorReadyState(canRetry: true), "retry_ready", "a retryable row reports retry_ready")
        assertEqual(HomeFailedMeetingCleanupTelemetry.priorReadyState(canRetry: false), "retry_blocked", "a blocked row reports retry_blocked")
    }
}
