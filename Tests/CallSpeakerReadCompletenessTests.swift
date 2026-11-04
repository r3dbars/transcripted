import Foundation
import ApplicationServices

private struct ScanFixtureWindow {
    let id: Int
    var title: String?
    var tree = CallSpeakerAXNode()
    var truncated = false
    var visitedNodes = 1
    var titleCost: TimeInterval = 0
    var treeCost: TimeInterval = 0
}

private struct ScanFixtureApp {
    let id: Int
    let host: CallSpeakerApp.Host
    var windows: [ScanFixtureWindow]?
}

/// Actual production scheduling loops, with plain handles and virtual AX time.
private final class ScanFixture {
    var time = Date(timeIntervalSince1970: 1_800_000_000)
    var visitedApps: [Int] = []
    var visitedTitles: [Int] = []
    var visitedTrees: [Int] = []
    var initialNodeCounts: [Int] = []
    var preparations = 0
    var slackMicChecks = 0
    var slackHoldsMicrophone = false

    func read(_ apps: [ScanFixtureApp], budget: TimeInterval = 1.5) -> CallSpeakerReadResult {
        CallSpeakerReadPlan.scanApps(
            apps,
            host: { $0.host },
            deadline: time.addingTimeInterval(budget),
            now: { self.time },
            read: { app, deadline in
                self.visitedApps.append(app.id)
                guard let windows = app.windows else { return .incomplete }
                return CallSpeakerReadPlan.scanWindows(
                    windows,
                    host: app.host,
                    deadline: deadline,
                    now: { self.time },
                    title: { window, _ in
                        self.visitedTitles.append(window.id)
                        self.time.addTimeInterval(window.titleCost)
                        return window.title
                    },
                    slackHoldsMicrophone: {
                        self.slackMicChecks += 1
                        return self.slackHoldsMicrophone
                    },
                    prepareForWalk: { _ in self.preparations += 1 },
                    readTree: { window, _, initialNodes in
                        self.visitedTrees.append(window.id)
                        self.initialNodeCounts.append(initialNodes)
                        self.time.addTimeInterval(window.treeCost)
                        return CallSpeakerReadPlan.TreeRead(
                            tree: window.tree,
                            truncated: window.truncated,
                            visitedNodes: initialNodes + window.visitedNodes
                        )
                    }
                )
            }
        )
    }
}

private func zoomScanWindow(_ id: Int, name: String = "Ana Ruiz") -> ScanFixtureWindow {
    ScanFixtureWindow(id: id, title: "Zoom Meeting", tree: CallSpeakerAXNode(children: [
        .init(roleDescription: "video render", description: "\(name), active speaker"),
    ]))
}

private func slackScanWindow(_ id: Int) -> ScanFixtureWindow {
    ScanFixtureWindow(id: id, title: "Huddle in #planning - Slack", tree: CallSpeakerAXNode(
        domClassList: ["p-huddle_peer_tile"],
        children: [
            .init(description: "View Ana Ruiz's profile"),
            .init(domClassList: ["p-huddle_peer_tile__overlay--active_speaker"]),
        ]
    ))
}

private func assertIncompleteScan(_ read: CallSpeakerReadResult) {
    assertEqual(read.completeness, .incomplete, "unexamined calls are unknown")
    let snapshot = CallSpeakerSnapshotBuilder.build(read)
    assertEqual(snapshot.status, .incompleteScan)
    assertTrue(snapshot.speaking.isEmpty && snapshot.roster.isEmpty && snapshot.selfNames.isEmpty,
               "partial names cannot leak into evidence or roster metadata")
    assertTrue(snapshot.status.isWithheld)
}

