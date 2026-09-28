import Foundation

// Behavior tests for the first step of starting a dictation
// (Sources/UI/Overlay/DictationStartAdmission.swift): whether a press becomes a
// take, and how it's counted for the start-rate metrics. These replace
// source-text checks on the order of lines in DictationSessionController.

@MainActor
func testDictationStartAdmission() {
    runSuite("A press is counted before any guard can refuse it") {
        let fake = StartAdmissionFake()
        fake.blocksNewCapture = true
        let decision = DictationStartAdmission.decide(fake.steps())

        assertEqual(decision, .refused(.unsavedCaptureRecoveryPending, message: nil), "the first guard refused it")
        assertEqual(fake.events, ["remember", "island", "count request", "check unsaved audio", "count refusal: unsaved_capture_recovery_pending"],
                    "a refused start is still a start the user asked for, so it's counted first")
    }

    runSuite("An admitted press is counted once, and nothing refuses it") {
        let fake = StartAdmissionFake()
        let decision = DictationStartAdmission.decide(fake.steps())

        assertEqual(decision, .admitted, "all guards passed")
        assertEqual(fake.events.filter { $0 == "count request" }.count, 1, "counted exactly once")
        assertFalse(fake.events.contains { $0.hasPrefix("count refusal") }, "no refusal for an admitted start")
    }

    runSuite("Each guard that refuses reports its own reason") {
        let unsaved = StartAdmissionFake()
        unsaved.blocksNewCapture = true
        assertEqual(DictationStartAdmission.decide(unsaved.steps()), .refused(.unsavedCaptureRecoveryPending, message: nil),
                    "unsaved audio blocks a new capture")
        assertEqual(unsaved.refusals, ["unsaved_capture_recovery_pending"], "and says so")

        let busy = StartAdmissionFake()
        busy.previousTakeIsTranscribing = true
        assertEqual(DictationStartAdmission.decide(busy.steps()), .refused(.previousDictationTranscribing, message: nil),
                    "a take still transcribing refuses the next")
        assertEqual(busy.refusals, ["previous_dictation_transcribing"], "and says so")

        let unavailable = StartAdmissionFake()
        unavailable.unavailableReason = "Microphone in use by a meeting"
        assertEqual(DictationStartAdmission.decide(unavailable.steps()),
                    .refused(.dictationUnavailable, message: "Microphone in use by a meeting"),
                    "an unavailable dictation refuses with its reason")
        assertEqual(unavailable.refusals, ["dictation_unavailable"], "and says so")

        assertEqual(Set(DictationStartAdmission.Refusal.allCases.map(\.rawValue)),
                    ["unsaved_capture_recovery_pending", "previous_dictation_transcribing", "dictation_unavailable"],
                    "the reasons are the telemetry values the dashboards already use")
    }

    runSuite("Guards run in order and stop at the first refusal") {
        let fake = StartAdmissionFake()
        fake.blocksNewCapture = true
        fake.previousTakeIsTranscribing = true
        fake.unavailableReason = "unavailable"
        _ = DictationStartAdmission.decide(fake.steps())

        assertEqual(fake.refusals, ["unsaved_capture_recovery_pending"], "only the first refusal is reported")
        assertFalse(fake.events.contains("check transcribing"), "later guards don't run after a refusal")

        let busyAndUnavailable = StartAdmissionFake()
        busyAndUnavailable.previousTakeIsTranscribing = true
        busyAndUnavailable.unavailableReason = "unavailable"
        assertEqual(DictationStartAdmission.decide(busyAndUnavailable.steps()),
                    .refused(.previousDictationTranscribing, message: nil),
                    "a take still transcribing is reported before dictation being unavailable")
        assertFalse(busyAndUnavailable.events.contains("check available"), "the third guard doesn't run after the second refuses")
    }

    runSuite("A press while already dictating is ignored and not counted") {
        let fake = StartAdmissionFake()
        fake.isDictating = true
        let decision = DictationStartAdmission.decide(fake.steps())

        assertEqual(decision, .alreadyDictating, "a second press doesn't start a second take")
        assertEqual(fake.events, [], "not counted, no island, no guards")
    }

    runSuite("A press queued behind a finishing take isn't counted yet") {
        // It's counted when it actually starts (through startDictation again) or
        // when the queue drops it, never both.
        let fake = StartAdmissionFake()
        fake.previousTakeFinishing = true
        let decision = DictationStartAdmission.decide(fake.steps())

        assertEqual(decision, .queuedBehindFinishingTake, "the press waits for the last take")
        assertEqual(fake.events, ["remember"],
                    "not counted (counting now and again when it starts would double-count), no island, no guards")
    }

    runSuite("The Notch island goes up before the counting and checks") {
        let fake = StartAdmissionFake()
        _ = DictationStartAdmission.decide(fake.steps())

        assertEqual(Array(fake.events.prefix(3)), ["remember", "island", "count request"],
                    "the island lands on the next frame, ahead of the ~12 ms of telemetry and checks")
    }
}

// MARK: - Fake

@MainActor
private final class StartAdmissionFake {
    var events: [String] = []
    var refusals: [String] = []
    var isDictating = false
    var previousTakeFinishing = false
    var blocksNewCapture = false
    var previousTakeIsTranscribing = false
    var unavailableReason: String?

    func steps() -> DictationStartAdmission.Steps {
        DictationStartAdmission.Steps(
            isDictating: { [unowned self] in self.isDictating },
            rememberPressIfFinishing: { [unowned self] in
                self.events.append("remember")
                return self.previousTakeFinishing
            },
            showStartingIsland: { [unowned self] in self.events.append("island") },
            countRequest: { [unowned self] in self.events.append("count request") },
            blocksNewCapture: { [unowned self] in
                self.events.append("check unsaved audio")
                return self.blocksNewCapture
            },
            previousTakeIsTranscribing: { [unowned self] in
                self.events.append("check transcribing")
                return self.previousTakeIsTranscribing
            },
            unavailableReason: { [unowned self] in
                self.events.append("check available")
                return self.unavailableReason
            },
            countRefusal: { [unowned self] refusal in
                self.events.append("count refusal: \(refusal.rawValue)")
                self.refusals.append(refusal.rawValue)
            }
        )
    }
}
