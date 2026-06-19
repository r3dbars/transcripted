import Foundation

@available(macOS 14.0, *)
private let syntheticPromptNow = Date(timeIntervalSince1970: 10_000)

@available(macOS 14.0, *)
private func syntheticRuntimeSnapshot(
    runningBundleIDs: Set<String> = [],
    frontmostBundleID: String? = nil,
    recentNativeActivity: [MeetingPromptProvider: Date] = [:],
    runtimeSuppressedUntil: [MeetingPromptProvider: Date] = [:],
    micActiveBundleIDs: Set<String> = [],
    isOwnCaptureActive: Bool = false,
    isMicInputPromptEnabled: Bool = true
) -> MeetingPromptRuntimeSnapshot {
    MeetingPromptRuntimeSnapshot(
        runningBundleIDs: runningBundleIDs,
        frontmostBundleID: frontmostBundleID,
        recentNativeActivity: recentNativeActivity,
        runtimeSuppressedUntil: runtimeSuppressedUntil,
        micActiveBundleIDs: micActiveBundleIDs,
        isOwnCaptureActive: isOwnCaptureActive,
        isMicInputPromptEnabled: isMicInputPromptEnabled
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

    runSuite("SyntheticMeetingPrompts — browser WebRTC mic activity prompts without Calendar") {
        let result = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: [
                    "com.google.Chrome.helper",
                    "com.apple.WebKit.GPU"
                ]
            )
        )

        assertTrue(result.shouldPrompt, "a browser process holding the mic is strong enough for an ad-hoc call prompt")
        assertEqual(result.candidate?.id, "mic:googleMeet", "browser helper noise should collapse to one stable browser-call candidate")
        assertEqual(result.candidate?.title, "Call detected in your browser", "browser WebRTC copy should stay provider-neutral")
        assertEqual(result.candidate?.reason, .micInput, "mic activity should keep its own analytics reason")
        assertNil(result.candidate?.suggestedTranscriptTitle, "ad-hoc browser calls should not invent a calendar title")
    }

    runSuite("SyntheticMeetingPrompts — native Zoom mic plus Calendar keeps the scheduled prompt") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(id: "zoom-native-mic", startsIn: 20)
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: ["us.zoom.xos"]
            )
        )

        assertEqual(result.candidate?.id, "calendar:zoom-native-mic", "native Zoom mic evidence should not replace a matching calendar prompt")
        assertEqual(result.candidate?.source, .calendarEvent, "the prompt should keep calendar context for title handoff")
        assertEqual(result.candidate?.suggestedTranscriptTitle, "Design review", "calendar-backed native calls should keep the meeting title hint")
    }

    runSuite("SyntheticMeetingPrompts — browser mic stays neutral unless a calendar prompt is already pending") {
        let activeBrowserCall = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(
                    id: "meet-calendar",
                    startsIn: 20,
                    url: URL(string: "https://meet.google.com/abc-defg-hij")
                )
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: ["com.google.Chrome.helper"]
            )
        )
        let pendingCalendar = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(
                    id: "meet-calendar",
                    startsIn: 20,
                    url: URL(string: "https://meet.google.com/abc-defg-hij")
                )
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: ["com.google.Chrome.helper"]
            ),
            pendingUntil: ["calendar:meet-calendar": syntheticPromptNow.addingTimeInterval(60)]
        )
        let expiredCalendarCooldown = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(
                    id: "meet-calendar",
                    startsIn: 20,
                    url: URL(string: "https://meet.google.com/abc-defg-hij")
                )
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: ["com.google.Chrome.helper"]
            ),
            snoozedUntil: ["calendar:meet-calendar": syntheticPromptNow.addingTimeInterval(-1)],
            pendingUntil: ["calendar:meet-calendar": syntheticPromptNow.addingTimeInterval(-1)]
        )

        assertEqual(activeBrowserCall.candidate?.id, "mic:googleMeet", "generic browser calls should not borrow a possibly unrelated calendar title")
        assertNil(activeBrowserCall.candidate?.suggestedTranscriptTitle, "browser calls may be Meet, Zoom web, or Teams web")
        assertFalse(pendingCalendar.shouldPrompt, "browser mic should not bypass a visible scheduled prompt")
        assertEqual(pendingCalendar.suppressionReason, .pendingCandidate, "pending calendar prompt should explain the quiet repeat")
        assertEqual(expiredCalendarCooldown.candidate?.id, "mic:googleMeet", "expired calendar cooldowns should not steal a live browser mic prompt")
    }

    runSuite("SyntheticMeetingPrompts — mic app flags suppress stale callbacks") {
        let disabled = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: ["com.google.Chrome.helper"],
                isMicInputPromptEnabled: false
            )
        )
        let ownCapture = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: ["com.google.Chrome.helper"],
                isOwnCaptureActive: true
            )
        )

        assertEqual(disabled.suppressionReason, .micInputDisabled, "disabled auto-call detection should suppress late mic callbacks")
        assertEqual(ownCapture.suppressionReason, .ownCaptureActive, "our own recording or dictation should suppress mic prompts")
    }

    runSuite("SyntheticMeetingPrompts — duplicate mic route noise respects pending cooldown") {
        let firstPass = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: [
                    "com.google.Chrome.helper",
                    "com.google.Chrome.helper.audio",
                    "com.apple.WebKit.GPU"
                ]
            )
        )
        let repeatPass = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                micActiveBundleIDs: [
                    "com.google.Chrome.helper",
                    "com.google.Chrome.helper.audio",
                    "com.apple.WebKit.GPU"
                ]
            ),
            pendingUntil: ["mic:googleMeet": syntheticPromptNow.addingTimeInterval(60)]
        )

        assertEqual(firstPass.candidate?.id, "mic:googleMeet", "noisy browser helpers should still produce one candidate id")
        assertFalse(repeatPass.shouldPrompt, "pending mic prompts should not repeat while helper processes churn")
        assertEqual(repeatPass.suppressionReason, .pendingCandidate, "repeat mic route noise should classify as pending")
    }

    runSuite("SyntheticMeetingPrompts — native runtime prompts are provider-limited") {
        let webex = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["com.cisco.webexmeetingsapp"],
                frontmostBundleID: "com.cisco.webexmeetingsapp"
            )
        )
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

        assertEqual(webex.candidate?.id, "runtime:webex", "Webex can prompt from runtime evidence")
        assertEqual(webex.candidate?.title, "Webex is active", "frontmost native runtime prompt should use active copy")
        assertEqual(zoom.suppressionReason, .noCandidate, "Zoom app-open evidence alone should stay quiet without calendar context")
        assertEqual(teams.suppressionReason, .noCandidate, "Teams should not prompt only because the app is open")
    }

    runSuite("SyntheticMeetingPrompts — recent runtime activity expires") {
        let recent = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["com.cisco.webexmeetingsapp"],
                recentNativeActivity: [.webex: syntheticPromptNow.addingTimeInterval(-30)]
            )
        )
        let stale = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["com.cisco.webexmeetingsapp"],
                recentNativeActivity: [
                    .webex: syntheticPromptNow.addingTimeInterval(
                        -(MeetingPromptHeuristics.runtimeActivityFreshness + 1)
                    )
                ]
            )
        )

        assertEqual(recent.candidate?.title, "Webex just opened", "recent native launches should get a softer prompt")
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

    runSuite("SyntheticMeetingPrompts — expired cooldowns allow a calendar prompt to return") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [syntheticCalendarEvent(id: "expired-cooldown")],
            snoozedUntil: ["calendar:expired-cooldown": syntheticPromptNow.addingTimeInterval(-1)],
            pendingUntil: ["calendar:expired-cooldown": syntheticPromptNow.addingTimeInterval(-1)]
        )

        assertTrue(result.shouldPrompt, "expired pending and snooze entries should not create a prompt loop")
        assertEqual(result.candidate?.id, "calendar:expired-cooldown", "the original calendar candidate should return")
    }

    runSuite("SyntheticMeetingPrompts — calendar pending state does not fall through to another popup") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(id: "primary-calendar", startsIn: 10),
                syntheticCalendarEvent(id: "secondary-calendar", startsIn: 45)
            ],
            pendingUntil: ["calendar:primary-calendar": syntheticPromptNow.addingTimeInterval(60)]
        )

        assertFalse(result.shouldPrompt, "a visible calendar prompt should suppress other calendar prompts in the same pass")
        assertEqual(result.suppressionReason, .pendingCandidate, "the pending top candidate should explain the suppression")
    }

    runSuite("SyntheticMeetingPrompts — app-only pending state does not double-trigger") {
        let result = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: [
                    "com.cisco.webexmeetingsapp",
                    "com.apple.FaceTime"
                ],
                frontmostBundleID: "com.cisco.webexmeetingsapp",
                recentNativeActivity: [.facetime: syntheticPromptNow.addingTimeInterval(-30)]
            ),
            pendingUntil: ["runtime:webex": syntheticPromptNow.addingTimeInterval(60)]
        )

        assertFalse(result.shouldPrompt, "an app-only prompt that is already visible should not fall through to another app")
        assertEqual(result.suppressionReason, .pendingCandidate, "pending app prompts should be treated as active popups")
    }

    runSuite("SyntheticMeetingPrompts — dismissed calendar prompt suppresses lower-priority app fallback") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(id: "dismissed-zoom", startsIn: 10)
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: [
                    "us.zoom.xos",
                    "com.cisco.webexmeetingsapp"
                ],
                frontmostBundleID: "us.zoom.xos",
                recentNativeActivity: [.webex: syntheticPromptNow.addingTimeInterval(-30)]
            ),
            snoozedUntil: ["calendar:dismissed-zoom": syntheticPromptNow.addingTimeInterval(60)]
        )

        assertFalse(result.shouldPrompt, "a dismissed calendar prompt should not immediately reappear as an app prompt")
        assertEqual(result.suppressionReason, .snoozedCandidate, "dismissed prompt cooldown should win over fallback candidates")
    }

    runSuite("SyntheticMeetingPrompts — runtime suppression blocks app-only follow-up") {
        let result = evaluateSyntheticPrompt(
            calendarAccessGranted: false,
            calendarEvents: [],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["com.cisco.webexmeetingsapp"],
                frontmostBundleID: "com.cisco.webexmeetingsapp",
                runtimeSuppressedUntil: [.webex: syntheticPromptNow.addingTimeInterval(60)]
            )
        )

        assertEqual(result.suppressionReason, .noCandidate, "provider runtime suppression should keep app-only prompts quiet")
    }

    runSuite("SyntheticMeetingPrompts — active recording suppresses calendar and app signals together") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [syntheticCalendarEvent(id: "recording-zoom", startsIn: 10)],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: [
                    "us.zoom.xos",
                    "com.cisco.webexmeetingsapp"
                ],
                frontmostBundleID: "us.zoom.xos",
                recentNativeActivity: [.webex: syntheticPromptNow.addingTimeInterval(-30)]
            ),
            presentationSnapshot: MeetingPromptPresentationSnapshot(
                sessionState: .recording,
                overlayState: .idle
            )
        )

        assertFalse(result.shouldPrompt, "prompt detection should stay quiet while Transcripted is recording")
        assertEqual(result.suppressionReason, .presentationBlocked, "active recording should use the presentation gate")
    }

    runSuite("SyntheticMeetingPrompts — existing popup suppresses another valid popup") {
        let result = evaluateSyntheticPrompt(
            calendarEvents: [syntheticCalendarEvent(id: "overlay-prompt", startsIn: 10)],
            presentationSnapshot: MeetingPromptPresentationSnapshot(
                sessionState: .ready,
                overlayState: .prompt
            )
        )

        assertFalse(result.shouldPrompt, "a detected-meeting prompt should not stack another prompt on top")
        assertEqual(result.suppressionReason, .presentationBlocked, "existing prompt state should block reevaluation")
    }

    runSuite("SyntheticMeetingPrompts — Zoom and browser WebRTC calendar routes behave once") {
        let zoom = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(id: "zoom-webrtc-route", startsIn: 10)
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["us.zoom.xos", "com.google.Chrome"],
                frontmostBundleID: "us.zoom.xos"
            )
        )
        let zoomRepeat = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(id: "zoom-webrtc-route", startsIn: 10)
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                runningBundleIDs: ["us.zoom.xos", "com.google.Chrome"],
                frontmostBundleID: "us.zoom.xos"
            ),
            pendingUntil: ["calendar:zoom-webrtc-route": syntheticPromptNow.addingTimeInterval(60)]
        )
        let browserWebRTC = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(
                    id: "meet-webrtc-route",
                    startsIn: 10,
                    url: URL(string: "https://meet.google.com/abc-defg-hij")
                )
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                frontmostBundleID: "com.google.Chrome"
            )
        )
        let browserWebRTCRepeat = evaluateSyntheticPrompt(
            calendarEvents: [
                syntheticCalendarEvent(
                    id: "meet-webrtc-route",
                    startsIn: 10,
                    url: URL(string: "https://meet.google.com/abc-defg-hij")
                )
            ],
            runtimeSnapshot: syntheticRuntimeSnapshot(
                frontmostBundleID: "com.google.Chrome"
            ),
            pendingUntil: ["calendar:meet-webrtc-route": syntheticPromptNow.addingTimeInterval(60)]
        )

        assertEqual(zoom.candidate?.id, "calendar:zoom-webrtc-route", "Zoom route evidence plus Calendar should stay one calendar prompt")
        assertEqual(zoom.candidate?.reason, .calendarPlusRuntimeMatch, "Zoom app evidence should strengthen the calendar prompt")
        assertEqual(zoomRepeat.suppressionReason, .pendingCandidate, "Zoom route repeats should stay quiet while the prompt is pending")
        assertEqual(browserWebRTC.candidate?.id, "calendar:meet-webrtc-route", "browser WebRTC evidence plus Calendar should stay one calendar prompt")
        assertEqual(browserWebRTC.candidate?.reason, .calendarPlusRuntimeMatch, "browser WebRTC evidence should strengthen browser-hosted calendar prompts")
        assertEqual(browserWebRTCRepeat.suppressionReason, .pendingCandidate, "browser WebRTC route repeats should stay quiet while the prompt is pending")
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
