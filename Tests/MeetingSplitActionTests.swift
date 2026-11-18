import Foundation

@MainActor
func testMeetingSplitAction() async {
    let app = "us.zoom.xos"
    func snapshot(active: Bool = true, reliable: Bool = true, age: Double = 0) -> MeetingCallActivitySnapshot {
        .init(inputUsers: active ? [app] : [], outputUsers: [], isReliable: reliable,
              sampledAt: ProcessInfo.processInfo.systemUptime - age)
    }
    func rejoined() -> MeetingSessionController {
        let session = MeetingSessionController()
        session.armCallEndTracking(identity: session.activeRecordingIdentity!, families: [app], late: false)
        session.updateCallCameraInUse(false, sampledAt: ProcessInfo.processInfo.systemUptime)
        session.observeCallActivity(snapshot(active: false, age: 11))
        session.observeCallActivity(snapshot(active: false))
        session.observeCallActivity(snapshot())
        return session
    }
    func event(_ id: String, at start: Date, detail: String = "starting") -> MeetingPromptDetector.Candidate {
        .init(id: id, title: "Meeting", detail: detail, provider: .teams, reason: .calendarNearby,
              source: .calendarEvent, startDate: start, endDate: start.addingTimeInterval(1800),
              meetingURL: nil, suggestedTranscriptTitle: "Meeting")
    }

    await runSuite("Rejoin needs continuous call-app evidence and a fresh read before stopping") {
        for read in [snapshot(active: false), snapshot(reliable: false), snapshot(age: 30)] {
            let observed = rejoined()
            assertNotNil(observed.meetingSplitOffer, "the call app returning offers a split")
            observed.observeCallActivity(read)
            assertTrue(observed.meetingSplitOffer == nil, "losing reliable call-app audio clears the offer")

            let accepted = rejoined()
            guard let offer = accepted.meetingSplitOffer else { continue }
            accepted.callActivitySampler = { complete in complete(read) }
            await accepted.acceptMeetingSplit(offer)
            assertEqual(accepted.stops, 0, "an unconfirmed rejoin cannot stop capture")
        }
        let session = rejoined()
        guard let offer = session.meetingSplitOffer else { return }
        session.callActivitySampler = { complete in complete(snapshot()) }
        await session.acceptMeetingSplit(offer)
        assertEqual(session.stops, 1, "fresh reliable audio admits the displayed rejoin")
    }

    await runSuite("Split rechecks warnings and recording ownership after refreshing") {
        for hazard in ["system", "route", "inactivity", "recording", "replacement"] {
            let session = rejoined()
            guard let offer = session.meetingSplitOffer else { return }
            session.callActivitySampler = { complete in
                switch hazard {
                case "system":
                    session.systemAudioDegradationWarning = .init(cause: .failure, phase: .degraded, isPromptDismissed: false)
                case "route": session.audioRouteWarning = true
                case "inactivity": session.audioInactivityWarning = .init(inactiveDuration: 30, countdownSeconds: 10)
                case "recording": session.activeRecordingIdentity = UUID()
                default:
                    session.observeCallActivity(snapshot(active: false))
                    session.offerCallRejoinSplit()
                }
                complete(snapshot())
            }
            await session.acceptMeetingSplit(offer)
            assertEqual(session.stops, 0, "a concurrent \(hazard) cancels the stale action")
        }
    }

    runSuite("Keep recording applies only to the displayed event and recording") {
        let start = Date()
        let session = MeetingSessionController()
        var declined: [String] = []
        session.onMeetingSplitDecision = { event, decision in
            if case .declined = decision { declined.append(event.id) }
        }
        _ = session.refreshCalendarSplit(candidates: [event("A", at: start)])
        guard let first = session.meetingSplitOffer else { return }
        _ = session.refreshCalendarSplit(candidates: [event("B", at: start)])
        session.declineMeetingSplit(first)
        assertEqual(session.meetingSplitOffer?.candidate?.id, "B", "a replacement keeps its prompt")
        guard let originalTime = session.meetingSplitOffer else { return }
        let newTime = start.addingTimeInterval(45)
        _ = session.refreshCalendarSplit(candidates: [event("B", at: newTime)])
        session.declineMeetingSplit(originalTime)
        assertTrue(declined.isEmpty, "a rescheduled event cannot inherit the old tap")
        guard let rescheduled = session.meetingSplitOffer else { return }
        _ = session.refreshCalendarSplit(candidates: [event("B", at: newTime, detail: "now")])
        session.declineMeetingSplit(rescheduled)
        assertEqual(declined, ["B"], "copy refresh preserves the displayed action")
    }

    await runSuite("A calendar refresh cannot stop through concurrent recording warnings") {
        let start = Date()
        let session = MeetingSessionController()
        _ = session.refreshCalendarSplit(candidates: [event("A", at: start)])
        guard let offer = session.meetingSplitOffer else { return }
        session.refreshCalendarForSplitAcceptance = {
            session.systemAudioDegradationWarning = .init(cause: .failure, phase: .degraded, isPromptDismissed: false)
            session.audioRouteWarning = true
            return true
        }
        await session.acceptMeetingSplit(offer)
        session.refreshCalendarForSplitAcceptance = { true }
        session.systemAudioDegradationWarning = session.systemAudioDegradationWarning?.dismissingPrompt()
        await session.acceptMeetingSplit(offer)
        assertEqual(session.stops, 0, "acknowledging system audio leaves the route warning in charge")
        session.audioRouteWarning = nil
        await session.acceptMeetingSplit(offer)
        assertEqual(session.stops, 1, "an acknowledged degradation no longer covers the offer")
    }

    await runSuite("Calendar actions match the displayed event across copy refreshes") {
        let start = Date()
        let session = MeetingSessionController()
        _ = session.refreshCalendarSplit(candidates: [event("A", at: start)])
        guard let displayed = session.meetingSplitOffer else { return }
        session.refreshCalendarForSplitAcceptance = {
            session.refreshCalendarSplit(candidates: [event("A", at: start, detail: "now")])
        }
        await session.acceptMeetingSplit(displayed)
        assertEqual(session.stops, 1, "generated countdown copy does not invalidate the action")
    }
}
