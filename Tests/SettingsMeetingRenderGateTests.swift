import Combine
import Foundation

/// The Settings window redraws for what it shows, not for every meeting tick:
/// a recording's 1 Hz duration and a transcription's progress steps used to
/// re-render the whole shell, open or closed.
@MainActor
func testSettingsMeetingRenderGate() {
    struct Coarse: Equatable {
        var state = "recording"
        var failedTitles: [String] = []
        var isSpeakerReviewPending = false
    }
    let base = Date(timeIntervalSinceReferenceDate: 812_000_040) // on a minute boundary

    runSuite("Render key - a recorded hour of duration ticks is one key at a fixed minute") {
        // Duration isn't an input: only coarse values, the shown percent and
        // the wall minute are. 3,600 ticks with nothing else moving -> 1 key.
        var keys: [SettingsMeetingRenderKey<Coarse>] = []
        for _ in 0..<3_600 {
            let key = SettingsMeetingRenderKey.make(coarse: Coarse(), activityProgress: nil, showsActivityPercent: true, now: base)
            if keys.last != key { keys.append(key) }
        }
        assertEqual(keys.count, 1, "duration ticks alone never change the key")

        var minuteKeys: [SettingsMeetingRenderKey<Coarse>] = []
        for second in 0..<3_600 {
            let key = SettingsMeetingRenderKey.make(
                coarse: Coarse(),
                activityProgress: nil,
                showsActivityPercent: true,
                now: base.addingTimeInterval(TimeInterval(second))
            )
            if minuteKeys.last != key { minuteKeys.append(key) }
        }
        assertEqual(minuteKeys.count, 60, "an hour of wall clock is one redraw a minute, not 3,600")
    }

    runSuite("Render key - transcription progress redraws per shown percent on Home only") {
        func distinctKeys(onHome: Bool) -> Int {
            var keys: [SettingsMeetingRenderKey<Coarse>] = []
            for step in 0...1_000 {
                // Transcribing maps 0...1 to 15%...75% of the row.
                let progress = 0.15 + (Double(step) / 1_000) * 0.60
                let key = SettingsMeetingRenderKey.make(
                    coarse: Coarse(state: "transcribing"),
                    activityProgress: progress,
                    showsActivityPercent: onHome,
                    now: base
                )
                assertEqual(key.activityPercent, onHome ? HomeActivityPercent.displayed(progress) : nil,
                            "the key carries exactly the percent the row shows")
                if keys.last != key { keys.append(key) }
            }
            return keys.count
        }
        assertEqual(distinctKeys(onHome: true), 61, "15% through 75%, one redraw per visible number")
        assertEqual(distinctKeys(onHome: false), 1, "other pages don't show the percent, so they don't redraw for it")
    }

    runSuite("Render key - coarse values and the minute each change it") {
        let start = SettingsMeetingRenderKey.make(coarse: Coarse(), activityProgress: 0.4, showsActivityPercent: true, now: base)
        let failedA = SettingsMeetingRenderKey.make(coarse: Coarse(failedTitles: ["A"]), activityProgress: 0.4, showsActivityPercent: true, now: base)
        let failedB = SettingsMeetingRenderKey.make(coarse: Coarse(failedTitles: ["B"]), activityProgress: 0.4, showsActivityPercent: true, now: base)
        let review = SettingsMeetingRenderKey.make(coarse: Coarse(isSpeakerReviewPending: true), activityProgress: 0.4, showsActivityPercent: true, now: base)
        let nextMinute = SettingsMeetingRenderKey.make(coarse: Coarse(), activityProgress: 0.4, showsActivityPercent: true, now: base.addingTimeInterval(60))
        let sameMinute = SettingsMeetingRenderKey.make(coarse: Coarse(), activityProgress: 0.4, showsActivityPercent: true, now: base.addingTimeInterval(59))
        assertTrue(start != failedA && failedA != failedB, "a new or different failed meeting redraws")
        assertTrue(start != review, "a pending speaker review redraws")
        assertTrue(start != nextMinute, "a new minute redraws")
        assertEqual(start, sameMinute, "seconds inside a minute don't")
    }

    runSuite("Home percent - same numbers the row always showed") {
        assertNil(HomeActivityPercent.displayed(nil), "no progress, no percent")
        assertNil(HomeActivityPercent.displayed(0), "zero shows no percent")
        assertEqual(HomeActivityPercent.displayed(0.29), Int(0.29 * 100), "truncates like the row did")
        assertEqual(HomeActivityPercent.displayed(0.57), Int(0.57 * 100), "truncates like the row did")
        assertEqual(HomeActivityPercent.displayed(0.58), Int(0.58 * 100), "truncates like the row did")
        assertEqual(HomeActivityPercent.displayed(1.0), 100, "done is 100")
    }

    runSuite("Render gate - publishes once per real change, after the publishing turn") {
        let changes = PassthroughSubject<Void, Never>()
        var currentKey = 0
        var keyReads = 0
        var pending: [@MainActor () -> Void] = []
        let gate = SettingsMeetingRenderGate<Int>(
            changes: changes,
            makeKey: {
                keyReads += 1
                return currentKey
            },
            schedule: { pending.append($0) }
        )
        @MainActor func drain() {
            let work = pending
            pending.removeAll()
            work.forEach { $0() }
        }
        var emissions = 0
        let watcher = gate.objectWillChange.sink { emissions += 1 }
        defer { watcher.cancel() }
        let readsAtInit = keyReads

        for _ in 0..<3_600 {
            changes.send()
            drain()
        }
        assertEqual(emissions, 0, "an hour of ticks with nothing visible changing never redraws")

        let readsBeforeBurst = keyReads
        for _ in 0..<50 { changes.send() }
        assertEqual(pending.count, 1, "a burst in one turn schedules one evaluation")
        drain()
        assertEqual(keyReads - readsBeforeBurst, 1, "and reads the key once")

        currentKey = 1
        changes.send()
        assertEqual(emissions, 0, "nothing publishes inside the publishing turn")
        drain()
        assertEqual(emissions, 1, "a key change redraws exactly once")
        assertEqual(gate.key, 1, "the gate keeps the newest key")
        assertTrue(readsAtInit == 1, "the first key is read at init")
    }

    runSuite("Render gate - redrawing only on key changes shows the same thing as redrawing on every publish") {
        struct Snapshot {
            var coarse: Coarse
            var progress: Double?
            var onHome: Bool
            var now: Date
        }
        func visible(_ snapshot: Snapshot) -> SettingsMeetingRenderKey<Coarse> {
            SettingsMeetingRenderKey.make(coarse: snapshot.coarse, activityProgress: snapshot.progress, showsActivityPercent: snapshot.onHome, now: snapshot.now)
        }
        var stream: [Snapshot] = []
        var clock = base
        for second in 0..<300 { // a recording: 1 Hz ticks
            clock = base.addingTimeInterval(TimeInterval(second))
            stream.append(Snapshot(coarse: Coarse(), progress: nil, onHome: true, now: clock))
        }
        for step in 0...400 { // transcribing, switching pages midway
            stream.append(Snapshot(
                coarse: Coarse(state: "transcribing"),
                progress: 0.15 + Double(step) / 400 * 0.6,
                onHome: step < 200 || step > 300,
                now: clock
            ))
        }
        stream.append(Snapshot(coarse: Coarse(state: "saved"), progress: 1, onHome: true, now: clock))
        stream.append(Snapshot(coarse: Coarse(state: "saved", failedTitles: ["Standup"]), progress: 1, onHome: true, now: clock))

        var current = stream[0]
        let changes = PassthroughSubject<Void, Never>()
        var pending: [@MainActor () -> Void] = []
        let gate = SettingsMeetingRenderGate(changes: changes, makeKey: { visible(current) }, schedule: { pending.append($0) })
        var rendered = visible(current)
        var renders = 0
        let watcher = gate.objectWillChange.sink { renders += 1 }
        defer { watcher.cancel() }

        @MainActor func drain() {
            let work = pending
            pending.removeAll()
            work.forEach { $0() }
        }
        for snapshot in stream.dropFirst() {
            changes.send()
            current = snapshot
            drain()
            rendered = gate.key
            assertEqual(rendered, visible(snapshot), "what's on screen matches the session after every step")
        }
        assertTrue(renders < stream.count / 4, "far fewer redraws than publishes (\(renders) for \(stream.count))")
    }

    runSuite("Recording clock - whole seconds only, and a new recording starts at 0") {
        let durations = CurrentValueSubject<TimeInterval, Never>(0)
        let clock = SettingsRecordingClock(durations: durations)
        var seen: [Int] = [clock.wholeSeconds]
        for tick in 1...10 {
            durations.send(Double(tick) * 0.2)
            if seen.last != clock.wholeSeconds { seen.append(clock.wholeSeconds) }
        }
        durations.send(0)
        if seen.last != clock.wholeSeconds { seen.append(clock.wholeSeconds) }
        assertEqual(seen, [0, 1, 2, 0], "ticks collapse to whole seconds and reset")
        assertEqual(clock.elapsedText, "0:00", "the label reads the reset time")
        durations.send(3_725.9)
        assertEqual(clock.elapsedText, "1:02:05", "past an hour")
        assertEqual(HomeRecordingElapsed.text(65), "1:05", "under an hour")
        assertEqual(HomeRecordingElapsed.text(-3), "0:00", "never negative")
    }
}
