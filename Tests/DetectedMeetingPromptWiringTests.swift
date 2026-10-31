// DetectedMeetingPromptWiringTests.swift
// The app connects the meeting prompt detector to the call prompt on the island
// through DetectedMeetingPromptWiring. These tests install that wiring on a real
// detector and a real pill controller, then drive the detector's own hook and the
// island's buttons, so a dropped connection fails here instead of shipping with
// the suite green.

import Foundation

@MainActor
func testDetectedMeetingPromptWiring() async {
    guard #available(macOS 14.0, *) else { return }

    runSuite("a detected call reaches the island and reports that it was shown") {
        let rig = WiringRig()
        rig.install()

        let candidate = wiringCandidate(id: "wiring-a", reason: .micInput)
        let presented = rig.detector.onPromptRequest?(candidate)

        assertEqual(presented, .presented, "the detector hook reports the prompt as shown")
        assertEqual(rig.shown, ["wiring-a"], "the app is told which prompt reached the island")
        assertEqual(
            rig.island.prompt,
            NotchIslandCallPromptContent(title: candidate.title, detail: candidate.detail, secondsLeft: 60),
            "an ad-hoc call gets the longer timeout and its own detail line"
        )
    }

    runSuite("the detail override replaces the candidate's detail line") {
        let rig = WiringRig()
        rig.detailOverride = "Mic only"
        rig.install()

        _ = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-b", reason: .calendarNearby))

        assertEqual(rig.island.prompt?.detail, "Mic only", "the override reaches the island")
        assertEqual(rig.island.prompt?.secondsLeft, 30, "a calendar prompt gets the default timeout")
    }

    runSuite("nothing is shown before first-run setup finishes") {
        let rig = WiringRig()
        rig.onboardingCompleted = false
        rig.install()

        let presented = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-c", reason: .micInput))

        assertEqual(presented, .skipped, "the detector is told the prompt was blocked")
        assertTrue(rig.island.prompt == nil, "the island stays empty")
        assertEqual(rig.shown, [], "no shown event for a prompt nobody saw")
    }

    runSuite("a prompt with no island is not reported as shown") {
        let rig = WiringRig()
        rig.install()
        rig.pill.island = nil

        let presented = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-d", reason: .micInput))

        assertEqual(presented, .skipped, "with no island there is nowhere to show it")
        assertEqual(rig.shown, [], "no shown event")
    }

    runSuite("each island answer reaches its own app callback") {
        let rig = WiringRig()
        rig.install()
        let candidate = wiringCandidate(id: "wiring-e", reason: .micInput)

        _ = rig.detector.onPromptRequest?(candidate)
        rig.island.callActionHandler?(.callRecord)
        _ = rig.detector.onPromptRequest?(candidate)
        rig.island.callActionHandler?(.callDismiss)
        _ = rig.detector.onPromptRequest?(candidate)
        rig.island.callActionHandler?(.callRemind)

        assertEqual(rig.answers, ["record:wiring-e", "dismiss:wiring-e", "remind:wiring-e"], "Record, Not now and Remind soon each land once")
    }

    runSuite("the expiry callback is the app's") {
        let rig = WiringRig()
        rig.install()
        let candidate = wiringCandidate(id: "wiring-f", reason: .micInput)

        rig.pill.onExpired?(candidate)

        assertEqual(rig.answers, ["expire:wiring-f"], "an unanswered prompt reports expiry to the app")
    }

    runSuite("an auto-start decision uses the Record path and skips the island prompt") {
        let rig = WiringRig()
        rig.decision = { _ in .autoStart }
        rig.install()

        let presented = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-g", reason: .micInput))

        assertEqual(presented, .autoStarted, "the detector still treats the call as handled")
        assertTrue(rig.island.prompt == nil, "auto-start must not show Record / Not now")
        assertEqual(rig.shown, [], "no shown event for a prompt nobody saw")
        assertEqual(rig.autoStarts, ["wiring-g"], "auto-start reaches the existing Record start path")
        assertEqual(rig.answers, [], "Record is not a user tap when auto-start fires")
    }

    runSuite("an auto-start that bails at kickoff falls back to the island prompt") {
        let rig = WiringRig()
        rig.decision = { _ in .autoStart }
        rig.autoStartSucceeds = false
        rig.install()

        let presented = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-bail", reason: .micInput))

        assertEqual(presented, .presented, "a failed kickoff must still offer Record / Not now")
        assertEqual(rig.autoStarts, ["wiring-bail"], "the Record path was still asked")
        assertEqual(rig.shown, ["wiring-bail"], "the island prompt appears instead of a silent wait")
        assertTrue(rig.island.prompt != nil, "the user can still tap Record")
    }

    runSuite("an auto-start that bails because a recording is already running does not show a prompt") {
        let rig = WiringRig()
        rig.decision = { _ in .autoStart }
        rig.autoStartSucceeds = false
        rig.detector.shouldSkipPromptEvaluation = { true }
        rig.install()

        let presented = rig.detector.onPromptRequest?(
            wiringCandidate(id: "wiring-busy", reason: .micInput)
        )

        assertEqual(presented, .skipped, "a live recording must not get a detection prompt stacked on it")
        assertEqual(rig.autoStarts, ["wiring-busy"], "kickoff was still asked")
        assertTrue(rig.island.prompt == nil, "the island stays on the recording")
        assertEqual(rig.shown, [], "no shown event for a prompt nobody should see")
    }

    runSuite("recovering a failed auto-start while a recording is running does not show a prompt") {
        let rig = WiringRig()
        rig.decision = { _ in .autoStart }
        rig.install()
        let candidate = wiringCandidate(id: "wiring-busy-recover", reason: .micInput)

        let first = rig.detector.onPromptRequest?(candidate)
        assertEqual(first, .autoStarted, "precondition: auto-start reported success")
        rig.detector.shouldSkipPromptEvaluation = { true }
        rig.detector.recoverFailedAutoStart(candidate: candidate)

        assertTrue(rig.island.prompt == nil, "the island stays on the recording")
        assertEqual(rig.shown, [], "no shown event while a recording is already running")
    }

    runSuite("a start that bails after autoStarted falls back to the island prompt") {
        let rig = WiringRig()
        rig.decision = { _ in .autoStart }
        rig.install()
        let candidate = wiringCandidate(id: "wiring-recover", reason: .micInput)

        let first = rig.detector.onPromptRequest?(candidate)
        assertEqual(first, .autoStarted, "precondition: auto-start reported success")
        assertTrue(rig.island.prompt == nil, "precondition: the island stayed empty")

        rig.detector.recoverFailedAutoStart(candidate: candidate)

        assertTrue(rig.island.prompt != nil, "the island prompt appears after capture bails")
        assertEqual(rig.shown, ["wiring-recover"], "the user sees Record / Not now instead of a 90-second wait")
    }

    runSuite("a none decision leaves the island empty") {
        let rig = WiringRig()
        rig.decision = { _ in .none }
        rig.install()

        let presented = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-h", reason: .micInput))

        assertEqual(presented, .skipped, "the detector is told nothing was shown")
        assertTrue(rig.island.prompt == nil, "nothing stacks on an already-running capture")
        assertEqual(rig.autoStarts, [], "auto-start does not fire")
        assertEqual(rig.shown, [], "no shown event")
    }

    runSuite("the real auto-record decision auto-starts a proven native Zoom call") {
        let rig = WiringRig()
        rig.decision = { candidate in
            DetectedMeetingPromptWiring.autoRecordDecision(
                for: candidate,
                otherCaptureActive: false,
                autoRecordEnabled: true,
                microphoneGranted: true,
                systemAudioGranted: true
            )
        }
        rig.install()

        let presented = rig.detector.onPromptRequest?(
            wiringCandidate(id: "wiring-real-zoom", reason: .micInput, provenNativeZoom: true)
        )

        assertEqual(presented, .autoStarted, "the detector still treats the call as handled")
        assertTrue(rig.island.prompt == nil, "a proven call must not show Record / Not now")
        assertEqual(rig.autoStarts, ["wiring-real-zoom"], "the real policy must reach the Record start path")
        assertEqual(rig.shown, [], "no shown event for a prompt nobody saw")
    }

    runSuite("the real auto-record decision never auto-starts a tab title without the mic") {
        let rig = WiringRig()
        rig.decision = { candidate in
            DetectedMeetingPromptWiring.autoRecordDecision(
                for: candidate,
                otherCaptureActive: false,
                autoRecordEnabled: true,
                microphoneGranted: true,
                systemAudioGranted: true
            )
        }
        rig.install()

        var candidate = wiringCandidate(id: "wiring-tab", reason: .cameraInput)
        candidate.callEvidence = .tabTitle
        candidate.holdsMicrophone = false
        candidate.isFocusedFrontWindow = true
        candidate.evidenceAge = MeetingAutoRecordPolicy.evidenceHoldDuration
        let presented = rig.detector.onPromptRequest?(candidate)

        assertEqual(presented, .presented, "the island prompt is still offered")
        assertEqual(rig.autoStarts, [], "a tab title without the mic must not auto-start")
        assertEqual(rig.shown, ["wiring-tab"], "the existing Record prompt still appears")
    }

    runSuite("the real auto-record decision keeps a calendar prompt while dictating") {
        let rig = WiringRig()
        rig.decision = { candidate in
            DetectedMeetingPromptWiring.autoRecordDecision(
                for: candidate,
                otherCaptureActive: true,
                autoRecordEnabled: false,
                microphoneGranted: true,
                systemAudioGranted: true
            )
        }
        rig.install()

        let presented = rig.detector.onPromptRequest?(
            wiringCandidate(id: "wiring-cal", reason: .calendarNearby)
        )

        assertEqual(presented, .presented, "dictation must not drop calendar prompts when auto-record is off")
        assertEqual(rig.autoStarts, [], "auto-start does not fire")
        assertEqual(rig.shown, ["wiring-cal"], "the calendar prompt still reaches the island")
    }

    runSuite("the real auto-record decision keeps a Zoom calendar event plus a background Zoom Meeting tab as a prompt") {
        let rig = WiringRig()
        rig.decision = { candidate in
            DetectedMeetingPromptWiring.autoRecordDecision(
                for: candidate,
                otherCaptureActive: false,
                autoRecordEnabled: true,
                microphoneGranted: true,
                systemAudioGranted: true
            )
        }
        rig.install()

        var candidate = wiringCandidate(
            id: "wiring-cal-zoom-tab",
            reason: .calendarNearby,
            source: .calendarEvent
        )
        candidate.holdsMicrophone = true
        candidate.isFocusedFrontWindow = false
        candidate.evidenceAge = MeetingAutoRecordPolicy.evidenceHoldDuration
        candidate.borrowedProofSource = .tabTitle
        let presented = rig.detector.onPromptRequest?(candidate)

        assertEqual(presented, .presented, "the island prompt is still offered")
        assertEqual(rig.autoStarts, [], "a background Zoom Meeting tab must not auto-start")
        assertEqual(rig.shown, ["wiring-cal-zoom-tab"], "the existing Record prompt still appears")
    }

    runSuite("the real auto-record decision keeps a Teams calendar event plus a background Teams tab as a prompt") {
        let rig = WiringRig()
        rig.decision = { candidate in
            DetectedMeetingPromptWiring.autoRecordDecision(
                for: candidate,
                otherCaptureActive: false,
                autoRecordEnabled: true,
                microphoneGranted: true,
                systemAudioGranted: true
            )
        }
        rig.install()

        var candidate = wiringCandidate(
            id: "wiring-cal-teams-tab",
            reason: .calendarNearby,
            source: .calendarEvent,
            provider: .teams
        )
        candidate.holdsMicrophone = true
        candidate.isFocusedFrontWindow = false
        candidate.evidenceAge = MeetingAutoRecordPolicy.evidenceHoldDuration
        candidate.borrowedProofSource = .tabTitle
        let presented = rig.detector.onPromptRequest?(candidate)

        assertEqual(presented, .presented, "the island prompt is still offered")
        assertEqual(rig.autoStarts, [], "a background Teams tab must not auto-start")
        assertEqual(rig.shown, ["wiring-cal-teams-tab"], "the existing Record prompt still appears")
    }

    runSuite("the real auto-record decision auto-starts a proven call even when the candidate is a calendar event") {
        let rig = WiringRig()
        rig.decision = { candidate in
            DetectedMeetingPromptWiring.autoRecordDecision(
                for: candidate,
                otherCaptureActive: false,
                autoRecordEnabled: true,
                microphoneGranted: true,
                systemAudioGranted: true
            )
        }
        rig.install()

        let presented = rig.detector.onPromptRequest?(
            wiringCandidate(
                id: "wiring-cal-proof",
                reason: .calendarNearby,
                source: .calendarEvent,
                provenNativeZoom: true
            )
        )

        assertEqual(presented, .autoStarted, "the detector still treats the call as handled")
        assertTrue(rig.island.prompt == nil, "a proven call must not show Record / Not now just because a calendar event also matched")
        assertEqual(rig.autoStarts, ["wiring-cal-proof"], "calendar enrichment must not block auto-start")
        assertEqual(rig.shown, [], "no shown event for a prompt nobody saw")
    }

    runSuite("live system-audio is not read when auto-record is off") {
        var liveCalls = 0
        var cachedCalls = 0
        let decision = DetectedMeetingPromptWiring.autoRecordDecision(
            for: wiringCandidate(id: "wiring-tcc-off", reason: .calendarNearby),
            otherCaptureActive: false,
            autoRecordEnabled: false,
            microphoneGranted: true,
            liveSystemAudio: {
                liveCalls += 1
                return true
            },
            cachedSystemAudio: {
                cachedCalls += 1
                return true
            }
        )
        assertEqual(decision, .prompt, "the setting off keeps today's prompt")
        assertEqual(liveCalls, 0, "auto-record off must not peek live TCC")
        assertEqual(cachedCalls, 1, "the saved grant is enough when auto-record is off")
    }

    runSuite("live system-audio is peeked when auto-record is on") {
        var liveCalls = 0
        var cachedCalls = 0
        let decision = DetectedMeetingPromptWiring.autoRecordDecision(
            for: wiringCandidate(id: "wiring-tcc-on", reason: .micInput, provenNativeZoom: true),
            otherCaptureActive: false,
            autoRecordEnabled: true,
            microphoneGranted: true,
            liveSystemAudio: {
                liveCalls += 1
                return true
            },
            cachedSystemAudio: {
                cachedCalls += 1
                return false
            }
        )
        assertEqual(decision, .autoStart, "a proven call auto-starts from the live grant")
        assertEqual(liveCalls, 1, "auto-record on peeks live TCC")
        assertEqual(cachedCalls, 0, "the saved grant is not rewritten or used as a stand-in")
    }

    await runSuite("detector to recordPrompt auto-starts a proven Zoom call") {
        let rig = WiringRig()
        rig.decision = { candidate in
            DetectedMeetingPromptWiring.autoRecordDecision(
                for: candidate,
                otherCaptureActive: false,
                autoRecordEnabled: true,
                microphoneGranted: true,
                systemAudioGranted: true
            )
        }
        rig.install()
        rig.detector.isOwnCaptureActive = { false }
        rig.detector.isAutoRecordEnabled = { true }
        rig.detector.autoRecordEvidenceHoldDuration = 0
        rig.detector.nativeMicSince[.zoom] = Date().addingTimeInterval(
            -MeetingAutoRecordPolicy.evidenceHoldDuration
        )

        rig.detector.updateMicInputUsers(["us.zoom.xos"])
        await rig.detector.waitUntilEvaluationsSettle()

        assertEqual(rig.autoStarts, ["mic:zoom"], "evaluate must reach recordPrompt through auto-start")
        assertEqual(rig.shown, [], "auto-start must not report a shown prompt")
        assertTrue(rig.island.prompt == nil, "the island stays empty")
        assertEqual(
            rig.detector.detectedCallSession?.promptShown,
            false,
            "the funnel must not count auto-start as a shown prompt"
        )
    }
}

