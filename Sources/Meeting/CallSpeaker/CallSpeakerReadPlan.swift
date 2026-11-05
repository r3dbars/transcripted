// CallSpeakerReadPlan.swift
// The reader's scheduling decisions, as pure functions so they're tested
// without Accessibility: which running app is read first, how much of the
// poll's time each app may use, and when Slack is worth reading at all.
//
// - Order: native call apps (Zoom, Teams), then browsers, then Slack. Slack
//   is open all day and can have dozens of windows; it goes last so it can
//   never eat the time a real meeting window needs.
// - Time: each app gets an even share of what is left of the poll's
//   deadline across the apps not read yet. An app that finishes early (no
//   meeting window) passes its unused time on; one that runs out is cut off
//   at its share (its window comes back truncated, which withholds it if it
//   shows tiles) instead of starving the apps after it.
// - Slack: its windows are walked, and `AXManualAccessibility` is set on it,
//   only when a huddle is likely: a window title says "huddle", or Slack
//   holds the mic input right now. Otherwise only its window titles are read.
//   Slack holds one huddle at a time: the walk stops at the first window
//   read in full that shows huddle tiles.
//
// Privacy: window titles are matched in memory and dropped; never logged.

import ApplicationServices
import Foundation

enum CallSpeakerReadPlan {
    /// Lower reads first.
    static func readRank(_ host: CallSpeakerApp.Host) -> Int {
        switch host {
        case .zoom, .teamsDesktop: return 0
        case .browser: return 1
        case .slack: return 2
        }
    }

