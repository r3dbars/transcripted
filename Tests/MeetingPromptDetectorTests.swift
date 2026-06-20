import Foundation

@available(macOS 14.0, *)
@MainActor
private func makeMeetingPromptCandidate(
    id: String,
    provider: MeetingPromptProvider = .zoom,
    source: MeetingPromptSource,
    reason: MeetingPromptReason? = nil
) -> MeetingPromptDetector.Candidate {
    let startDate = Date(timeIntervalSince1970: 2_000)
    return MeetingPromptDetector.Candidate(
        id: id,
        title: "Meeting detected",
        detail: "Design review - starting now",
        provider: provider,
        reason: reason ?? MeetingPromptHeuristics.reason(for: source, hasRuntimeContext: false),
        source: source,
        startDate: startDate,
        endDate: startDate.addingTimeInterval(30 * 60),
        meetingURL: nil,
        suggestedTranscriptTitle: source == .calendarEvent ? "Design review" : nil
    )
}

@available(macOS 14.0, *)
private func makeMeetingPromptCalendarSnapshot(
    id: String,
    provider: MeetingPromptProvider = .webex,
    startsIn: TimeInterval,
    duration: TimeInterval = 30 * 60,
    isAllDay: Bool = false,
    now: Date
) -> MeetingPromptCalendarEventSnapshot {
    let url: URL
    switch provider {
    case .zoom:
        url = URL(string: "https://zoom.us/j/123")!
    case .googleMeet:
        url = URL(string: "https://meet.google.com/abc-defg-hij")!
    case .teams:
        url = URL(string: "https://teams.microsoft.com/l/meetup-join/example")!
    case .webex:
        url = URL(string: "https://company.webex.com/meet/room")!
    case .facetime:
        url = URL(string: "https://facetime.apple.com/join/example")!
    }

    return MeetingPromptCalendarEventSnapshot(
        id: id,
        title: "Design review",
        startDate: now.addingTimeInterval(startsIn),
        endDate: now.addingTimeInterval(startsIn + duration),
        isAllDay: isAllDay,
        url: url,
        location: nil,
        notes: nil
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

    runSuite("MeetingPromptDetector.dismiss — runtime resume ignores all-day calendar blocks") {
        let now = Date()
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { true },
            calendarEventSnapshots: [
                makeMeetingPromptCalendarSnapshot(
                    id: "all-day-webex",
                    startsIn: 4 * 60 * 60,
                    duration: 8 * 60 * 60,
                    isAllDay: true,
                    now: now
                )
            ]
        )
        let candidate = makeMeetingPromptCandidate(id: "runtime:webex", provider: .webex, source: .runtimeApp)

        let before = Date()
        let decision = detector.dismiss(candidate: candidate)
        let after = Date()

        assertEqual(
            decision.kind,
            .runtimeDefaultFallback,
            "all-day meeting links should not suppress runtime prompts until the calendar block ends"
        )
        assertTrue(
            decision.until >= before.addingTimeInterval(MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval - 1),
            "all-day events should fall back to the normal runtime dismissal interval"
        )
        assertTrue(
            decision.until <= after.addingTimeInterval(MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval + 1),
            "all-day events should not stretch runtime suppression to the later calendar block"
        )
    }

    runSuite("MeetingPromptDetector.dismiss — runtime resume still uses the next real calendar meeting") {
        let now = Date()
        let startsIn: TimeInterval = 10 * 60
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { true },
            calendarEventSnapshots: [
                makeMeetingPromptCalendarSnapshot(
                    id: "upcoming-webex",
                    startsIn: startsIn,
                    now: now
                )
            ]
        )
        let candidate = makeMeetingPromptCandidate(id: "runtime:webex", provider: .webex, source: .runtimeApp)

        let before = Date()
        let decision = detector.dismiss(candidate: candidate)
        let expectedResume = now.addingTimeInterval(startsIn - MeetingPromptHeuristics.calendarReminderLeadTime)

        assertEqual(
            decision.kind,
            .runtimeUntilNextCalendar,
            "real meeting links should still resume runtime prompts before the next calendar meeting"
        )
        assertTrue(
            decision.until >= expectedResume.addingTimeInterval(-1),
            "runtime resume should land near the next calendar prompt window"
        )
        assertTrue(
            decision.until <= before.addingTimeInterval(startsIn),
            "runtime resume should happen before the meeting starts"
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

    runSuite("MeetingPromptDetector.Candidate analytics buckets stay coarse") {
        let calendarRuntime = makeMeetingPromptCandidate(
            id: "calendar:runtime",
            provider: .googleMeet,
            source: .calendarEvent,
            reason: .calendarPlusRuntimeMatch
        )
        let mic = makeMeetingPromptCandidate(
            id: "mic:browser",
            provider: .googleMeet,
            source: .runtimeApp,
            reason: .micInput
        )

        assertEqual(calendarRuntime.analyticsCalendarConfidence, "linked_event_runtime_match", "calendar plus runtime evidence should stay a coarse confidence bucket")
        assertEqual(calendarRuntime.analyticsCallState, "app_active", "calendar plus runtime evidence should not name the app or meeting")
        assertEqual(calendarRuntime.analyticsAppSignal, "browser_runtime", "browser-hosted calendar matches should stay a family-level signal")
        assertEqual(mic.analyticsCalendarConfidence, "none", "ad-hoc mic prompts should not imply calendar evidence")
        assertEqual(mic.analyticsCallState, "mic_active", "mic prompts should preserve active-call evidence")
        assertEqual(mic.analyticsAppSignal, "browser_mic", "browser mic prompts should stay family-level, not bundle-level")
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

    await runSuite("MeetingPromptDetector.updateMicInputUsers — busy presentation state suppresses mic prompts") {
        let detector = MeetingPromptDetector()
        detector.shouldSkipPromptEvaluation = { true }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertNil(box.candidate, "detector-level busy-state gating should block ad-hoc call prompts")
        assertEqual(box.promptCount, 0, "busy-state suppression should avoid asking the overlay to present")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — disabled mic prompt gate suppresses stale callbacks") {
        let detector = MeetingPromptDetector()
        detector.isMicInputPromptEnabled = { false }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertNil(box.candidate, "a stale monitor callback after disabling auto-detect calls should stay quiet")
        assertEqual(box.promptCount, 0, "the disabled preference gate should avoid asking the overlay to present")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — pending mic prompt avoids repeats during one call") {
        let detector = MeetingPromptDetector()
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
            box.suppressionCount += 1
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        detector.updateMicInputUsers(["com.google.Chrome.helper", "com.apple.WebKit.GPU"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "a changed browser-helper set should not spam a second mic prompt for the same call")
        assertEqual(box.candidate?.id, "mic:googleMeet", "the pending candidate id should stay stable across browser helpers")
        assertEqual(box.suppressionCount, 1, "duplicate pending candidates should emit one suppression signal")
        assertEqual(box.suppression?.reason, .pendingCandidate, "duplicate prompt attempts should be classified as pending")
        assertEqual(box.suppression?.cooldownReason, "prompt_pending", "pending duplicates should keep the prompt-pending cooldown reason")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — inactive edge preserves transient pending cooldown") {
        let detector = MeetingPromptDetector()
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        detector.updateMicInputUsers([])
        await waitForPromptEvaluation()
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "mute/unmute should not bypass the short pending cooldown")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — inactive edge preserves explicit dismiss backoff") {
        let detector = MeetingPromptDetector()
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
            box.suppressionCount += 1
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        if let candidate = box.candidate {
            _ = detector.dismiss(candidate: candidate)
        }
        detector.updateMicInputUsers([])
        await waitForPromptEvaluation()
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "mute/unmute should not wipe an explicit Not now dismissal")
        assertEqual(box.suppressionCount, 1, "dismissed mic prompts should emit a cooldown suppression signal when the call returns")
        assertEqual(box.suppression?.reason, .runtimeSuppressed, "dismissed mic prompts should classify follow-up attempts as runtime-suppressed")
        assertEqual(box.suppression?.cooldownReason, MeetingPromptBackoffKind.runtimeDefaultFallback.rawValue, "suppression should keep the backoff rule that caused the cooldown")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — already-recording suppression is reported coarsely") {
        let detector = MeetingPromptDetector()
        detector.ownCaptureActivity = { .meetingRecording }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
            box.suppressionCount += 1
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertNil(box.candidate, "we should not prompt while a meeting recording is already active")
        assertEqual(box.promptCount, 0, "already-recording suppression should not ask the overlay to present")
        assertEqual(box.suppressionCount, 1, "already-recording calls should emit one suppression signal")
        assertEqual(box.suppression?.reason, .ownCaptureActive, "already-recording calls should use the own-capture suppression reason")
        assertEqual(box.suppression?.captureActivity, .meetingRecording, "suppression should preserve meeting-vs-dictation activity without app names")
        assertEqual(box.suppression?.candidate.provider, .googleMeet, "suppression should keep only the coarse provider enum")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — native mic candidate keeps calendar title") {
        let now = Date()
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { true },
            calendarEventSnapshots: [
                makeMeetingPromptCalendarSnapshot(
                    id: "scheduled-zoom",
                    provider: .zoom,
                    startsIn: 30,
                    now: now
                )
            ],
            refreshesCalendarEventSnapshots: false
        )
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "one prompt should be presented")
        assertEqual(box.candidate?.source, .calendarEvent, "native mic evidence should keep matching calendar context")
        assertEqual(box.candidate?.suggestedTranscriptTitle, "Design review", "native calendar-backed mic calls should keep the meeting title hint")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — generic browser mic candidate does not steal calendar title") {
        let now = Date()
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { true },
            calendarEventSnapshots: [
                makeMeetingPromptCalendarSnapshot(
                    id: "scheduled-meet",
                    provider: .googleMeet,
                    startsIn: 30,
                    now: now
                )
            ],
            refreshesCalendarEventSnapshots: false
        )
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "one prompt should be presented")
        assertEqual(box.candidate?.source, .runtimeApp, "generic browser mic evidence should not borrow an unrelated Meet calendar event")
        assertNil(box.candidate?.suggestedTranscriptTitle, "browser mic prompts should stay neutral because they could be Meet, Zoom-web, or Teams-web")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — browser mic does not replace pending calendar prompt") {
        let now = Date()
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { true },
            calendarEventSnapshots: [
                makeMeetingPromptCalendarSnapshot(
                    id: "scheduled-meet",
                    provider: .googleMeet,
                    startsIn: 30,
                    now: now
                )
            ],
            refreshesCalendarEventSnapshots: false
        )
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.start()
        await waitForPromptEvaluation()
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        detector.stop()

        assertEqual(box.promptCount, 1, "generic browser mic should not bypass an already-pending calendar prompt")
        assertEqual(box.candidate?.source, .calendarEvent, "the visible scheduled prompt should keep its calendar context")
        assertEqual(box.candidate?.suggestedTranscriptTitle, "Design review", "the scheduled prompt should keep the meeting title hint")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class CandidateBox {
    var candidate: MeetingPromptDetector.Candidate?
    var suppression: MeetingPromptSuppression?
    var promptCount = 0
    var suppressionCount = 0
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