@available(macOS 14.0, *)
@MainActor
private final class WiringRig {
    let detector = MeetingPromptDetector(
        calendarAccessGranted: { false },
        calendarEventSnapshots: [],
        refreshesCalendarEventSnapshots: false,
        fetchCalendarEventSnapshots: { _, _ in [] },
        learnedBackoffDefaults: nil,
        meetingShortcutDisplay: { "⌥M" }
    )
    let pill = CapturePillController()
    let island = WiringFakeIsland()
    var onboardingCompleted = true
    var detailOverride: String?
    var shown: [String] = []
    var answers: [String] = []
    var autoStarts: [String] = []
    var autoStartSucceeds = true
    var decision: (MeetingPromptDetector.Candidate) -> MeetingAutoRecordPolicy.Decision = { _ in .prompt }

    init() {
        detector.isAutoRecordEnabled = { false }
        detector.frontmostBundleIDProvider = { nil }
        detector.runningBundleIDsProvider = { [] }
        detector.browserWindowTitlesProvider = { _ in [] }
    }

    func install() {
        pill.island = island
        DetectedMeetingPromptWiring(
            onboardingCompleted: { [weak self] in self?.onboardingCompleted ?? false },
            detailOverride: { [weak self] in self?.detailOverride },
            onShown: { [weak self] in self?.shown.append($0.id) },
            onRecord: { [weak self] in self?.answers.append("record:\($0.id)") },
            onDismiss: { [weak self] in self?.answers.append("dismiss:\($0.id)") },
            onExpired: { [weak self] in self?.answers.append("expire:\($0.id)") },
            onRemind: { [weak self] in self?.answers.append("remind:\($0.id)") },
            decisionForCandidate: { [weak self] candidate in
                self?.decision(candidate) ?? .prompt
            },
            onAutoStart: { [weak self] candidate in
                self?.autoStarts.append(candidate.id)
                return self?.autoStartSucceeds ?? false
            }
        ).install(on: detector, pill: pill)
    }
}

