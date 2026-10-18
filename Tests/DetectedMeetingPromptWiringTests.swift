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

        assertEqual(presented, true, "the detector hook reports the prompt as shown")
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

        assertEqual(presented, false, "the detector is told the prompt was blocked")
        assertTrue(rig.island.prompt == nil, "the island stays empty")
        assertEqual(rig.shown, [], "no shown event for a prompt nobody saw")
    }

    runSuite("a prompt with no island is not reported as shown") {
        let rig = WiringRig()
        rig.install()
        rig.pill.island = nil

        let presented = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-d", reason: .micInput))

        assertEqual(presented, false, "with no island there is nowhere to show it")
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

        assertEqual(presented, true, "the detector still treats the call as handled")
        assertTrue(rig.island.prompt == nil, "auto-start must not show Record / Not now")
        assertEqual(rig.shown, [], "no shown event for a prompt nobody saw")
        assertEqual(rig.autoStarts, ["wiring-g"], "auto-start reaches the existing Record start path")
        assertEqual(rig.answers, [], "Record is not a user tap when auto-start fires")
    }

    runSuite("a none decision leaves the island empty") {
        let rig = WiringRig()
        rig.decision = { _ in .none }
        rig.install()

        let presented = rig.detector.onPromptRequest?(wiringCandidate(id: "wiring-h", reason: .micInput))

        assertEqual(presented, false, "the detector is told nothing was shown")
        assertTrue(rig.island.prompt == nil, "nothing stacks on an already-running capture")
        assertEqual(rig.autoStarts, [], "auto-start does not fire")
        assertEqual(rig.shown, [], "no shown event")
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
    var decision: (MeetingPromptDetector.Candidate) -> MeetingAutoRecordPolicy.Decision = { _ in .prompt }

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
            onAutoStart: { [weak self] in self?.autoStarts.append($0.id) }
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
private func wiringCandidate(id: String, reason: MeetingPromptReason) -> MeetingPromptDetector.Candidate {
    let start = Date(timeIntervalSince1970: 2_000)
    return MeetingPromptDetector.Candidate(
        id: id,
        title: "Call detected",
        detail: "Record this call?",
        provider: .zoom,
        reason: reason,
        source: .runtimeApp,
        startDate: start,
        endDate: start.addingTimeInterval(1_800),
        meetingURL: nil,
        suggestedTranscriptTitle: nil
    )
}
