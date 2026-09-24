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
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
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

        let output = makeMeetingPromptCandidate(
            id: "mic:zoom",
            provider: .zoom,
            source: .runtimeApp,
            reason: .audioOutput
        )
        assertEqual(output.analyticsCalendarConfidence, "none", "ad-hoc output prompts should not imply calendar evidence")
        assertEqual(output.analyticsCallState, "output_active", "output prompts should record the listen-only call state")
        assertEqual(output.analyticsAppSignal, "native_output", "output attribution is native-only and stays family-level")
    }

    await runSuite("MeetingPromptDetector calendar refresh — prompt evaluations reuse the warm snapshot") {
        let now = Date()
        let box = CandidateBox()
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { true },
            fetchCalendarEventSnapshots: { _, _ in
                box.calendarFetchCount += 1
                return [
                    makeMeetingPromptCalendarSnapshot(
                        id: "warm-calendar",
                        startsIn: 30,
                        now: now
                    )
                ]
            }
        )
        detector.frontmostBundleIDProvider = { nil }
        detector.browserWindowTitlesProvider = { _ in [] }
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.start()
        defer { detector.stop() }
        await waitForPromptEvaluation()
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        detector.updateAudioOutputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()

        assertEqual(box.calendarFetchCount, 1, "signal-driven evaluations should reuse the cached calendar window while it is fresh")
        assertNotNil(box.candidate, "the warm calendar snapshot should still be usable for prompting")
    }

    await runSuite("MeetingPromptDetector calendar refresh — EventKit changes invalidate the warm snapshot") {
        let box = CandidateBox()
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { true },
            fetchCalendarEventSnapshots: { _, _ in
                box.calendarFetchCount += 1
                return []
            }
        )
        detector.frontmostBundleIDProvider = { nil }

        detector.start()
        defer { detector.stop() }
        await waitForPromptEvaluation()
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        await waitForPromptEvaluation()

        assertEqual(box.calendarFetchCount, 2, "calendar changes should force exactly one fresh EventKit read")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — a Meet tab holding the mic prompts an ad-hoc call") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        showBrowserTab("Meet - abc-defg-hij", on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertNotNil(box.candidate, "a Meet tab holding the mic should surface a prompt with no calendar event")
        assertEqual(box.candidate?.id, "mic:googleMeet", "a Meet tab should attribute to Google Meet")
        assertEqual(box.candidate?.title, "Google Meet call detected", "a named call tab should name the call")
        assertEqual(box.candidate?.callEvidence, .tabTitle, "the tab title is the evidence")
        assertEqual(box.candidate?.analyticsAppSignal, "browser_mic", "a named browser call is still a browser signal")
        assertEqual(box.candidate?.reason, .micInput, "mic prompts should record the distinct mic-input reason")
        assertEqual(box.candidate?.source, .runtimeApp, "mic prompts should reuse the runtime source so backoff is unchanged")
        assertEqual(box.candidate?.suggestedTranscriptTitle, nil, "a browser call has no calendar title to suggest")
    }

    await runSuite("MeetingPromptDetector.updateMicInputUsers — never prompts while our own capture is active") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
        detector.shouldSkipPromptEvaluation = { true }
        detector.isOwnCaptureActive = { false }
        detector.browserWindowTitlesProvider = { _ in [] }
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
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
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

        showBrowserTab("Meet - abc-defg-hij", on: detector)
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
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        showBrowserTab("Meet - abc-defg-hij", on: detector)
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
        detector.frontmostBundleIDProvider = { nil }
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

        showBrowserTab("Meet - abc-defg-hij", on: detector)
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
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
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
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        showUnrecognizedBrowserTabWithNoWait(on: detector)
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
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        showUnrecognizedBrowserTabWithNoWait(on: detector)
        detector.start()
        await waitForPromptEvaluation()
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        detector.stop()

        assertEqual(box.promptCount, 1, "generic browser mic should not bypass an already-pending calendar prompt")
        assertEqual(box.candidate?.source, .calendarEvent, "the visible scheduled prompt should keep its calendar context")
        assertEqual(box.candidate?.suggestedTranscriptTitle, "Design review", "the scheduled prompt should keep the meeting title hint")
    }

    await runSuite("MeetingPromptDetector.updateCameraInUse — mic and camera on the same call prompt once") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        showBrowserTab("Meet - abc-defg-hij", on: detector)
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        // The camera turning on for the same call must not raise a second prompt.
        detector.updateCameraInUse(true)
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "a mic call corroborated by the camera should still prompt exactly once")
        assertEqual(box.candidate?.id, "mic:googleMeet", "the de-duped candidate keeps the stable browser-call id")
        assertEqual(box.candidate?.reason, .micInput, "the mic signal wins when both mic and camera are active")
    }

    await runSuite("MeetingPromptDetector.updateCameraInUse — a camera-on with no call app frontmost stays quiet") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        // The test runner is not a browser or conferencing app, so a bare
        // camera-on signal cannot be attributed and must not prompt.
        detector.updateCameraInUse(true)
        await waitForPromptEvaluation()

        assertNil(box.candidate, "a camera-on we cannot attribute to a call app should not prompt")
        assertEqual(box.promptCount, 0, "an unattributable camera signal should never ask the overlay to present")
    }

    await runSuite("MeetingPromptDetector.updateAudioOutputUsers — a listen-only native call prompts without the mic") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateAudioOutputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "sustained Zoom output with the mic idle is a live listen-only call")
        assertEqual(box.candidate?.id, "mic:zoom", "output attribution reuses the stable ad-hoc candidate id")
        assertEqual(box.candidate?.reason, .audioOutput, "the output-led signal keeps its distinct reason")
    }

    await runSuite("MeetingPromptDetector.updateAudioOutputUsers — mic and output on the same call prompt once") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()
        detector.updateAudioOutputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "output corroborating an active mic call must not raise a second prompt")
        assertEqual(box.candidate?.reason, .micInput, "the mic signal wins when both mic and output are active")
    }

    runSuite("MeetingPromptDetector.expire — an unattended countdown re-offers instead of long-dismissing") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        let candidate = makeMeetingPromptCandidate(id: "mic:zoom", source: .runtimeApp, reason: .micInput)

        let before = Date()
        let decision = detector.expire(candidate: candidate)
        let after = Date()

        assertEqual(decision.kind, .expiredReoffer, "the first unattended expiry should schedule a short re-offer")
        assertTrue(
            decision.until >= before.addingTimeInterval(MeetingPromptHeuristics.promptExpiryReofferInterval - 1),
            "the re-offer should wait for the short expiry interval"
        )
        assertTrue(
            decision.until <= after.addingTimeInterval(MeetingPromptHeuristics.promptExpiryReofferInterval + 1),
            "an unattended expiry must not inherit the long dismissal window"
        )
    }

    runSuite("MeetingPromptDetector.expire — repeated unattended expiries fall back to the normal dismissal") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        let candidate = makeMeetingPromptCandidate(id: "mic:zoom", source: .runtimeApp, reason: .micInput)

        var lastDecision: MeetingPromptBackoffDecision?
        for _ in 0..<(MeetingPromptHeuristics.maxPromptExpiryReoffers + 1) {
            lastDecision = detector.expire(candidate: candidate)
        }

        assertEqual(
            lastDecision?.kind,
            .runtimeDefaultFallback,
            "past the re-offer cap an ignored call must inherit the full runtime dismissal backoff"
        )
    }

    runSuite("MeetingPromptDetector.expire — past the re-offer cap does not mark the call declined") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        let candidate = makeMeetingPromptCandidate(id: "mic:zoom", source: .runtimeApp, reason: .micInput)

        for _ in 0..<(MeetingPromptHeuristics.maxPromptExpiryReoffers + 1) {
            _ = detector.expire(candidate: candidate)
        }

        assertEqual(
            detector.dismissStreak(for: .zoom),
            0,
            "an unattended expiry cap must not count as the user tapping Not now"
        )

        _ = detector.dismiss(candidate: candidate)
        assertEqual(
            detector.dismissStreak(for: .zoom),
            1,
            "an explicit Not now after the expiry cap should start the dismiss streak at 1"
        )
    }

    await runSuite("MeetingPromptDetector.expire — a re-offered candidate can prompt again after the interval") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 1, "the initial call should prompt")

        guard let shown = box.candidate else { return }
        _ = detector.expire(candidate: shown)

        // The expiry re-offer is candidate-level only: the provider must NOT be
        // runtime-suppressed, so once the re-offer interval passes the same call
        // can prompt again. We can't fast-forward the clock here, so assert the
        // suppression shape instead: the candidate is snoozed (cooldown), not
        // provider-suppressed.
        detector.updateAudioOutputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "during the re-offer cooldown the same call must stay quiet, not re-prompt instantly")
    }

    await runSuite("MeetingPromptDetector.requestEvaluation — own-capture clear can prompt a live call") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        var ownCapture = true
        detector.isOwnCaptureActive = { ownCapture }
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 0, "a live call must stay quiet while own-capture is active")

        ownCapture = false
        detector.requestEvaluation()
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 1, "clearing own-capture should re-evaluate immediately instead of waiting for the poll")
    }

    await runSuite("MeetingPromptDetector.onUnrecordedCallEnded — a short call ending never nudges") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        detector.onPromptRequest = { _ in true }
        let box = CandidateBox()
        detector.onUnrecordedCallEnded = { _ in
            box.unrecordedCallCount += 1
        }

        // Start and immediately end a detected call. The session ends, but a
        // seconds-long call is far below MissedCallNudgePolicy.minimumCallDuration.
        detector.updateMicInputUsers(["us.zoom.xos"])
        await waitForPromptEvaluation()
        detector.updateMicInputUsers([])
        await waitForPromptEvaluation()

        assertEqual(box.unrecordedCallCount, 0, "a call shorter than the minimum duration must not raise the missed-call nudge")
    }

    await runSuite("MeetingPromptDetector browser evidence — an unrecognized site waits before prompting") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        showBrowserTab("Hacker News", on: detector)
        detector.browserEvidenceTiming = BrowserCallEvidence.Timing(
            corroboratedDelay: 1,
            uncorroboratedDelay: 1,
            titleRecheckInterval: 60
        )
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
        await waitForPromptEvaluation(extraMilliseconds: 0)

        assertEqual(box.promptCount, 0, "an unrecognized site holding the mic must not prompt right away")
        assertEqual(box.suppression?.reason, .awaitingCallEvidence, "the held-back prompt should be reported as waiting for evidence")

        await waitForPromptEvaluation(extraMilliseconds: 1_500)

        assertEqual(box.promptCount, 1, "once the wait runs out the detector should re-check on its own and prompt")
        assertEqual(box.candidate?.id, MeetingPromptDetector.unverifiedBrowserCandidateID, "an unnamed browser call has its own candidate id")
        assertEqual(box.candidate?.title, "Call detected in your browser", "an unnamed browser call keeps the neutral title")
        assertEqual(box.candidate?.callEvidence, .micOnly, "the evidence was time on the mic alone")
    }

    await runSuite("MeetingPromptDetector browser evidence — a voice assistant never prompts") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        showBrowserTab("ChatGPT", on: detector)
        detector.browserEvidenceTiming = BrowserCallEvidence.Timing(
            corroboratedDelay: 0,
            uncorroboratedDelay: 0,
            titleRecheckInterval: 60
        )
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        detector.updateCameraInUse(true)
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 0, "ChatGPT voice holding the mic is not a call, however long it runs")
        assertEqual(box.suppression?.reason, .notACall, "the skip should be reported as not a call")
    }

    await runSuite("MeetingPromptDetector browser evidence — a Teams tab is a Teams call") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        showBrowserTab("Meeting with Ana | Microsoft Teams", on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.microsoft.edgemac.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "a Teams web tab holding the mic should prompt right away")
        assertEqual(box.candidate?.provider, .teams, "the tab title names the provider")
        assertEqual(box.candidate?.id, "mic:teams", "a Teams tab shares the Teams candidate id")
        assertEqual(box.candidate?.title, "Teams call detected", "the prompt should name Teams")
        assertEqual(box.candidate?.analyticsAppSignal, "browser_mic", "it still came from a browser")
    }

    await runSuite("MeetingPromptDetector browser evidence — audio playing back shortens the wait") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        showBrowserTab("Hacker News", on: detector)
        detector.browserEvidenceTiming = BrowserCallEvidence.Timing(
            corroboratedDelay: 0,
            uncorroboratedDelay: 3_600,
            titleRecheckInterval: 3_600
        )
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 0, "mic alone has to wait")

        // Output from another browser does not count.
        detector.updateBrowserOutputUsers(["com.apple.WebKit.GPU"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 0, "Safari playing audio says nothing about Chrome's mic")

        detector.updateBrowserOutputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 1, "the same browser playing audio back corroborates the call")
        assertEqual(box.candidate?.callEvidence, .micAndOutput, "the evidence should say mic and output")
    }

    await runSuite("MeetingPromptDetector browser evidence — Not now to a generic prompt does not hide a Meet tab") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        showUnrecognizedBrowserTabWithNoWait(on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.candidate?.id, MeetingPromptDetector.unverifiedBrowserCandidateID, "the first prompt is the generic browser call")
        if let candidate = box.candidate {
            _ = detector.dismiss(candidate: candidate)
        }
        detector.updateMicInputUsers([])
        await waitForPromptEvaluation()

        showBrowserTab("Meet - abc-defg-hij", on: detector)
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 2, "a real Meet tab right after a Not now to ChatGPT-style mic use should still prompt")
        assertEqual(box.candidate?.id, "mic:googleMeet", "the second prompt is the named Meet call")

        showUnrecognizedBrowserTabWithNoWait(on: detector)
        detector.updateMicInputUsers([])
        await waitForPromptEvaluation()
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 2, "the generic prompt itself stays in its Not now quiet window")
    }

    await runSuite("MeetingPromptDetector learned backoff — a Not now survives a relaunch") {
        let suiteName = "MeetingPromptDetectorTests.learned.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MeetingPromptDetector(learnedBackoffDefaults: defaults)
        first.frontmostBundleIDProvider = { nil }
        first.isOwnCaptureActive = { false }
        showUnrecognizedBrowserTabWithNoWait(on: first)
        let firstBox = CandidateBox()
        first.onPromptRequest = { candidate in
            firstBox.candidate = candidate
            firstBox.promptCount += 1
            return true
        }
        first.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(firstBox.promptCount, 1, "the first browser mic use prompts")
        if let candidate = firstBox.candidate {
            _ = first.dismiss(candidate: candidate)
        }

        let relaunched = MeetingPromptDetector(learnedBackoffDefaults: defaults)
        relaunched.frontmostBundleIDProvider = { nil }
        relaunched.isOwnCaptureActive = { false }
        showUnrecognizedBrowserTabWithNoWait(on: relaunched)
        let box = CandidateBox()
        relaunched.onPromptRequest = { candidate in
            box.promptCount += 1
            return true
        }
        relaunched.onPromptSuppressed = { suppression in
            box.suppression = suppression
        }
        relaunched.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 0, "a relaunch must not reset the Not now")
        assertEqual(box.suppression?.reason, .learnedQuiet, "the skip should say it came from the learned quiet window")
    }

    await runSuite("MeetingPromptDetector browser evidence — ChatGPT voice stays quiet after a tab switch") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        detector.browserEvidenceTiming = instantBrowserEvidenceTiming
        showBrowserTab("ChatGPT", on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.suppression?.reason, .notACall, "precondition: ChatGPT in front is not a call")

        // Voice mode keeps talking in a background tab while the user reads
        // something else, with its reply playing back.
        showBrowserTab("Hacker News", on: detector)
        await waitForPromptEvaluation(extraMilliseconds: 300)
        detector.updateBrowserOutputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 0, "clicking away from ChatGPT must not turn its voice session into a call")

        // A real call can still win.
        showBrowserTab("Meet - abc-defg-hij", on: detector)
        await waitForPromptEvaluation(extraMilliseconds: 300)
        detector.updateBrowserOutputUsers([])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 1, "a Meet tab showing up later in the same session still prompts")
        assertEqual(box.candidate?.id, "mic:googleMeet", "under its real name")
    }

    await runSuite("MeetingPromptDetector browser evidence — a non-call site seen later only holds while in front") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        var timing = instantBrowserEvidenceTiming
        timing.nonCallSiteStickyWindow = -1
        detector.browserEvidenceTiming = timing
        showBrowserTab("Claude", on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 0, "no prompt while the non-call site is in front")

        // Notes in Claude during a call whose tab has no recognizable title.
        showBrowserTab("Hacker News", on: detector)
        await waitForPromptEvaluation(extraMilliseconds: 300)
        detector.updateBrowserOutputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 1, "a site that was not in front when the mic started does not silence the whole call")
    }

    await runSuite("MeetingPromptDetector browser evidence — a Not now survives a muted browser letting go of the mic") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        var timing = instantBrowserEvidenceTiming
        timing.micReleaseGrace = 5
        detector.browserEvidenceTiming = timing
        showBrowserTab("Huddle with Sam - Slack", on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
        }

        detector.updateMicInputUsers(["com.apple.WebKit.GPU"])
        await waitForPromptEvaluation()
        assertEqual(box.candidate?.id, MeetingPromptDetector.browserCallSiteCandidateID, "precondition: the call-site prompt")
        if let candidate = box.candidate {
            _ = detector.dismiss(candidate: candidate)
        }

        // Safari mutes: the mic drops and comes back, and the title reads
        // differently this time.
        showBrowserTab("Hacker News", on: detector)
        detector.updateMicInputUsers([])
        await waitForPromptEvaluation(extraMilliseconds: 300)
        detector.updateMicInputUsers(["com.apple.WebKit.GPU"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "unmuting must not re-ask the call the user just declined")
        assertEqual(box.suppression?.reason, .declinedThisCall, "the Not now still covers the call")
    }

    await runSuite("MeetingPromptDetector browser evidence — a Teams chat tab in the background is not a call") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        detector.browserEvidenceTiming = instantBrowserEvidenceTiming
        showBrowserWindows([
            BrowserWindowTitle(title: "ChatGPT", isFocused: true),
            BrowserWindowTitle(title: "Chat | Microsoft Teams", isFocused: false),
            BrowserWindowTitle(title: "WhatsApp", isFocused: false),
        ], on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 0, "chat apps left open elsewhere must not make ChatGPT voice a call")
        assertEqual(box.suppression?.reason, .notACall, "the focused ChatGPT window decides")
        assertEqual(box.suppression?.candidate.callEvidence, .nonCallSite, "and the telemetry says why")
    }

    await runSuite("MeetingPromptDetector browser evidence — a Not now covers the rest of the call, even by name") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        detector.isOwnCaptureActive = { false }
        showUnrecognizedBrowserTabWithNoWait(on: detector)
        let box = CandidateBox()
        detector.onPromptRequest = { candidate in
            box.candidate = candidate
            box.promptCount += 1
            return true
        }
        detector.onPromptSuppressed = { suppression in
            box.suppression = suppression
        }

        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.candidate?.id, MeetingPromptDetector.unverifiedBrowserCandidateID, "precondition: the generic prompt")
        if let candidate = box.candidate {
            _ = detector.dismiss(candidate: candidate)
        }

        // Same mic session: the user clicks over to the Meet tab.
        showBrowserTab("Meet - abc-defg-hij", on: detector)
        await waitForPromptEvaluation(extraMilliseconds: 300)
        detector.updateBrowserOutputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(box.promptCount, 1, "the call the user just said Not now to must not be re-asked as Google Meet")
        assertEqual(box.suppression?.reason, .declinedThisCall, "the skip should say the call was already declined")
    }

    await runSuite("MeetingPromptDetector learned backoff — never learned off without window titles") {
        let suiteName = "MeetingPromptDetectorTests.learnedOff.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedLearnedOffBrowserMic(in: defaults)

        let withTitles = MeetingPromptDetector(learnedBackoffDefaults: defaults)
        withTitles.frontmostBundleIDProvider = { nil }
        withTitles.isOwnCaptureActive = { false }
        showUnrecognizedBrowserTabWithNoWait(on: withTitles)
        let titledBox = CandidateBox()
        withTitles.onPromptRequest = { _ in
            titledBox.promptCount += 1
            return true
        }
        withTitles.onPromptSuppressed = { suppression in
            titledBox.suppression = suppression
        }
        withTitles.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(titledBox.promptCount, 0, "with titles, three Not nows to an unrecognized site turn it off")
        assertEqual(titledBox.suppression?.cooldownReason, "learned_off", "the skip should say it was learned off")

        let noTitles = MeetingPromptDetector(learnedBackoffDefaults: defaults)
        noTitles.frontmostBundleIDProvider = { nil }
        noTitles.isOwnCaptureActive = { false }
        noTitles.browserEvidenceTiming = instantBrowserEvidenceTiming
        noTitles.browserWindowTitlesProvider = { _ in [] }
        let box = CandidateBox()
        noTitles.onPromptRequest = { _ in
            box.promptCount += 1
            return true
        }
        noTitles.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(box.promptCount, 1, "without Accessibility a real Meet looks the same, so it must still prompt")

        let reset = MeetingPromptDetector(learnedBackoffDefaults: defaults)
        reset.frontmostBundleIDProvider = { nil }
        reset.isOwnCaptureActive = { false }
        showUnrecognizedBrowserTabWithNoWait(on: reset)
        reset.resetLearnedBackoff()
        let resetBox = CandidateBox()
        reset.onPromptRequest = { _ in
            resetBox.promptCount += 1
            return true
        }
        reset.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        assertEqual(resetBox.promptCount, 1, "turning detection off and on (the reset) brings the prompt back")
    }

    await runSuite("MeetingPromptDetector learned backoff — recording before any prompt teaches nothing") {
        let suiteName = "MeetingPromptDetectorTests.manualRecord.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedLearnedOffBrowserMic(in: defaults)

        let detector = MeetingPromptDetector(learnedBackoffDefaults: defaults)
        detector.frontmostBundleIDProvider = { nil }
        detector.ownCaptureActivity = { .meetingRecording }
        showUnrecognizedBrowserTabWithNoWait(on: detector)
        detector.onPromptRequest = { _ in true }

        // Record first (menu or hotkey), then join: the prompt is never
        // considered, so this says nothing about unrecognized browser mics.
        detector.updateMicInputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()
        // A second pass over the same call, while still recording.
        detector.updateBrowserOutputUsers(["com.google.Chrome.helper"])
        await waitForPromptEvaluation()

        assertEqual(
            MeetingPromptLearnedBackoff(userDefaults: defaults).dismissStreak(
                for: MeetingPromptLearnedBackoff.unverifiedBrowserKind,
                now: Date()
            ),
            3,
            "a recording started before any prompt must not clear the learned Not nows"
        )
    }

    runSuite("MeetingPromptDetector.dismissStreak — counts consecutive 'not now's and resets on accept") {
        let detector = MeetingPromptDetector()
        detector.frontmostBundleIDProvider = { nil }
        let candidate = makeMeetingPromptCandidate(id: "mic:zoom", source: .runtimeApp, reason: .micInput)

        assertEqual(detector.dismissStreak(for: .zoom), 0, "a fresh detector has no dismissal history")

        _ = detector.dismiss(candidate: candidate)
        assertEqual(detector.dismissStreak(for: .zoom), 1, "an explicit dismissal starts the streak")

        _ = detector.dismiss(candidate: candidate)
        assertEqual(detector.dismissStreak(for: .zoom), 2, "consecutive dismissals grow the streak")
        assertEqual(detector.dismissStreak(for: .teams), 0, "streaks are per provider")

        detector.markAccepted(candidate: candidate)
        assertEqual(detector.dismissStreak(for: .zoom), 0, "an accepted recording resets the provider's streak")
    }
}