@MainActor
private final class WiringFakeIsland: NotchIslandCallPromptPresenting {
    var callActionHandler: ((NotchIslandAction) -> Void)?
    var callHoverHandler: ((Bool) -> Void)?
    var callVisibilityHandler: ((Bool) -> Void)?
    var prompt: NotchIslandCallPromptContent?
    func updateCallPrompt(_ content: NotchIslandCallPromptContent?) { prompt = content }
    func updateCallPromptSeconds(_ secondsLeft: Int) { prompt?.secondsLeft = secondsLeft }
}

@available(macOS 14.0, *)
@MainActor
private func wiringCandidate(
    id: String,
    reason: MeetingPromptReason,
    source: MeetingPromptSource = .runtimeApp,
    provider: MeetingPromptProvider = .zoom,
    provenNativeZoom: Bool = false
) -> MeetingPromptDetector.Candidate {
    let start = Date(timeIntervalSince1970: 2_000)
    return MeetingPromptDetector.Candidate(
        id: id,
        title: "Call detected",
        detail: "Record this call?",
        provider: provider,
        reason: reason,
        source: source,
        startDate: start,
        endDate: start.addingTimeInterval(1_800),
        meetingURL: nil,
        suggestedTranscriptTitle: nil,
        callEvidence: provenNativeZoom ? .nativeApp : .none,
        holdsMicrophone: provenNativeZoom,
        isFocusedFrontWindow: provenNativeZoom,
        evidenceAge: provenNativeZoom ? MeetingAutoRecordPolicy.evidenceHoldDuration : 0,
        nativeProcessHoldsMicrophone: provenNativeZoom
    )
}