    /// `apps` in read order; apps of the same rank keep their order.
    static func ordered<App>(_ apps: [App], host: (App) -> CallSpeakerApp.Host) -> [App] {
        apps.enumerated()
            .sorted { lhs, rhs in
                let left = readRank(host(lhs.element))
                let right = readRank(host(rhs.element))
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// Time held back for each app still to be read after this one: enough
    /// for its window-title reads, which is all an app with no meeting
    /// window costs.
    static let laterAppReserve: TimeInterval = 0.15

    /// When the next app's read must stop: everything left before
    /// `pollDeadline` except a small reserve per app still to come (this one
    /// excluded). An even split starved the call app: a browser is almost
    /// always running, and a big Teams or Zoom tree cut short is withheld.
    /// Apps are read call apps first, so the one most likely to hold the
    /// meeting gets the most time; one with no meeting window is done fast
    /// and passes its time on. The last app gets everything left.
    static func appDeadline(now: Date, pollDeadline: Date, appsLeft: Int) -> Date {
        let remaining = pollDeadline.timeIntervalSince(now)
        guard appsLeft > 1, remaining > 0 else { return pollDeadline }
        let reserved = laterAppReserve * Double(appsLeft - 1)
        let share = max(remaining - reserved, remaining / Double(appsLeft))
        return now.addingTimeInterval(share)
    }

    /// Whether Slack is likely in a huddle, so its windows are worth walking.
    /// `holdsMicrophone` is only asked when no title says "huddle".
    static func isSlackHuddleLikely(windowTitles: [String], holdsMicrophone: () -> Bool) -> Bool {
        windowTitles.contains(where: CallSpeakerWindowMatcher.isLikelyHuddleTitle) || holdsMicrophone()
    }

    /// Whether Slack (or one of its helper processes, which is what takes
    /// the mic in Electron) is among the processes holding the mic input.
    static func isSlackHoldingMicrophone(micInputBundleIDs: Set<String>) -> Bool {
        micInputBundleIDs.contains { bundleID in
            CallSpeakerApp.slackBundleIDs.contains { id in bundleID == id || bundleID.hasPrefix(id + ".") }
        }
    }
}

// MARK: - Bounded scan orchestration

extension CallSpeakerReadPlan {
    static let maxWindowsPerApp = 8
    static let maxSlackWindows = 32
    static let maxNodesPerWindow = 4000
    /// Window titles read per app before the app's list counts as too long
    /// to examine. Titles are one cheap read each; only meeting candidates
    /// count against `maxWindowsPerApp` / `maxSlackWindows`.
    static let maxTitleReadsPerApp = 64

    struct WindowScan {
        var windows: [CallSpeakerWindowRead]
        var completeness: CallSpeakerReadResult.Completeness
        var diagnostics = CallSpeakerScanDiagnostics()

        static let empty = WindowScan(windows: [], completeness: .complete)

        static func incomplete(
            _ issue: CallSpeakerScanIssue,
            windows: [CallSpeakerWindowRead] = [],
            diagnostics: CallSpeakerScanDiagnostics = .init()
        ) -> WindowScan {
            var diagnostics = diagnostics
            diagnostics.incompleteness[issue, default: 0] += 1
            return WindowScan(windows: windows, completeness: .incomplete, diagnostics: diagnostics)
        }
    }

    /// One window title read: its text ("" when it has none, or the window
    /// closed mid-scan), or why it couldn't be read.
    enum TitleRead: Equatable {
        case text(String)
        case failed(CallSpeakerScanIssue)
    }

    struct TreeRead {
        var tree: CallSpeakerAXNode
        var truncated: Bool
        /// Total consumed nodes, including the supplied initial shared count.
        var visitedNodes: Int
        /// Why the walk was cut short or left elements out.
        var diagnostics = CallSpeakerScanDiagnostics()
    }

    /// The live reader uses these loops with AX operations; tests inject
    /// window handles and virtual time. A skipped supported app is unknown,
    /// not evidence that the windows already returned belong to the only call.
    static func scanApps<App>(
        _ apps: [App],
        host: (App) -> CallSpeakerApp.Host,
        deadline: Date,
        now: () -> Date,
        read: (App, Date) -> WindowScan
    ) -> CallSpeakerReadResult {
        guard !apps.isEmpty else { return .nothingRunning }
        let orderedApps = ordered(apps, host: host)
        var windows: [CallSpeakerWindowRead] = []
        var diagnostics = CallSpeakerScanDiagnostics()
        for (index, app) in orderedApps.enumerated() {
            let time = now()
            guard time < deadline else {
                diagnostics.incompleteness[.deadline, default: 0] += 1
                return CallSpeakerReadResult(supportedAppRunning: true, windows: windows, completeness: .incomplete, diagnostics: diagnostics)
            }
            let result = read(app, appDeadline(now: time, pollDeadline: deadline, appsLeft: orderedApps.count - index))
            windows.append(contentsOf: result.windows)
            diagnostics.merge(result.diagnostics)
            guard result.completeness == .complete else {
                return CallSpeakerReadResult(supportedAppRunning: true, windows: windows, completeness: .incomplete, diagnostics: diagnostics)
            }
        }
        return CallSpeakerReadResult(supportedAppRunning: true, windows: windows, completeness: .complete, diagnostics: diagnostics)
    }

    /// Ordinary unmatched/untitled windows and Slack's no-huddle gate are
    /// complete exclusions. Budget limits, failed title reads and candidates
    /// left unread are not.
    ///
    /// A candidate whose walk was cut short (node cap, depth, deadline, or
    /// an AX "couldn't finish") is still returned, marked truncated, and the
    /// scan goes on: `CallSpeakerSnapshotBuilder` withholds a cut-short
    /// window that shows tiles, and ignores one that shows none (a Teams
    /// chat or a big Slack main window). Only candidates never read make the
    /// scan incomplete.
    ///
    /// Slack holds one huddle at a time, so once one Slack window has been
    /// read in full and shows huddle tiles, the rest aren't walked.
    static func scanWindows<Window>(
        _ windows: [Window],
        host: CallSpeakerApp.Host,
        deadline: Date,
        now: () -> Date,
        title: (Window, Date) -> TitleRead,
        slackHoldsMicrophone: () -> Bool,
        prepareForWalk: (Date) -> Void,
        readTree: (Window, Date, Int) -> TreeRead
    ) -> WindowScan {
        let isSlack = host == .slack
        let limit = isSlack ? maxSlackWindows : maxWindowsPerApp
        // A list too long to read every title of could hide a call in its
        // unread tail. Do not interpret a bounded prefix as complete.
        guard windows.count <= maxTitleReadsPerApp else { return .incomplete(.windowCap) }
        var candidates: [(window: Window, match: CallSpeakerWindowMatch, huddle: Bool)] = []
        var titles: [String] = []
        for window in windows {
            guard now() < deadline else { return .incomplete(.deadline) }
            let text: String
            switch title(window, deadline) {
            case .text(let read): text = read
            case .failed(let issue): return .incomplete(issue)
            }
            guard let match = CallSpeakerWindowMatcher.match(title: text, host: host) else { continue }
            if isSlack { titles.append(text) }
            candidates.append((window, match, CallSpeakerWindowMatcher.isLikelyHuddleTitle(text)))
        }
        guard !candidates.isEmpty else { return .empty }
        // Windows that aren't meetings never count; more meeting candidates
        // than one poll walks could hide a second call in the unread ones.
        guard candidates.count <= limit else { return .incomplete(.windowCap) }
        if isSlack {
            guard isSlackHuddleLikely(windowTitles: titles, holdsMicrophone: slackHoldsMicrophone) else { return .empty }
            candidates.sort { $0.huddle && !$1.huddle }
        }
        prepareForWalk(deadline)

        var reads: [CallSpeakerWindowRead] = []
        var diagnostics = CallSpeakerScanDiagnostics()
        var sharedNodes = 0
        for candidate in candidates {
            guard now() < deadline else {
                return .incomplete(.deadline, windows: reads, diagnostics: diagnostics)
            }
            // Slack's shared budget ran out before this candidate: it is unread.
            guard !isSlack || sharedNodes < maxNodesPerWindow else {
                return .incomplete(.nodeCap, windows: reads, diagnostics: diagnostics)
            }
            let result = readTree(candidate.window, deadline, isSlack ? sharedNodes : 0)
            diagnostics.merge(result.diagnostics)
            let read = CallSpeakerWindowRead(match: candidate.match, tree: result.tree, truncated: result.truncated)
            reads.append(read)
            if isSlack {
                sharedNodes = result.visitedNodes
                if !result.truncated && showsTiles(read) { break }
            }
        }
        return WindowScan(windows: reads, completeness: .complete, diagnostics: diagnostics)
    }

    /// Whether the app's parser finds any call tile in this window.
    static func showsTiles(_ window: CallSpeakerWindowRead) -> Bool {
        CallSpeakerSelectorTable.parser(for: window.match.app).parse(window.tree).hasTiles
    }
}

// MARK: - Scan diagnostics

/// Why a window read was cut short, a scan stopped early, or an element was
/// skipped. Reasons and raw AX error codes only: safe for the summary log.
enum CallSpeakerScanIssue: Hashable, Sendable {
    case axError(Int32)
    case deadline
    case nodeCap
    case depthCap
    case windowCap
    /// AX answered `.success` with a value of the wrong shape.
    case unexpectedValue

    static func ax(_ error: AXError) -> CallSpeakerScanIssue { .axError(error.rawValue) }

    /// "ax_25204" for `kAXErrorCannotComplete` (-25204), else the reason.
    var logKey: String {
        switch self {
        case .axError(let code): return "ax_\(abs(Int(code)))"
        case .deadline: return "deadline"
        case .nodeCap: return "node_cap"
        case .depthCap: return "depth_cap"
        case .windowCap: return "window_cap"
        case .unexpectedValue: return "unexpected_value"
        }
    }
}

/// Counts of `CallSpeakerScanIssue`s, per poll and summed per recording.
struct CallSpeakerScanDiagnostics: Equatable, Sendable {
    /// Why windows came back cut short, whether or not the cut withheld.
    var truncations: [CallSpeakerScanIssue: Int] = [:]
    /// Why a scan stopped before every app, window title or candidate was examined.
    var incompleteness: [CallSpeakerScanIssue: Int] = [:]
    /// Elements left out mid-walk (destroyed, or an unreadable batch) without withholding.
    var skippedElements: [CallSpeakerScanIssue: Int] = [:]

    var isEmpty: Bool { truncations.isEmpty && incompleteness.isEmpty && skippedElements.isEmpty }

    mutating func merge(_ other: CallSpeakerScanDiagnostics) {
        truncations.merge(other.truncations, uniquingKeysWith: +)
        incompleteness.merge(other.incompleteness, uniquingKeysWith: +)
        skippedElements.merge(other.skippedElements, uniquingKeysWith: +)
    }

    /// Log context: "truncated_<reason>", "incomplete_<reason>", "skipped_<reason>".
    var logContext: [String: String] {
        var context: [String: String] = [:]
        for (issue, count) in truncations { context["truncated_\(issue.logKey)"] = "\(count)" }
        for (issue, count) in incompleteness { context["incomplete_\(issue.logKey)"] = "\(count)" }
        for (issue, count) in skippedElements { context["skipped_\(issue.logKey)"] = "\(count)" }
        return context
    }
}
