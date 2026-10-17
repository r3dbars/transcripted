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
