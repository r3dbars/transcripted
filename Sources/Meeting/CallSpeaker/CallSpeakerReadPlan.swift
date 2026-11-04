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
//   at its share (its window comes back truncated and is withheld) instead
//   of starving the apps after it.
// - Slack: its windows are walked, and `AXManualAccessibility` is set on it,
//   only when a huddle is likely: a window title says "huddle", or Slack
//   holds the mic input right now. Otherwise only its window titles are read.
//
// Privacy: window titles are matched in memory and dropped; never logged.

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

    struct WindowScan {
        var windows: [CallSpeakerWindowRead]
        var completeness: CallSpeakerReadResult.Completeness

        static let empty = WindowScan(windows: [], completeness: .complete)
        static let incomplete = WindowScan(windows: [], completeness: .incomplete)
    }

    struct TreeRead {
        var tree: CallSpeakerAXNode
        var truncated: Bool
        /// Total consumed nodes, including the supplied initial shared count.
        var visitedNodes: Int
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
        for (index, app) in orderedApps.enumerated() {
            let time = now()
            guard time < deadline else {
                return CallSpeakerReadResult(supportedAppRunning: true, windows: windows, completeness: .incomplete)
            }
            let result = read(app, appDeadline(now: time, pollDeadline: deadline, appsLeft: orderedApps.count - index))
            windows.append(contentsOf: result.windows)
            guard result.completeness == .complete else {
                return CallSpeakerReadResult(supportedAppRunning: true, windows: windows, completeness: .incomplete)
            }
        }
        return CallSpeakerReadResult(supportedAppRunning: true, windows: windows, completeness: .complete)
    }

    /// A successful empty title is ""; nil means the title read failed.
    /// Ordinary unmatched/untitled windows and Slack's no-huddle gate are
    /// complete exclusions. Budget limits and failed reads are not.
    static func scanWindows<Window>(
        _ windows: [Window],
        host: CallSpeakerApp.Host,
        deadline: Date,
        now: () -> Date,
        title: (Window, Date) -> String?,
        slackHoldsMicrophone: () -> Bool,
        prepareForWalk: (Date) -> Void,
        readTree: (Window, Date, Int) -> TreeRead
    ) -> WindowScan {
        let isSlack = host == .slack
        let limit = isSlack ? maxSlackWindows : maxWindowsPerApp
        // The omitted tail can contain a second call. Do not interpret a
        // bounded prefix as a complete list or walk its partial candidates.
        guard windows.count <= limit else { return .incomplete }
        var candidates: [(window: Window, match: CallSpeakerWindowMatch, huddle: Bool)] = []
        var titles: [String] = []
        for window in windows {
            guard now() < deadline, let text = title(window, deadline) else { return .incomplete }
            guard let match = CallSpeakerWindowMatcher.match(title: text, host: host) else { continue }
            if isSlack { titles.append(text) }
            candidates.append((window, match, CallSpeakerWindowMatcher.isLikelyHuddleTitle(text)))
        }
        guard !candidates.isEmpty else { return .empty }
        if isSlack {
            guard isSlackHuddleLikely(windowTitles: titles, holdsMicrophone: slackHoldsMicrophone) else { return .empty }
            candidates.sort { $0.huddle && !$1.huddle }
        }
        prepareForWalk(deadline)

        var reads: [CallSpeakerWindowRead] = []
        var sharedNodes = 0
        for candidate in candidates {
            guard now() < deadline, !isSlack || sharedNodes < maxNodesPerWindow else {
                return WindowScan(windows: reads, completeness: .incomplete)
            }
            let result = readTree(candidate.window, deadline, isSlack ? sharedNodes : 0)
            reads.append(CallSpeakerWindowRead(match: candidate.match, tree: result.tree, truncated: result.truncated))
            guard !result.truncated else { return WindowScan(windows: reads, completeness: .incomplete) }
            if isSlack { sharedNodes = result.visitedNodes }
        }
        return WindowScan(windows: reads, completeness: .complete)
    }
}
