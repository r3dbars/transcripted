import Foundation

@available(macOS 14.0, *)
private let syntheticPromptNow = Date(timeIntervalSince1970: 10_000)

@available(macOS 14.0, *)
private func syntheticRuntimeSnapshot(
    runningBundleIDs: Set<String> = [],
    frontmostBundleID: String? = nil,
    recentNativeActivity: [MeetingPromptProvider: Date] = [:],
    runtimeSuppressedUntil: [MeetingPromptProvider: Date] = [:]
) -> MeetingPromptRuntimeSnapshot {
    MeetingPromptRuntimeSnapshot(
        runningBundleIDs: runningBundleIDs,
        frontmostBundleID: frontmostBundleID,
        recentNativeActivity: recentNativeActivity,
        runtimeSuppressedUntil: runtimeSuppressedUntil
    )
}

@available(macOS 14.0, *)
private func syntheticCalendarEvent(
    id: String,
    title: String? = "Design review",
    startsIn: TimeInterval = 30,
    duration: TimeInterval = 30 * 60,
    isAllDay: Bool = false,
    url: URL? = URL(string: "https://us02web.zoom.us/j/123"),
    location: String? = nil,
    notes: String? = nil
) -> MeetingPromptCalendarEventSnapshot {
    MeetingPromptCalendarEventSnapshot(
        id: id,
        title: title,
        startDate: syntheticPromptNow.addingTimeInterval(startsIn),
        endDate: syntheticPromptNow.addingTimeInterval(startsIn + duration),
        isAllDay: isAllDay,
        url: url,
        location: location,
        notes: notes
    )
}

@available(macOS 14.0, *)
private func evaluateSyntheticPrompt(
    calendarAccessGranted: Bool = true,
    calendarEvents: [MeetingPromptCalendarEventSnapshot],
    runtimeSnapshot: MeetingPromptRuntimeSnapshot = syntheticRuntimeSnapshot(),
    snoozedUntil: [String: Date] = [:],
    pendingUntil: [String: Date] = [:],
    presentationSnapshot: MeetingPromptPresentationSnapshot? = nil
) -> MeetingPromptSyntheticEvaluation {
    MeetingPromptSyntheticEvaluator.evaluate(
        now: syntheticPromptNow,
        calendarAccessGranted: calendarAccessGranted,
        calendarEvents: calendarEvents,
        runtimeSnapshot: runtimeSnapshot,
        snoozedUntil: snoozedUntil,
        pendingUntil: pendingUntil,
        presentationSnapshot: presentationSnapshot
    )
}

