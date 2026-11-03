// CallSpeakerActivityTests.swift
// Promises:
// - Polls fold into speaking spans: a span runs while polls show the same one
//   other person speaking, and ends on a change, on nobody or several people
//   speaking, or after a gap of more than 2.5 s. Withheld polls add no
//   evidence. Short spans are dropped, Teams spans move 1.5 s earlier, and
//   every span sits inside a coverage span.
// - Finished activity waits for its meeting, is handed out once, and the
//   store never grows past its cap.
// - The recorder never reads the call app while the setting is off or
//   Accessibility isn't trusted, backs off when no call app runs, polls
//   every 3 s until a roster shows and every 1 s after, and produces
//   activity on virtual time.
// Every name is fictional.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

private func speaking(
    _ names: Set<String>,
    roster: [String]? = nil,
    selfNames: Set<String> = [],
    app: CallSpeakerApp? = .zoom
) -> CallSpeakerSnapshot {
    CallSpeakerSnapshot(
        roster: roster ?? Array(names).sorted(),
        speaking: names,
        selfNames: selfNames,
        status: names.subtracting(selfNames).isEmpty ? .rosterOnly : .speakingIndicator,
        app: app
    )
}

private func interval(_ name: String, _ start: Double, _ end: Double) -> CallSpeakerActivity.Interval {
    .init(name: name, start: start, end: end)
}

private func span(_ start: Double, _ end: Double) -> CallSpeakerActivity.Span {
    .init(start: start, end: end)
}

private func everyIntervalIsCovered(_ activity: CallSpeakerActivity) -> Bool {
    activity.intervals.allSatisfy { item in
        activity.coverage.contains { $0.start <= item.start && item.end <= $0.end }
    }
}

/// Sleeps move only this clock's own time, then yield.
private final class VirtualPollClock: @unchecked Sendable {
    private let startInstant = ContinuousClock.now
    private let lock = NSLock()
    private var advanced: Duration = .zero

    var advancedSeconds: Double {
        lock.withLock { advanced } / .seconds(1)
    }

    var clock: CallSpeakerPollClock {
        CallSpeakerPollClock(
            now: { self.startInstant.advanced(by: self.lock.withLock { self.advanced }) },
            sleep: { interval in
                try Task.checkCancellation()
                self.lock.withLock { self.advanced += interval }
                await Task.yield()
            }
        )
    }
}

