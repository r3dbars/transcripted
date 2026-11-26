import Foundation

@available(macOS 14.0, *)
@MainActor
private func makeRecordActionCandidate() -> MeetingPromptDetector.Candidate {
    let startDate = Date(timeIntervalSince1970: 2_000)
    return MeetingPromptDetector.Candidate(
        id: "record-action-candidate",
        title: "Meeting detected",
        detail: "Record this meeting?",
        provider: .zoom,
        reason: .calendarPlusRuntimeMatch,
        source: .calendarEvent,
        startDate: startDate,
        endDate: startDate.addingTimeInterval(30 * 60),
        meetingURL: nil,
        suggestedTranscriptTitle: nil
    )
}

@MainActor
private func yieldUntil(
    _ condition: @escaping () -> Bool,
    attempts: Int = 20
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
func testMeetingPromptRecordAction() async {
    guard #available(macOS 14.0, *) else { return }

    let candidate = makeRecordActionCandidate()
    var startContinuation: CheckedContinuation<Bool, Never>?
    var startRequestedCount = 0
    var startInvocationCount = 0
    var completedOutcomes: [Bool] = []

    let action = MeetingPromptRecordAction(
        onStartRequested: {
            startRequestedCount += 1
        },
        startRecording: { _, _ in
            startInvocationCount += 1
            return await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        },
        onCompleted: { _, started in
            completedOutcomes.append(started)
        }
    )

    runSuite("MeetingPromptRecordAction — Record start survives prompt dismissal and is single-flight") {
        assertTrue(
            action.record(candidate: candidate, promptTelemetryProperties: [:]),
            "the first Record choice should enqueue a start"
        )
        assertFalse(
            action.record(candidate: candidate, promptTelemetryProperties: [:]),
            "a second Record choice must not enqueue a duplicate meeting session"
        )
        assertEqual(startRequestedCount, 1, "only the accepted Record choice should update the UI")
    }

    // CapturePillController clears its prompt immediately after dispatching
    // Record. The app-owned action must keep running after that UI disappears.
    let startBeganAfterPromptDismissal = await yieldUntil { startInvocationCount == 1 }
    runSuite("MeetingPromptRecordAction — app-owned task continues after prompt UI is gone") {
        assertTrue(startBeganAfterPromptDismissal, "Record should reach the meeting start request after the prompt closes")
    }

    startContinuation?.resume(returning: true)
    let completedSuccessfully = await yieldUntil { completedOutcomes == [true] }
    runSuite("MeetingPromptRecordAction — reports a recording outcome") {
        assertTrue(completedSuccessfully, "a successful start should report the recording outcome")
        assertTrue(
            action.record(candidate: candidate, promptTelemetryProperties: [:]),
            "the action should accept a later Record choice after the first start resolves"
        )
    }

    let retryBegan = await yieldUntil { startInvocationCount == 2 }
    startContinuation?.resume(returning: false)
    let completedWithFailure = await yieldUntil { completedOutcomes == [true, false] }
    runSuite("MeetingPromptRecordAction — failed starts report an honest terminal outcome") {
        assertTrue(retryBegan, "a retry should start only after the first request resolves")
        assertTrue(completedWithFailure, "a failed start should reach the completion path instead of disappearing")
    }
}