func testCallSpeakerReadCompleteness() {
    runSuite("CallSpeakerReadCompleteness: native AX absence and failures remain distinct") {
        for status in [AXError.success, .noValue, .attributeUnsupported] {
            assertEqual(CallSpeakerAXTreeReader.titleValue(status: status, value: nil), "")
        }
        assertEqual(CallSpeakerAXTreeReader.titleValue(status: .success, value: "" as NSString), "")
        assertEqual(CallSpeakerAXTreeReader.titleValue(status: .success, value: "Settings" as NSString), "Settings")
        for status in [AXError.cannotComplete, .invalidUIElement, .failure] {
            assertEqual(CallSpeakerAXTreeReader.titleValue(status: status, value: nil), nil)
        }
        assertEqual(CallSpeakerAXTreeReader.titleValue(status: .success, value: NSNumber(value: 1)), nil)

        for status in [AXError.noValue, .attributeUnsupported, .cannotComplete, .invalidUIElement] {
            var error = status
            guard let boxed = AXValueCreate(.axError, &error) else {
                assertTrue(false, "the local AX error fixture must be constructible")
                continue
            }
            assertEqual(
                CallSpeakerAXTreeReader.hasFailedAttributes(["AXGroup" as NSString, boxed]),
                status != .noValue && status != .attributeUnsupported,
                "a batch placeholder must not hide a failed read"
            )
        }
        assertFalse(CallSpeakerAXTreeReader.hasFailedAttributes(["AXGroup" as NSString]))
    }

    runSuite("CallSpeakerReadCompleteness: a deadline cannot hide an unvisited supported app") {
        let scan = ScanFixture()
        var first = zoomScanWindow(1)
        first.treeCost = 2
        let read = scan.read([
            ScanFixtureApp(id: 1, host: .zoom, windows: [first]),
            ScanFixtureApp(id: 2, host: .browser, windows: [ScanFixtureWindow(id: 2, title: "Meet - abc-defg-hij")]),
        ])
        assertEqual(scan.visitedApps, [1], "the deadline keeps the second app unvisited")
        assertEqual(read.windows.count, 1, "the first call alone would look nameable")
        assertIncompleteScan(read)

        let beforeFirst = ScanFixture()
        assertIncompleteScan(beforeFirst.read([ScanFixtureApp(id: 1, host: .zoom, windows: [])], budget: 0))
        assertTrue(beforeFirst.visitedApps.isEmpty)
    }

    runSuite("CallSpeakerReadCompleteness: window-list and title failures are not empty scans") {
        for brokenWindows in [Optional<[ScanFixtureWindow]>.none, [ScanFixtureWindow(id: 2, title: nil)]] {
            let scan = ScanFixture()
            let read = scan.read([
                ScanFixtureApp(id: 1, host: .zoom, windows: [zoomScanWindow(1)]),
                ScanFixtureApp(id: 2, host: .browser, windows: brokenWindows),
            ])
            assertEqual(scan.visitedApps, [1, 2])
            assertIncompleteScan(read)
        }
    }

    runSuite("CallSpeakerReadCompleteness: window caps never turn a prefix into the only call") {
        for (host, limit) in [(CallSpeakerApp.Host.zoom, 8), (.slack, 32)] {
            let scan = ScanFixture()
            let windows = (0...limit).map { id in
                id == 0 ? (host == .slack ? slackScanWindow(id) : zoomScanWindow(id))
                    : ScanFixtureWindow(id: id, title: host == .slack ? "Planning - Slack" : "Settings")
            }
            assertIncompleteScan(scan.read([ScanFixtureApp(id: 1, host: host, windows: windows)]))
            assertTrue(scan.visitedTitles.isEmpty && scan.visitedTrees.isEmpty,
                       "a known oversized list cannot justify reading partial candidate trees")
        }
    }

    runSuite("CallSpeakerReadCompleteness: title and candidate deadlines preserve incompleteness") {
        let titles = ScanFixture()
        var slowTitle = zoomScanWindow(1)
        slowTitle.titleCost = 2
        assertIncompleteScan(titles.read([ScanFixtureApp(id: 1, host: .zoom, windows: [slowTitle, zoomScanWindow(2)])]))
        assertEqual(titles.visitedTitles, [1])
        assertTrue(titles.visitedTrees.isEmpty, "no trees are read after title enumeration stopped")

        let candidates = ScanFixture()
        var slowTree = zoomScanWindow(1)
        slowTree.treeCost = 2
        let read = candidates.read([ScanFixtureApp(id: 1, host: .zoom, windows: [slowTree, zoomScanWindow(2)])])
        assertEqual(candidates.visitedTitles, [1, 2], "both call candidates were recognized")
        assertEqual(candidates.visitedTrees, [1], "the second call's tree was not examined")
        assertIncompleteScan(read)
    }

    runSuite("CallSpeakerReadCompleteness: Slack shared node exhaustion cannot hide another huddle") {
        let scan = ScanFixture()
        var first = slackScanWindow(1)
        first.visitedNodes = 4000
        let read = scan.read([ScanFixtureApp(id: 1, host: .slack, windows: [first, slackScanWindow(2)])])
        assertEqual(scan.visitedTrees, [1])
        assertIncompleteScan(read)

        let complete = ScanFixture()
        let single = complete.read([ScanFixtureApp(id: 1, host: .slack, windows: [first])])
        assertEqual(single.completeness, .complete, "exactly consuming the budget is fine when no candidate remains")
        assertEqual(CallSpeakerSnapshotBuilder.build(single).status, .speakingIndicator)
    }

    runSuite("CallSpeakerReadCompleteness: a truncated tree with no tiles can conceal a second call") {
        let scan = ScanFixture()
        var hiddenCall = ScanFixtureWindow(id: 2, title: "Huddle in #other - Slack")
        hiddenCall.truncated = true
        let read = scan.read([ScanFixtureApp(id: 1, host: .slack, windows: [slackScanWindow(1), hiddenCall])])
        assertEqual(scan.visitedTrees, [1, 2])
        assertEqual(scan.initialNodeCounts, [0, 1], "Slack shares the consumed node count")
        assertIncompleteScan(read)
    }

    runSuite("CallSpeakerReadCompleteness: complete empty and untitled scans stay ordinary") {
        for windows in [[], [ScanFixtureWindow(id: 1, title: "")], [ScanFixtureWindow(id: 1, title: "Settings")]] {
            let scan = ScanFixture()
            let read = scan.read([ScanFixtureApp(id: 1, host: .zoom, windows: windows)])
            assertEqual(read.completeness, .complete)
            assertEqual(CallSpeakerSnapshotBuilder.build(read).status, .noWindow)
            assertTrue(scan.visitedTrees.isEmpty)
        }
        let scan = ScanFixture()
        let read = scan.read([], budget: 0)
        assertFalse(read.supportedAppRunning)
        assertEqual(read.completeness, .complete)
        assertTrue(scan.visitedApps.isEmpty)
    }

    runSuite("CallSpeakerReadCompleteness: Slack's no-huddle gate intentionally excludes complete title reads") {
        let scan = ScanFixture()
        let read = scan.read([ScanFixtureApp(id: 1, host: .slack, windows: [ScanFixtureWindow(id: 1, title: "")])])
        assertEqual(read.completeness, .complete)
        assertEqual(scan.slackMicChecks, 1)
        assertEqual(scan.preparations, 0)
        assertTrue(scan.visitedTrees.isEmpty)
        assertEqual(CallSpeakerSnapshotBuilder.build(read).status, .noWindow)

        let allowed = ScanFixture()
        allowed.slackHoldsMicrophone = true
        var untitled = slackScanWindow(1)
        untitled.title = ""
        let active = allowed.read([ScanFixtureApp(id: 1, host: .slack, windows: [untitled])])
        assertEqual(active.completeness, .complete)
        assertEqual(allowed.preparations, 1)
        assertEqual(CallSpeakerSnapshotBuilder.build(active).status, .speakingIndicator)
    }
}