/// Makes the detector see one focused browser window with `title`, instead of
/// reading real windows through Accessibility.
@available(macOS 14.0, *)
@MainActor
private func showBrowserTab(_ title: String, on detector: MeetingPromptDetector) {
    detector.browserWindowTitlesProvider = { _ in [BrowserWindowTitle(title: title, isFocused: true)] }
}

/// An ordinary page (not a call, not a known non-call site) with the
/// unrecognized-site waits removed, so a browser mic prompts at once as the
/// generic browser call.
@available(macOS 14.0, *)
@MainActor
private func showUnrecognizedBrowserTabWithNoWait(on detector: MeetingPromptDetector) {
    showBrowserTab("Hacker News", on: detector)
    detector.browserEvidenceTiming = instantBrowserEvidenceTiming
}

/// No waits, no grace after the mic drops, and title re-reads allowed after
/// a fifth of a second, so a test can change the titles and see them read.
private let instantBrowserEvidenceTiming = BrowserCallEvidence.Timing(
    corroboratedDelay: 0,
    uncorroboratedDelay: 0,
    titleRecheckInterval: 60,
    micReleaseGrace: 0,
    titleReadSpacing: 0.2
)

/// Makes the detector see these browser windows.
@available(macOS 14.0, *)
@MainActor
private func showBrowserWindows(_ windows: [BrowserWindowTitle], on detector: MeetingPromptDetector) {
    detector.browserWindowTitlesProvider = { _ in windows }
}

/// Saves three recent Not nows to an unrecognized browser mic, all past
/// their quiet windows, so only the learned-off rule can keep it quiet.
private func seedLearnedOffBrowserMic(in defaults: UserDefaults) {
    let backoff = MeetingPromptLearnedBackoff(userDefaults: defaults)
    let now = Date()
    for daysAgo in [3.0, 2.0, 1.0] {
        backoff.recordDismissal(
            kind: MeetingPromptLearnedBackoff.unverifiedBrowserKind,
            now: now.addingTimeInterval(-daysAgo * 86_400)
        )
    }
}

@available(macOS 14.0, *)
@MainActor
private final class CandidateBox {
    var candidate: MeetingPromptDetector.Candidate?
    var suppression: MeetingPromptSuppression?
    var promptCount = 0
    var suppressionCount = 0
    var unrecordedCallCount = 0
    var calendarFetchCount = 0
}

// updateMicInputUsers re-evaluates on a detached @MainActor Task; yield/sleep a
// few times so it can run before we assert.
@MainActor
private func waitForPromptEvaluation(extraMilliseconds: UInt64 = 0) async {
    if extraMilliseconds > 0 {
        try? await Task.sleep(nanoseconds: extraMilliseconds * 1_000_000)
    }
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
