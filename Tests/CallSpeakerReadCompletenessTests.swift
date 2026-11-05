// CallSpeakerReadCompletenessTests.swift
// Promise: a poll names nobody unless every supported app, window title and
// meeting candidate was examined. Candidates never read (deadline, caps,
// failed title or window-list reads) withhold the whole poll. A window cut
// short that shows no tiles (a Teams chat, a big Slack main window) doesn't
// count; one that shows tiles still withholds. Windowless apps and elements
// destroyed mid-walk are ordinary, and only "couldn't finish" AX errors cut a
// window short. All names and titles are fictional.

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
                guard let windows = app.windows else { return .incomplete(.ax(.cannotComplete)) }
                return CallSpeakerReadPlan.scanWindows(
                    windows,
                    host: app.host,
                    deadline: deadline,
                    now: { self.time },
                    title: { window, _ in
                        self.visitedTitles.append(window.id)
                        self.time.addTimeInterval(window.titleCost)
                        return window.title.map { .text($0) } ?? .failed(.ax(.cannotComplete))
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
                        var diagnostics = CallSpeakerScanDiagnostics()
                        if window.truncated { diagnostics.truncations[.nodeCap] = 1 }
                        return CallSpeakerReadPlan.TreeRead(
                            tree: window.tree,
                            truncated: window.truncated,
                            visitedNodes: initialNodes + window.visitedNodes,
                            diagnostics: diagnostics
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

private func slackScanWindow(_ id: Int, title: String = "Huddle in #planning - Slack") -> ScanFixtureWindow {
    ScanFixtureWindow(id: id, title: title, tree: CallSpeakerAXNode(
        domClassList: ["p-huddle_peer_tile"],
        children: [
            .init(description: "View Ana Ruiz's profile"),
            .init(domClassList: ["p-huddle_peer_tile__overlay--active_speaker"]),
        ]
    ))
}

/// A Slack window with channel content but no huddle tiles.
private func slackMainWindow(_ id: Int, visitedNodes: Int, truncated: Bool) -> ScanFixtureWindow {
    ScanFixtureWindow(
        id: id,
        title: "general (Channel) - Acme - Slack",
        tree: CallSpeakerAXNode(role: "AXWindow", children: [.init(role: "AXStaticText", value: "Channel messages")]),
        truncated: truncated,
        visitedNodes: visitedNodes
    )
}

private func teamsTile(_ name: String, speaking: Bool) -> CallSpeakerAXNode {
    CallSpeakerAXNode(
        role: "AXMenuItem",
        description: "\(name), unmuted More options",
        children: speaking ? [CallSpeakerAXNode(role: "AXGroup", domClassList: ["vdi-frame-occlusion"])] : []
    )
}

private func axErrorPlaceholder(_ error: AXError) -> AnyObject {
    var error = error
    return AXValueCreate(.axError, &error)!
}

/// A batch-read result shaped like the reader's attribute list, with one
/// placeholder at `index`.
private func batchValues(placeholder: AXError, at index: Int, count: Int = 10) -> [AnyObject] {
    (0..<count).map { $0 == index ? axErrorPlaceholder(placeholder) : ("AXGroup" as NSString) }
}

private func assertIncompleteScan(_ read: CallSpeakerReadResult) {
    assertEqual(read.completeness, .incomplete, "unexamined calls are unknown")
    let snapshot = CallSpeakerSnapshotBuilder.build(read)
    assertEqual(snapshot.status, .incompleteScan)
    assertTrue(snapshot.speaking.isEmpty && snapshot.roster.isEmpty && snapshot.selfNames.isEmpty,
               "partial names cannot leak into evidence or roster metadata")
    assertTrue(snapshot.status.isWithheld)
}

private func assertNamesAna(_ read: CallSpeakerReadResult, _ message: String) {
    assertEqual(read.completeness, .complete, message)
    let snapshot = CallSpeakerSnapshotBuilder.build(read)
    assertEqual(snapshot.status, .speakingIndicator, message)
    assertEqual(snapshot.speaking, ["Ana Ruiz"], message)
}

func testCallSpeakerReadCompleteness() {
    runSuite("CallSpeakerReadCompleteness: native AX absence and failures remain distinct") {
        for status in [AXError.success, .noValue, .attributeUnsupported, .invalidUIElement] {
            assertEqual(CallSpeakerAXTreeReader.titleValue(status: status, value: nil), .text(""),
                        "no title, or a window closed mid-scan, is an untitled window")
        }
        assertEqual(CallSpeakerAXTreeReader.titleValue(status: .success, value: "" as NSString), .text(""))
        assertEqual(CallSpeakerAXTreeReader.titleValue(status: .success, value: "Settings" as NSString), .text("Settings"))
        for status in [AXError.cannotComplete, .failure] {
            assertEqual(CallSpeakerAXTreeReader.titleValue(status: status, value: nil), .failed(.ax(status)))
        }
        assertEqual(CallSpeakerAXTreeReader.titleValue(status: .success, value: NSNumber(value: 1)), .failed(.unexpectedValue))
    }

    runSuite("CallSpeakerReadCompleteness: a windowless app is an empty, complete read") {
        for (status, value) in [(AXError.noValue, nil), (.success, nil), (.success, [] as NSArray)] as [(AXError, AnyObject?)] {
            guard case .windows(let windows) = CallSpeakerAXTreeReader.windowListValue(status: status, value: value) else {
                assertTrue(false, "a windowless app answering \(status.rawValue) has no windows to read")
                continue
            }
            assertTrue(windows.isEmpty)
        }
        for status in [AXError.cannotComplete, .failure, .invalidUIElement] {
            guard case .failed(let issue) = CallSpeakerAXTreeReader.windowListValue(status: status, value: nil) else {
                assertTrue(false, "a failed window list (\(status.rawValue)) leaves the app unexamined")
                continue
            }
            assertEqual(issue, .ax(status))
        }

        let scan = ScanFixture()
        let read = scan.read([
            ScanFixtureApp(id: 1, host: .zoom, windows: [zoomScanWindow(1)]),
            ScanFixtureApp(id: 2, host: .zoom, windows: []),
        ])
        assertNamesAna(read, "a windowless second app doesn't withhold the call")
    }

    runSuite("CallSpeakerReadCompleteness: only couldn't-finish errors cut an element read short") {
        let domIdentifier = 7, domClassList = 8, role = 0, children = 9
        for index in [domIdentifier, domClassList] {
            for error in [AXError.failure, .illegalArgument, .noValue, .attributeUnsupported] {
                assertEqual(CallSpeakerAXTreeReader.elementReadOutcome(batchValues(placeholder: error, at: index)), .usable,
                            "a native app's \(error.rawValue) for a web-only attribute means it is absent")
            }
        }
        for index in [role, domIdentifier, children] {
            assertEqual(CallSpeakerAXTreeReader.elementReadOutcome(batchValues(placeholder: .cannotComplete, at: index)),
                        .truncate(.cannotComplete), "a timeout on any attribute leaves part of the window unread")
            assertEqual(CallSpeakerAXTreeReader.elementReadOutcome(batchValues(placeholder: .invalidUIElement, at: index)),
                        .skip(.invalidUIElement), "an element destroyed mid-walk is skipped, not a cut-short window")
        }
        assertEqual(CallSpeakerAXTreeReader.elementReadOutcome(batchValues(placeholder: .failure, at: children)),
                    .truncate(.failure), "a failed children read hides a subtree")
        for error in [AXError.noValue, .attributeUnsupported] {
            assertEqual(CallSpeakerAXTreeReader.elementReadOutcome(batchValues(placeholder: error, at: role)), .usable)
        }
        assertEqual(CallSpeakerAXTreeReader.elementReadOutcome(["AXGroup" as NSString]), .usable)
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
        assertEqual(read.diagnostics.incompleteness, [.deadline: 1], "the summary says why the scan stopped")

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
            assertEqual(read.diagnostics.incompleteness, [.ax(.cannotComplete): 1], "the AX code behind it is counted")
        }
    }

    runSuite("CallSpeakerReadCompleteness: window caps count meeting candidates, never a prefix of them") {
        for (host, limit) in [(CallSpeakerApp.Host.zoom, 8), (.slack, 32)] {
            let scan = ScanFixture()
            let windows = (0...limit).map { id in host == .slack ? slackScanWindow(id) : zoomScanWindow(id) }
            assertIncompleteScan(scan.read([ScanFixtureApp(id: 1, host: host, windows: windows)]))
            assertTrue(scan.visitedTrees.isEmpty, "more candidates than a poll walks can't justify reading some of them")
        }

        let manyWindows = ScanFixture()
        let windows = [zoomScanWindow(0)] + (1...12).map { ScanFixtureWindow(id: $0, title: "Settings") }
        assertNamesAna(manyWindows.read([ScanFixtureApp(id: 1, host: .zoom, windows: windows)]),
                       "windows that aren't meetings don't count against the candidate cap")
        assertEqual(manyWindows.visitedTrees, [0])

        let tooManyTitles = ScanFixture()
        let huge = [zoomScanWindow(0)] + (1...CallSpeakerReadPlan.maxTitleReadsPerApp).map { ScanFixtureWindow(id: $0, title: "Settings") }
        assertIncompleteScan(tooManyTitles.read([ScanFixtureApp(id: 1, host: .zoom, windows: huge)]))
        assertTrue(tooManyTitles.visitedTitles.isEmpty, "a list too long to read every title of is not examined at all")
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

    runSuite("CallSpeakerReadCompleteness: a cut-short window with no tiles doesn't count; one with tiles withholds") {
        // A Teams window cut short before any tile, beside a complete Zoom call.
        let scan = ScanFixture()
        var teams = ScanFixtureWindow(id: 1, title: "Weekly sync | Microsoft Teams",
                                      tree: CallSpeakerAXNode(role: "AXWindow"))
        teams.truncated = true
        let read = scan.read([
            ScanFixtureApp(id: 1, host: .teamsDesktop, windows: [teams]),
            ScanFixtureApp(id: 2, host: .zoom, windows: [zoomScanWindow(2)]),
        ])
        assertEqual(scan.visitedTrees, [1, 2], "the scan goes on past the cut-short window")
        assertNamesAna(read, "the Zoom call is still named")
        assertEqual(read.diagnostics.truncations, [.nodeCap: 1], "the cut is still counted for the summary")

        // The same cut window showing a tile is a second call that can't be read.
        let tiles = ScanFixture()
        var teamsWithTiles = teams
        teamsWithTiles.tree = CallSpeakerAXNode(role: "AXWindow", children: [teamsTile("Ben Okafor", speaking: true)])
        let withTiles = tiles.read([
            ScanFixtureApp(id: 1, host: .teamsDesktop, windows: [teamsWithTiles]),
            ScanFixtureApp(id: 2, host: .zoom, windows: [zoomScanWindow(2)]),
        ])
        let snapshot = CallSpeakerSnapshotBuilder.build(withTiles)
        assertTrue(snapshot.status.isWithheld, "a cut-short window with tiles withholds the poll")
        assertTrue(snapshot.speaking.isEmpty)

        let alone = ScanFixture()
        var cutZoom = zoomScanWindow(1)
        cutZoom.truncated = true
        let cutRead = alone.read([ScanFixtureApp(id: 1, host: .zoom, windows: [cutZoom])])
        assertEqual(CallSpeakerSnapshotBuilder.build(cutRead).status, .truncated,
                    "the call's own window cut short may have missed a speaking tile")
    }

    runSuite("CallSpeakerReadCompleteness: a Teams chat beside a Zoom call never withholds the call") {
        for host in [CallSpeakerApp.Host.teamsDesktop, .browser] {
            let scan = ScanFixture()
            var chat = ScanFixtureWindow(id: 1, title: "Chat | General | Microsoft Teams" + (host == .browser ? " - Microsoft Edge" : ""),
                                         tree: CallSpeakerAXNode(role: "AXWindow"))
            chat.truncated = true
            chat.treeCost = 1.3
            let read = scan.read([
                ScanFixtureApp(id: 1, host: host, windows: [chat]),
                ScanFixtureApp(id: 2, host: .zoom, windows: [zoomScanWindow(2)]),
            ])
            assertEqual(scan.visitedTrees, [2], "the chat page isn't walked, so it can't eat the call's time")
            assertNamesAna(read, "Zoom names survive a Teams chat open in \(host)")
        }
    }

    runSuite("CallSpeakerReadCompleteness: a Slack huddle is read beside a large main window") {
        let scan = ScanFixture()
        scan.slackHoldsMicrophone = true
        let main = slackMainWindow(1, visitedNodes: 4000, truncated: true)
        let read = scan.read([ScanFixtureApp(id: 1, host: .slack, windows: [main, slackScanWindow(2)])])
        assertEqual(scan.visitedTrees, [2], "the huddle is read first and is the one call; the main window isn't walked")
        assertNamesAna(read, "huddle names survive a big Slack main window")

        // Untitled huddle behind a main window cut short with budget to spare.
        let late = ScanFixture()
        late.slackHoldsMicrophone = true
        let afterMain = late.read([ScanFixtureApp(id: 1, host: .slack, windows: [
            slackMainWindow(1, visitedNodes: 1500, truncated: true),
            slackScanWindow(2, title: "Acme - Slack"),
            slackScanWindow(3, title: "Design - Slack"),
        ])])
        assertEqual(late.visitedTrees, [1, 2], "the walk stops at the first full huddle read")
        assertEqual(late.initialNodeCounts, [0, 1500], "Slack shares the consumed node count")
        assertNamesAna(afterMain, "a cut-short Slack window without tiles doesn't withhold the huddle")
    }

    runSuite("CallSpeakerReadCompleteness: Slack's spent node budget cannot hide an unread huddle") {
        let scan = ScanFixture()
        scan.slackHoldsMicrophone = true
        let read = scan.read([
            ScanFixtureApp(id: 1, host: .zoom, windows: [zoomScanWindow(1)]),
            ScanFixtureApp(id: 2, host: .slack, windows: [
                slackMainWindow(1, visitedNodes: 4000, truncated: true),
                slackScanWindow(2, title: "Acme - Slack"),
            ]),
        ])
        assertEqual(scan.visitedTrees, [1, 1], "Zoom's window, then only Slack's main window")
        assertIncompleteScan(read)
        assertEqual(read.diagnostics.incompleteness, [.nodeCap: 1])

        let complete = ScanFixture()
        var exact = slackScanWindow(1)
        exact.visitedNodes = 4000
        let single = complete.read([ScanFixtureApp(id: 1, host: .slack, windows: [exact])])
        assertEqual(single.completeness, .complete, "exactly consuming the budget is fine when no candidate remains")
        assertEqual(CallSpeakerSnapshotBuilder.build(single).status, .speakingIndicator)
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

    runSuite("CallSpeakerReadCompleteness: the summary log carries codes and counts only") {
        var diagnostics = CallSpeakerScanDiagnostics()
        diagnostics.truncations[.ax(.cannotComplete)] = 2
        diagnostics.incompleteness[.deadline] = 1
        diagnostics.skippedElements[.ax(.invalidUIElement)] = 3
        assertEqual(diagnostics.logContext, [
            "truncated_ax_25204": "2",
            "incomplete_deadline": "1",
            "skipped_ax_25202": "3",
        ])
        var total = diagnostics
        total.merge(diagnostics)
        assertEqual(total.truncations[.ax(.cannotComplete)], 4)
    }
}
