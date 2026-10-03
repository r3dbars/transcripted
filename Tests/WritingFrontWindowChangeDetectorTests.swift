import Foundation

// Behavioral coverage for Writing's front-window poll decisions
// (Sources/Writing/WritingFrontWindowChangeDetector.swift): the 1 Hz poll
// fires Screen Memory's window-changed trigger exactly as the old main-thread
// poll did, while unchanged ticks never wake main or re-read the bundle ID.

private struct PollWindow: Equatable {
    let pid: Int32
    let window: UInt32
    let bundle: String?
}

private enum PollEvent {
    /// The background queue read this front window.
    case read(PollWindow?)
    /// Main gets a turn and runs any delivery that's waiting.
    case mainRuns
}

/// The old poll, which read and compared on main every tick: the first read
/// is the baseline, then any read that differs from the previous one fires.
private func oldPollTriggers(_ reads: [PollWindow?]) -> [PollWindow?] {
    var fired: [PollWindow?] = []
    var last: PollWindow?
    for (index, read) in reads.enumerated() {
        if index == 0 { last = read; continue }
        if read != last {
            last = read
            fired.append(read)
        }
    }
    return fired
}

private struct NewPollRun {
    var fired: [PollWindow?] = []
    var mainHops = 0
}

private func newPollTriggers(_ events: [PollEvent]) -> NewPollRun {
    var detector = FrontWindowChangeDetector<PollWindow>()
    var run = NewPollRun()
    var hopQueued = false
    for event in events {
        switch event {
        case .read(let window):
            if detector.record(window) {
                assertFalse(hopQueued, "never more than one main hop in flight")
                hopQueued = true
                run.mainHops += 1
            }
        case .mainRuns:
            guard hopQueued else { continue }
            hopQueued = false
            if case .some(let window) = detector.takeDelivery() { run.fired.append(window) }
        }
    }
    return run
}

/// Main is free: every read is followed by main getting a turn.
private func mainAlwaysFree(_ reads: [PollWindow?]) -> [PollEvent] {
    reads.flatMap { [PollEvent.read($0), .mainRuns] }
}