func testSyntheticMeetingPrompts() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("SyntheticMeetingPrompts — calendar Zoom event creates one nearby prompt") {
        let result = evaluateSyntheticPrompt(calendarEvents: [
            syntheticCalendarEvent(id: "zoom-calendar")
        ])

        assertTrue(result.shouldPrompt, "a meeting URL in Calendar should produce a prompt")
        assertEqual(result.candidate?.id, "calendar:zoom-calendar", "candidate id should stay stable for cooldowns")
        assertEqual(result.candidate?.provider, .zoom, "Zoom URL should map to the Zoom provider")
        assertEqual(result.candidate?.source, .calendarEvent, "Calendar events should stay calendar-sourced")
        assertEqual(result.candidate?.reason, .calendarNearby, "calendar-only prompt should not claim runtime evidence")
        assertEqual(result.candidate?.suggestedTranscriptTitle, "Design review", "event title should feed meeting title hints")
        assertEqual(result.candidate?.detail, "Design review - starts soon", "near-start prompt copy should be deterministic")
    }

    runSuite("SyntheticMeetingPrompts — meeting URLs can come from location or notes") {
        let locationResult = evaluateSyntheticPrompt(calendarEvents: [
            syntheticCalendarEvent(
                id: "location-webex",
                url: nil,
                location: "Join at https://company.webex.com/meet/room"
            )
        ])
        let notesResult = evaluateSyntheticPrompt(calendarEvents: [
            syntheticCalendarEvent(
                id: "notes-teams",
                url: nil,
                notes: "Teams link: https://teams.microsoft.com/l/meetup-join/example"
            )
        ])

        assertEqual(locationResult.candidate?.provider, .webex, "location links should be scanned")
        assertEqual(notesResult.candidate?.provider, .teams, "notes links should be scanned")
    }

    runSuite("SyntheticMeetingPrompts — non-meeting calendar shapes stay quiet") {
        let allDay = evaluateSyntheticPrompt(calendarEvents: [
            syntheticCalendarEvent(id: "all-day", isAllDay: true)
        ])
        let tooEarly = evaluateSyntheticPrompt(calendarEvents: [
            syntheticCalendarEvent(id: "too-early", startsIn: MeetingPromptHeuristics.calendarReminderLeadTime + 1)
        ])
        let tooLate = evaluateSyntheticPrompt(calendarEvents: [
            syntheticCalendarEvent(id: "too-late", startsIn: -(MeetingPromptHeuristics.calendarReminderPostStartGrace + 1))
        ])
        let lookalike = evaluateSyntheticPrompt(calendarEvents: [
            syntheticCalendarEvent(id: "lookalike", url: URL(string: "https://zoom.us.evil.example/j/123"))
        ])

        assertEqual(allDay.suppressionReason, .noCandidate, "all-day meetings should not create prompts")
        assertEqual(tooEarly.suppressionReason, .noCandidate, "meetings outside the lead window should not prompt")
        assertEqual(tooLate.suppressionReason, .noCandidate, "expired meetings should not prompt")
        assertEqual(lookalike.suppressionReason, .noCandidate, "provider lookalikes should not prompt")
    }

    runSuite("SyntheticMeetingPrompts — calendar plus native runtime evidence gets stronger reason") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(id: "zoom-open", startsIn: 45)
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["us.zoom.xos"],
                frontmostBundleID: "us.zoom.xos"
            )
        )

        assertEqual(result.candidate?.reason, .calendarPlusRuntimeMatch, "open matching app should strengthen the calendar prompt")
        assertEqual(result.candidate?.detail, "Design review - Zoom is open", "detail should explain native runtime context")
    }

    runSuite("SyntheticMeetingPrompts — browser-hosted calendar providers can use browser context") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(
                    id: "google-meet-browser",
                    url: URL(string: "https://meet.google.com/abc-defg-hij")
                )
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                frontmostBundleID: "com.google.Chrome"
            )
        )

        assertEqual(result.candidate?.provider, .googleMeet, "Google Meet calendar URLs should be recognized")
        assertEqual(result.candidate?.reason, .calendarPlusRuntimeMatch, "frontmost browser should strengthen browser-hosted calendar prompts")
        assertEqual(result.candidate?.detail, "Design review - meeting tab is active", "browser context should stay generic and privacy-safe")
    }

    runSuite("SyntheticMeetingPrompts — browser frontmost alone does not invent a meeting") {
        let result = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(frontmostBundleID: "com.google.Chrome")
        )

        assertEqual(result.suppressionReason, .noCandidate, "a browser alone is not enough evidence for a prompt")
    }

    runSuite("SyntheticMeetingPrompts — native runtime prompts are provider-limited") {
        let zoom = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["us.zoom.xos"],
                frontmostBundleID: "us.zoom.xos"
            )
        )
        let teams = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["com.microsoft.teams2"],
                frontmostBundleID: "com.microsoft.teams2"
            )
        )

        assertEqual(zoom.candidate?.id, "runtime:zoom", "Zoom can prompt from runtime evidence")
        assertEqual(zoom.candidate?.title, "Zoom is active", "frontmost native runtime prompt should use active copy")
        assertEqual(teams.suppressionReason, .noCandidate, "Teams should not prompt only because the app is open")
    }

    runSuite("SyntheticMeetingPrompts — recent runtime activity expires") {
        let recent = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["us.zoom.xos"],
                recentNativeActivity: [.zoom: syntheticPromptNow.addingTimeInterval(-30)]
            )
        )
        let stale = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["us.zoom.xos"],
                recentNativeActivity: [
                    .zoom: syntheticPromptNow.addingTimeInterval(
                        -(MeetingPromptHeuristics.runtimeActivityFreshness + 1)
                    )
                ]
            )
        )

        assertEqual(recent.candidate?.title, "Zoom just opened", "recent native launches should get a softer prompt")
        assertEqual(stale.suppressionReason, .noCandidate, "stale native activity should expire")
    }

    runSuite("SyntheticMeetingPrompts — cooldowns suppress repeat prompts") {
        let candidateID = "calendar:cooldown"
        let pending = evaluateSyntheticPrompt(
            calendarEvents: [syntheticCalendarEvent(id: "cooldown")],
            pendingUntil: [candidateID: syntheticPromptNow.addingTimeInterval(60)]
        )
        let snoozed = evaluateSyntheticPrompt(
            calendarEvents: [syntheticCalendarEvent(id: "cooldown")],
            snoozedUntil: [candidateID: syntheticPromptNow.addingTimeInterval(60)]
        )

        assertEqual(pending.suppressionReason, .pendingCandidate, "pending cooldown should avoid prompt spam")
        assertEqual(snoozed.suppressionReason, .snoozedCandidate, "snooze should avoid prompt spam")
    }

    runSuite("SyntheticMeetingPrompts — runtime suppression blocks app-only follow-up") {
        let result = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["us.zoom.xos"],
                frontmostBundleID: "us.zoom.xos",
                runtimeSuppressedUntil: [.zoom: syntheticPromptNow.addingTimeInterval(60)]
            )
        )

        assertEqual(result.suppressionReason, .noCandidate, "provider runtime suppression should keep app-only prompts quiet")
    }

    runSuite("SyntheticMeetingPrompts — presentation gate suppresses busy meeting states") {
        let idle = MeetingPromptPresentationSnapshot(
            sessionState: .ready,
            overlayState: .idle
        )
        let recording = MeetingPromptPresentationSnapshot(
            sessionState: .recording,
            overlayState: .idle
        )
        let loading = MeetingPromptPresentationSnapshot(
            sessionState: .loadingModels,
            overlayState: .idle
        )
        let overlayBusy = MeetingPromptPresentationSnapshot(
            sessionState: .ready,
            overlayState: .prompt
        )
        let savedOverlay = MeetingPromptPresentationSnapshot(
            sessionState: .idle,
            overlayState: .saved
        )

        assertTrue(MeetingPromptPresentationGate.allowsDetectedMeetingPrompt(idle), "ready + idle overlay should allow prompts")
        assertFalse(MeetingPromptPresentationGate.allowsDetectedMeetingPrompt(recording), "active recording should suppress detected prompts")
        assertFalse(MeetingPromptPresentationGate.allowsDetectedMeetingPrompt(loading), "model loading should suppress detected prompts")
        assertFalse(MeetingPromptPresentationGate.allowsDetectedMeetingPrompt(overlayBusy), "an existing prompt should suppress another prompt")
        assertTrue(MeetingPromptPresentationGate.allowsDetectedMeetingPrompt(savedOverlay), "recent saved state may show a new prompt")
    }

    runSuite("SyntheticMeetingPrompts — evaluator respects presentation gate") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [syntheticCalendarEvent(id: "blocked-recording")],
            presentationSnapshot: MeetingPromptPresentationSnapshot(
                sessionState: .recording,
                overlayState: .idle
            )
        )

        assertFalse(result.shouldPrompt, "valid candidates should stay hidden while recording")
        assertEqual(result.suppressionReason, .presentationBlocked, "busy presentation state should be visible to tests")
    }
}
