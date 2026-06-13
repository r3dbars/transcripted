import Foundation

@available(macOS 14.0, *)
@MainActor
private func makeMeetingPromptCandidate(
    id: String,
    provider: MeetingPromptProvider = .zoom,
    source: MeetingPromptSource
) -> MeetingPromptDetector.Candidate {
    let startDate = Date(timeIntervalSince1970: 2_000)
    return MeetingPromptDetector.Candidate(
        id: id,
        title: "Meeting detected",
        detail: "Design review - starting now",
        provider: provider,
        reason: MeetingPromptHeuristics.reason(for: source, hasRuntimeContext: false),
        source: source,
        startDate: startDate,
        endDate: startDate.addingTimeInterval(30 * 60),
        meetingURL: nil,
        suggestedTranscriptTitle: source == .calendarEvent ? "Design review" : nil
    )
}

@MainActor
func testMeetingPromptDetector() async {
    guard #available(macOS 14.0, *) else { return }

    runSuite("MeetingPromptDetector.remindSoon — calendar prompts use the short reminder backoff") {
        let detector = MeetingPromptDetector()
        let candidate = makeMeetingPromptCandidate(id: "calendar:design-review", source: .calendarEvent)

        let before = Date()
        let decision = detector.remindSoon(candidate: candidate)
        let after = Date()

        assertEqual(
            decision.kind,
            .calendarShortReminder,
            "remind-soon should stay distinct from a full calendar dismissal"
        )
        assertTrue(
            decision.until >= before.addingTimeInterval(MeetingPromptHeuristics.remindSoonInterval - 1),
            "remind-soon should not return before the short reminder interval"
        )
        assertTrue(
            decision.until <= after.addingTimeInterval(MeetingPromptHeuristics.remindSoonInterval + 1),
            "remind-soon should not fall back to the long calendar dismissal interval"
        )
    }

    runSuite("MeetingPromptDetector.remindSoon — runtime prompts use the short reminder backoff") {
        let detector = MeetingPromptDetector()
        let candidate = makeMeetingPromptCandidate(id: "runtime:zoom", source: .runtimeApp)

        let before = Date()
        let decision = detector.remindSoon(candidate: candidate)
        let after = Date()

        assertEqual(
            decision.kind,
            .runtimeShortReminder,
            "runtime remind-soon should stay distinct from a full runtime dismissal"
        )
        assertTrue(
            decision.until >= before.addingTimeInterval(MeetingPromptHeuristics.remindSoonInterval - 1),
            "runtime remind-soon should not return before the short reminder interval"
        )
        assertTrue(
            decision.until <= after.addingTimeInterval(MeetingPromptHeuristics.remindSoonInterval + 1),
            "runtime remind-soon should not fall back to the long runtime dismissal interval"
        )
    }

    runSuite("MeetingPromptDetector.dismiss — Not now keeps the longer calendar dismissal") {
        let detector = MeetingPromptDetector()
        let candidate = makeMeetingPromptCandidate(id: "calendar:not-now", source: .calendarEvent)

        let before = Date()
        let decision = detector.dismiss(candidate: candidate)

        assertEqual(
            decision.kind,
            .calendarDefault,
            "calendar dismissal should keep using the normal Not now backoff"
        )
        assertTrue(
            decision.until.timeIntervalSince(before) > 25 * 60,
            "Not now should remain meaningfully longer than Remind me soon"
        )
    }

    runSuite("MeetingPromptDetector.Candidate — calendar prompts carry a transcript title hint") {
        let calendarCandidate = makeMeetingPromptCandidate(id: "calendar:title", source: .calendarEvent)
        let runtimeCandidate = makeMeetingPromptCandidate(id: "runtime:title", source: .runtimeApp)

        assertEqual(
            calendarCandidate.suggestedTranscriptTitle,
            "Design review",
            "calendar-backed prompts should carry the event title into the recording path"
        )
        assertNil(
            runtimeCandidate.suggestedTranscriptTitle,
            "runtime-only prompts should not invent a transcript title"
        )
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — a browser holding the mic prompts an ad-hoc call") {
        let detector = MeetingPromptDetector()
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertNotNil(box.candidate, "a browser holding the mic should surface a prompt with no calendar event")
        assertEqual(box.candidate?.id, "mic:googleMeet", "a browser mic call should attribute to the browser-call provider")
        assertEqual(box.candidate?.reason, .micInput, "mic prompts should record the distinct mic-input reason")
        assertEqual(box.candidate?.source, .runtimeApp, "mic prompts should reuse the runtime source so backoff is unchanged")
        assertEqual(box.candidate?.suggestedTranscriptTitle, nil, "a browser call has no calendar title to suggest")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — never prompts while our own capture is active") {
        let detector = MeetingPromptDetector()
        detector.isOwnCaptureActive = { true }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertNil(box.candidate, "we must never prompt to record a call while Transcripted itself holds the mic")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class CandidateBox {
    var candidate: MeetingPromptDetector.Candidate?
}

// updateMicInputUsers re-evaluates on a detached @MainActor Task; yield/sleep a
// few times so it can run before we assert.
@MainActor
private func waitForPromptEvaluation() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