func testWritingFrontWindowChangeDetector() {
    let a = PollWindow(pid: 100, window: 1, bundle: "com.example.a")
    let a2 = PollWindow(pid: 100, window: 2, bundle: "com.example.a")
    let b = PollWindow(pid: 200, window: 3, bundle: "com.example.b")
    let c = PollWindow(pid: 300, window: 4, bundle: "com.example.c")
    let unresolved = PollWindow(pid: 400, window: 5, bundle: nil)
    let resolved = PollWindow(pid: 400, window: 5, bundle: "com.example.d")
    let reusedPid = PollWindow(pid: 100, window: 9, bundle: "com.example.other")

    runSuite("The window poll fires the same triggers as the old main-thread poll when main is free") {
        let scripts: [[PollWindow?]] = [
            [a, a, a, a],
            [a, b, b, a, a],
            [a, a2, a2, a],
            [nil, a, nil, nil, b],
            [unresolved, resolved, resolved, unresolved],
            [a, reusedPid, a],
            [a, b, c, a, b, c],
        ]
        for script in scripts {
            let run = newPollTriggers(mainAlwaysFree(script))
            assertEqual(run.fired, oldPollTriggers(script), "script \(script)")
        }
    }

    runSuite("The first read is the baseline and never fires") {
        assertEqual(newPollTriggers(mainAlwaysFree([a])).fired, [])
        assertEqual(newPollTriggers(mainAlwaysFree([nil])).fired, [])
        assertEqual(newPollTriggers(mainAlwaysFree([b, b])).fired, [])
    }

    runSuite("Unchanged ticks never wake main") {
        let run = newPollTriggers(mainAlwaysFree([a, a, a, a, a, b, b, b, b]))
        assertEqual(run.mainHops, 1, "only the switch to b hops to main")
        assertEqual(run.fired, [b])
    }

    runSuite("A change that reverts while main is busy fires nothing, like the old poll after a hang") {
        let run = newPollTriggers([.read(a), .read(b), .read(a), .mainRuns, .read(a), .mainRuns])
        assertEqual(run.fired, [])
        // The old poll got no ticks during the hang, so it saw only a, a.
        assertEqual(run.fired, oldPollTriggers([a, a]))
    }

    runSuite("Several changes while main is busy fire once with the latest window") {
        let run = newPollTriggers([.read(a), .read(b), .read(c), .mainRuns])
        assertEqual(run.fired, [c])
        assertEqual(run.mainHops, 1)
        assertEqual(run.fired, oldPollTriggers([a, c]))
    }

    runSuite("A change after a busy-main revert still fires") {
        let run = newPollTriggers([
            .read(a), .read(b), .read(a), .mainRuns,
            .read(c), .mainRuns,
            .read(c), .mainRuns,
            .read(a), .mainRuns,
        ])
        assertEqual(run.fired, [c, a])
    }

    runSuite("Losing the front window fires with no window, and getting one back fires again") {
        let run = newPollTriggers(mainAlwaysFree([a, nil, nil, a]))
        assertEqual(run.fired, [nil, a])
    }

    runSuite("The bundle ID is looked up once per front window while it resolves") {
        var memo = FrontWindowBundleMemo()
        var lookups: [Int32] = []
        func read(_ pid: Int32, _ window: UInt32) -> String? {
            memo.bundleIdentifier(pid: pid, window: window) { pid in
                lookups.append(pid)
                return "bundle.\(pid)"
            }
        }
        assertEqual(read(1, 10), "bundle.1")
        assertEqual(read(1, 10), "bundle.1")
        assertEqual(read(1, 10), "bundle.1")
        assertEqual(lookups, [1], "an unchanged window reuses the bundle ID")
        assertEqual(read(1, 11), "bundle.1")
        assertEqual(lookups, [1, 1], "a new window in the same app looks it up again")
        assertEqual(read(2, 11), "bundle.2")
        assertEqual(lookups, [1, 1, 2], "a new process looks it up again")
        assertEqual(read(1, 11), "bundle.1")
        assertEqual(lookups, [1, 1, 2, 1], "going back looks it up again")
    }

    runSuite("A bundle ID that didn't resolve is asked for again next tick") {
        var memo = FrontWindowBundleMemo()
        var answers: [String?] = [nil, nil, "com.example.late"]
        var lookups = 0
        func read() -> String? {
            memo.bundleIdentifier(pid: 7, window: 70) { _ in
                lookups += 1
                return answers.isEmpty ? "unexpected" : answers.removeFirst()
            }
        }
        assertNil(read())
        assertNil(read())
        assertEqual(read(), "com.example.late")
        assertEqual(read(), "com.example.late")
        assertEqual(lookups, 3, "nil is never cached; the resolved ID is")
    }

    runSuite("With the bundle memo, the poll fires the same triggers as looking up every tick") {
        // pid 400's bundle ID resolves late; pid 100 is reused for a new
        // window with a different bundle ID.
        let frames: [(Int32, UInt32)] = [
            (100, 1), (100, 1), (400, 5), (400, 5), (400, 5), (400, 5),
            (100, 1), (100, 9), (100, 9), (100, 1),
        ]
        var tick = 0
        func liveLookup(_ pid: Int32, _ window: UInt32) -> String? {
            switch pid {
            case 400: return tick >= 4 ? "com.example.d" : nil
            case 100: return window == 9 ? "com.example.other" : "com.example.a"
            default: return nil
            }
        }
        var everyTick: [PollWindow?] = []
        var memoReads: [PollWindow?] = []
        var memo = FrontWindowBundleMemo()
        for (index, frame) in frames.enumerated() {
            tick = index
            everyTick.append(PollWindow(pid: frame.0, window: frame.1, bundle: liveLookup(frame.0, frame.1)))
            let bundle = memo.bundleIdentifier(pid: frame.0, window: frame.1) { liveLookup($0, frame.1) }
            memoReads.append(PollWindow(pid: frame.0, window: frame.1, bundle: bundle))
        }
        assertEqual(memoReads, everyTick)
        assertEqual(
            newPollTriggers(mainAlwaysFree(memoReads)).fired,
            oldPollTriggers(everyTick)
        )
    }
}