private actor FakeCallSpeakerReader: CallSpeakerWindowReading {
    private let result: CallSpeakerReadResult
    private let clock: VirtualPollClock
    private(set) var readCount = 0
    private(set) var readTimes: [Double] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ result: CallSpeakerReadResult, clock: VirtualPollClock) {
        self.result = result
        self.clock = clock
    }

    func read(session: UUID) async -> CallSpeakerReadResult {
        readCount += 1
        readTimes.append(clock.advancedSeconds)
        let ready = waiters.filter { $0.count <= readCount }
        waiters.removeAll { $0.count <= readCount }
        ready.forEach { $0.continuation.resume() }
        return result
    }

    func waitForReads(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private func teamsCall(speaking speaker: String?, roster: [String] = ["Ana Ruiz", "Ben Okafor"]) -> CallSpeakerReadResult {
    let tiles = roster.map { name in
        CallSpeakerAXNode(
            role: "AXMenuItem",
            description: "\(name), unmuted More options",
            children: name == speaker ? [CallSpeakerAXNode(role: "AXGroup", domClassList: ["vdi-frame-occlusion"])] : []
        )
    }
    return CallSpeakerReadResult(
        supportedAppRunning: true,
        windows: [CallSpeakerWindowRead(
            match: CallSpeakerWindowMatch(app: .teamsDesktop, meetingKey: "teams-desktop"),
            tree: CallSpeakerAXNode(role: "AXWindow", children: tiles),
            truncated: false
        )]
    )
}

@MainActor
private func makeRecorder(
    reader: FakeCallSpeakerReader,
    clock: VirtualPollClock,
    enabled: Bool = true,
    trusted: Bool = true
) -> CallSpeakerActivityRecorder {
    CallSpeakerActivityRecorder(environment: .init(
        isEnabled: { enabled },
        isAccessibilityTrusted: { trusted },
        reader: reader,
        clock: clock.clock
    ))
}

/// Lets the recorder's loop run until virtual time passes `seconds`.
/// Bounded by turns, never by wall-clock time.
@MainActor
private func runUntilVirtualTime(_ clock: VirtualPollClock, passes seconds: Double) async {
    for _ in 0..<200_000 where clock.advancedSeconds < seconds {
        await Task.yield()
    }
}

@MainActor
func testCallSpeakerActivity() async {
    runSuite("CallSpeakerActivityAccumulator: a span runs while one person speaks and ends on a change") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(speaking(["Ana Ruiz"]), at: 0)
        accumulator.add(speaking(["Ana Ruiz"]), at: 1)
        accumulator.add(speaking(["Ana Ruiz"]), at: 2)
        accumulator.add(speaking(["Ben Okafor"]), at: 3)
        accumulator.add(speaking(["Ben Okafor"]), at: 4)
        accumulator.add(speaking([], roster: ["Ana Ruiz", "Ben Okafor"]), at: 5)
        let activity = accumulator.finished()
        assertEqual(activity.intervals, [interval("Ana Ruiz", 0, 3), interval("Ben Okafor", 3, 5)],
                    "each span ends at the poll that stopped showing its speaker")
        assertEqual(activity.coverage, [span(0, 5)], "one trusted span across the change")
        assertTrue(activity.sawSpeakingIndicator, "a speaking indicator was seen")
        assertTrue(everyIntervalIsCovered(activity), "intervals lie inside coverage")
    }

    runSuite("CallSpeakerActivityAccumulator: a gap over 2.5 s ends the span at the last poll") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(speaking(["Ana Ruiz"]), at: 0)
        accumulator.add(speaking(["Ana Ruiz"]), at: 1)
        accumulator.add(speaking(["Ana Ruiz"]), at: 4)
        accumulator.add(speaking(["Ana Ruiz"]), at: 5)
        let activity = accumulator.finished()
        assertEqual(activity.intervals, [interval("Ana Ruiz", 0, 1), interval("Ana Ruiz", 4, 5)],
                    "no evidence across the 3 s hole")
        assertEqual(activity.coverage, [span(0, 1), span(4, 5)], "coverage has the same hole")
    }

    runSuite("CallSpeakerActivityAccumulator: slow reads timed at their midpoints keep the span") {
        // 1 s cadence plus reads of up to 1.5 s put midpoints ~1.7 s apart.
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(speaking(["Ana Ruiz"]), at: 0)
        accumulator.add(speaking(["Ana Ruiz"]), at: 1.7)
        accumulator.add(speaking(["Ana Ruiz"]), at: 3.4)
        accumulator.add(speaking([], roster: ["Ana Ruiz"]), at: 5.1)
        let activity = accumulator.finished()
        assertEqual(activity.intervals, [interval("Ana Ruiz", 0, 5.1)], "one span, not three fragments")
        assertEqual(activity.coverage, [span(0, 5.1)], "one coverage span")
    }

    runSuite("CallSpeakerActivityAccumulator: two people speaking at once is no speaker") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(speaking(["Ana Ruiz"]), at: 0)
        accumulator.add(speaking(["Ana Ruiz"]), at: 1)
        accumulator.add(speaking(["Ana Ruiz", "Ben Okafor"]), at: 2)
        accumulator.add(speaking(["Ana Ruiz", "Ben Okafor"]), at: 3)
        let activity = accumulator.finished()
        assertEqual(activity.intervals, [interval("Ana Ruiz", 0, 2)], "the overlap adds no span")
        assertEqual(activity.coverage, [span(0, 2)], "and no coverage")
    }

    runSuite("CallSpeakerActivityAccumulator: the local user speaking alongside one other still names the other") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(speaking(["Ana Ruiz", "Cara Diaz"], selfNames: ["Cara Diaz"]), at: 0)
        accumulator.add(speaking(["Ana Ruiz", "Cara Diaz"], selfNames: ["Cara Diaz"]), at: 1)
        let activity = accumulator.finished()
        assertEqual(activity.intervals, [interval("Ana Ruiz", 0, 1)], "self is never a speaker span")
        assertEqual(activity.selfNames, ["Cara Diaz"], "self names are passed on")
        assertTrue(!activity.rosterNames.contains("Cara Diaz"), "self is never on the roster")
    }

    runSuite("CallSpeakerActivityAccumulator: withheld polls add no evidence and close only on a gap") {
        for status in [CallSpeakerSnapshot.Status.windowsDisagree, .multipleWindows, .truncated] {
            var accumulator = CallSpeakerActivityAccumulator()
            let withheld = CallSpeakerSnapshot(roster: ["Ana Ruiz"], speaking: [], selfNames: [], status: status)
            accumulator.add(speaking(["Ana Ruiz"]), at: 0)
            accumulator.add(withheld, at: 1)
            accumulator.add(speaking(["Ana Ruiz"]), at: 1.5)
            accumulator.add(withheld, at: 2.5)
            accumulator.add(withheld, at: 3.5)
            accumulator.add(speaking(["Ana Ruiz"]), at: 4.5)
            accumulator.add(speaking(["Ana Ruiz"]), at: 5.5)
            let activity = accumulator.finished()
            assertEqual(activity.intervals, [interval("Ana Ruiz", 0, 1.5), interval("Ana Ruiz", 4.5, 5.5)],
                        "\(status.rawValue): a short withheld stretch keeps the span, a long one ends it at the last real poll")
            assertTrue(everyIntervalIsCovered(activity), "\(status.rawValue): intervals inside coverage")
        }
    }

    runSuite("CallSpeakerActivityAccumulator: spans under 0.4 s are dropped") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(speaking(["Ana Ruiz"]), at: 0)
        accumulator.add(speaking(["Ben Okafor"]), at: 0.3)
        accumulator.add(speaking([], roster: ["Ana Ruiz"]), at: 1.3)
        let activity = accumulator.finished()
        assertEqual(activity.intervals, [interval("Ben Okafor", 0.3, 1.3)], "Ana's 0.3 s blip is dropped")
    }

    runSuite("CallSpeakerActivityAccumulator: Teams spans move 1.5 s earlier, with their coverage") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(speaking(["Ana Ruiz"], app: .teamsDesktop), at: 10)
        accumulator.add(speaking(["Ana Ruiz"], app: .teamsDesktop), at: 11)
        accumulator.add(speaking([], roster: ["Ana Ruiz"], app: .teamsDesktop), at: 12)
        let activity = accumulator.finished()
        assertEqual(activity.intervals, [interval("Ana Ruiz", 8.5, 10.5)], "Teams indicator lag removed")
        assertEqual(activity.coverage, [span(8.5, 10.5)], "coverage moves with it")
    }

    runSuite("CallSpeakerActivityAccumulator: roster and self names accumulate, never from mixed meetings") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(CallSpeakerSnapshot(roster: ["Ana Ruiz"], speaking: [], selfNames: ["Cara Diaz"], status: .rosterOnly), at: 0)
        accumulator.add(CallSpeakerSnapshot(roster: ["Zed Quill"], speaking: [], selfNames: [], status: .multipleWindows), at: 1)
        accumulator.add(CallSpeakerSnapshot(roster: ["Ben Okafor", "Ana Ruiz"], speaking: [], selfNames: [], status: .truncated), at: 2)
        let activity = accumulator.finished()
        assertEqual(activity.rosterNames, ["Ana Ruiz", "Ben Okafor"], "roster in first-seen order, without the other meeting")
        assertEqual(activity.selfNames, ["Cara Diaz"], "self names")
        assertTrue(!activity.sawSpeakingIndicator, "roster only never counts as a speaking indicator")
        assertTrue(activity.intervals.isEmpty && activity.coverage.isEmpty, "no speaking evidence")
    }

    runSuite("CallSpeakerActivityAccumulator: Slack adds to the roster only once it marks the local user") {
        var accumulator = CallSpeakerActivityAccumulator()
        accumulator.add(CallSpeakerSnapshot(roster: ["Ana Ruiz"], speaking: [], selfNames: [], status: .rosterOnly, app: .slack), at: 0)
        assertTrue(accumulator.finished().rosterNames.isEmpty,
                   "a Slack roster without a self marker may hold the user's own tile: omit untrusted roster metadata")
        accumulator.add(CallSpeakerSnapshot(roster: ["Ana Ruiz"], speaking: [], selfNames: ["Cara Diaz"], status: .rosterOnly, app: .slack), at: 1)
        assertEqual(accumulator.finished().rosterNames, ["Ana Ruiz"], "with a self marker the roster counts")
        var zoom = CallSpeakerActivityAccumulator()
        zoom.add(CallSpeakerSnapshot(roster: ["Ana Ruiz"], speaking: [], selfNames: [], status: .rosterOnly, app: .zoom), at: 0)
        assertEqual(zoom.finished().rosterNames, ["Ana Ruiz"], "apps that detect the user count without one")
    }

    runSuite("CallSpeakerActivityStore: activity is handed out once, by recording date") {
        var store = CallSpeakerActivityStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let activity = CallSpeakerActivity(rosterNames: ["Ana Ruiz"])
        store.put(activity, recordingStartedAt: start)
        assertTrue(store.take(recordingStartedAt: Date(timeIntervalSince1970: 1_800_000_100)) == nil, "another meeting gets nothing")
        assertTrue(store.take(recordingStartedAt: nil) == nil, "an import (no date) gets nothing")
        assertEqual(store.take(recordingStartedAt: start), activity, "its own meeting gets it")
        assertTrue(store.take(recordingStartedAt: start) == nil, "only once")

        store.put(activity, recordingStartedAt: start)
        store.drop(recordingStartedAt: start)
        assertTrue(store.take(recordingStartedAt: start) == nil, "a discarded recording drops its activity")
    }

    runSuite("CallSpeakerActivityStore: the setting turned off before transcription hands out nothing") {
        var store = CallSpeakerActivityStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        store.put(CallSpeakerActivity(rosterNames: ["Ana Ruiz"]), recordingStartedAt: start)
        assertTrue(store.take(recordingStartedAt: start, enabled: false) == nil, "off at hand-out: no activity")
        assertEqual(store.count, 0, "and it is dropped, not kept for a later ask")
        store.put(CallSpeakerActivity(rosterNames: ["Ana Ruiz"]), recordingStartedAt: start)
        assertEqual(store.take(recordingStartedAt: start, enabled: true)?.rosterNames, ["Ana Ruiz"], "on: handed out")
    }

    runSuite("CallSpeakerActivityStore: keeps only the newest meetings") {
        var store = CallSpeakerActivityStore(capacity: 3)
        let dates = (0..<5).map { Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 60) }
        for (index, date) in dates.enumerated() {
            store.put(CallSpeakerActivity(rosterNames: ["Person \(index)"]), recordingStartedAt: date)
        }
        assertEqual(store.count, 3, "bounded")
        assertTrue(store.take(recordingStartedAt: dates[0]) == nil, "oldest dropped")
        assertEqual(store.take(recordingStartedAt: dates[4])?.rosterNames, ["Person 4"], "newest kept")
    }

    await runSuite("CallSpeakerActivityRecorder: reads nothing while the setting is off") {
        let clock = VirtualPollClock()
        let reader = FakeCallSpeakerReader(teamsCall(speaking: "Ana Ruiz"), clock: clock)
        let recorder = makeRecorder(reader: reader, clock: clock, enabled: false)
        recorder.start(recordingStartedAt: Date())
        await runUntilVirtualTime(clock, passes: 30)
        let activity = recorder.stop()
        assertTrue(clock.advancedSeconds >= 30, "the loop kept re-checking on virtual time")
        assertEqual(await reader.readCount, 0, "the call app is never read with the setting off")
        assertTrue(activity == nil, "nothing recorded")
        assertTrue((recorder.lastSummary?.gatedChecks ?? 0) <= 8, "re-checks back off to every 5 s")
    }

    await runSuite("CallSpeakerActivityRecorder: reads nothing without Accessibility") {
        let clock = VirtualPollClock()
        let reader = FakeCallSpeakerReader(teamsCall(speaking: "Ana Ruiz"), clock: clock)
        let recorder = makeRecorder(reader: reader, clock: clock, trusted: false)
        recorder.start(recordingStartedAt: Date())
        await runUntilVirtualTime(clock, passes: 30)
        _ = recorder.stop()
        assertTrue(clock.advancedSeconds >= 30, "the loop kept re-checking on virtual time")
        assertEqual(await reader.readCount, 0, "the call app is never read without Accessibility")
    }

    await runSuite("CallSpeakerActivityRecorder: backs off when no call app is running") {
        let clock = VirtualPollClock()
        let reader = FakeCallSpeakerReader(.nothingRunning, clock: clock)
        let recorder = makeRecorder(reader: reader, clock: clock)
        recorder.start(recordingStartedAt: Date())
        await reader.waitForReads(3)
        _ = recorder.stop()
        let times = await reader.readTimes
        assertEqual(Array(times.prefix(3)), [0, 5, 10], "reads 5 s apart while no call app runs")
    }

    await runSuite("CallSpeakerActivityRecorder: polls every 3 s without a roster") {
        let clock = VirtualPollClock()
        let empty = CallSpeakerReadResult(supportedAppRunning: true, windows: [])
        let reader = FakeCallSpeakerReader(empty, clock: clock)
        let recorder = makeRecorder(reader: reader, clock: clock)
        recorder.start(recordingStartedAt: Date())
        await reader.waitForReads(3)
        _ = recorder.stop()
        assertEqual(Array(await reader.readTimes.prefix(3)), [0, 3, 6], "slow cadence with no meeting window")
    }

    await runSuite("CallSpeakerActivityRecorder: polls every 1 s once a roster shows, into activity") {
        let clock = VirtualPollClock()
        let reader = FakeCallSpeakerReader(teamsCall(speaking: "Ana Ruiz"), clock: clock)
        let recorder = makeRecorder(reader: reader, clock: clock)
        recorder.start(recordingStartedAt: Date())
        await reader.waitForReads(6)
        let activity = recorder.stop()
        assertEqual(Array(await reader.readTimes.prefix(5)), [0, 1, 2, 3, 4], "fast cadence while the roster shows")
        assertTrue(activity?.sawSpeakingIndicator == true, "the speaking indicator was seen")
        assertEqual(activity?.intervals.map(\.name), ["Ana Ruiz"], "one unbroken span for the speaker")
        assertEqual(activity?.intervals.first?.start, 0, "Teams lag shift is clamped at the recording start")
        assertTrue((activity?.intervals.first?.end ?? 0) >= 2, "extended across polls")
        assertEqual(activity?.rosterNames, ["Ana Ruiz", "Ben Okafor"], "roster")
        assertTrue(activity.map(everyIntervalIsCovered) == true, "intervals inside coverage")
        assertTrue(recorder.stop() == nil, "a second stop has nothing more to hand out")
    }
}
