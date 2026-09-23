// MeetingPromptLearnedBackoff.swift
// Remembers how the user answers the detected-call prompt, per kind of call,
// across relaunches. Foundation only.
//
// Before this, "Not now" bought 30 minutes, the memory lived only in RAM, and
// a relaunch or a new day started the nagging over. Now each consecutive
// "Not now" for the same kind of call stays quiet longer, a Record resets it,
// and an unrecognized browser mic that the user keeps turning down stops
// prompting on its own.
//
// Kinds are coarse strings (`native:zoom`, `browser_verified`,
// `browser_unverified`) so a "Not now" to ChatGPT voice never silences a real
// Google Meet tab. Nothing here holds titles, bundle IDs, or times of day
// beyond the quiet window itself; it lives in the app's own UserDefaults.

import Foundation

final class MeetingPromptLearnedBackoff {
    struct Entry: Codable, Equatable {
        var dismissStreak: Int = 0
        var quietUntil: Date?
        var lastDismissedAt: Date?
        var recordCount: Int = 0
    }

    static let defaultsKey = "meeting-prompt-learned-backoff-v1"

    /// Quiet time after the Nth consecutive "Not now" for a kind of call we
    /// have real evidence for (a native app, a named call tab, the camera).
    /// Capped at 8 hours so tomorrow's meeting still gets its prompt.
    static let verifiedQuietSchedule: [TimeInterval] = [30 * 60, 2 * 60 * 60, 8 * 60 * 60]
    /// Quiet time for an unrecognized browser mic (no call title, no camera).
    /// These are the ChatGPT-voice and web-dictation cases, so they back off
    /// harder and can reach a full day.
    static let unverifiedQuietSchedule: [TimeInterval] = [30 * 60, 2 * 60 * 60, 8 * 60 * 60, 24 * 60 * 60]
    /// After this many consecutive "Not now"s with no recording ever made from
    /// that kind, an unrecognized browser mic stops prompting until the streak
    /// is forgotten. A named call tab or the camera still prompts.
    static let learnedOffStreak = 3
    /// A streak older than this is forgotten, so a habit from weeks ago does
    /// not keep the prompt quiet forever.
    static let streakForgetInterval: TimeInterval = 14 * 24 * 60 * 60

    static let unverifiedBrowserKind = "browser_unverified"
    static let verifiedBrowserKind = "browser_verified"

    static func nativeKind(for provider: MeetingPromptProvider) -> String {
        "native:\(provider.rawValue)"
    }

    private let userDefaults: UserDefaults?
    private var entries: [String: Entry]

    /// `userDefaults: nil` keeps everything in memory (tests, and any detector
    /// the app did not opt into persistence).
    init(userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults
        if let data = userDefaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    static func quietInterval(forStreak streak: Int, kind: String) -> TimeInterval {
        let schedule = kind == unverifiedBrowserKind ? unverifiedQuietSchedule : verifiedQuietSchedule
        let index = min(max(streak, 1), schedule.count) - 1
        return schedule[index]
    }

    func entry(for kind: String, now: Date) -> Entry {
        forgettingStaleStreak(entries[kind] ?? Entry(), now: now)
    }

    func dismissStreak(for kind: String, now: Date) -> Int {
        entry(for: kind, now: now).dismissStreak
    }

    /// When the kind is quiet because of earlier "Not now"s, the end of that
    /// quiet window. `nil` when it may prompt.
    func quietUntil(for kind: String, now: Date) -> Date? {
        guard let until = entry(for: kind, now: now).quietUntil, until > now else { return nil }
        return until
    }

    /// Whether an unrecognized browser mic has been turned down enough times,
    /// with no recording ever made from it, that it should stop prompting.
    func isLearnedOff(kind: String, now: Date) -> Bool {
        guard kind == Self.unverifiedBrowserKind else { return false }
        let entry = entry(for: kind, now: now)
        return entry.recordCount == 0 && entry.dismissStreak >= Self.learnedOffStreak
    }

    /// An explicit "Not now". Returns the end of the quiet window it starts.
    @discardableResult
    func recordDismissal(kind: String, now: Date) -> Date {
        var entry = entry(for: kind, now: now)
        entry.dismissStreak += 1
        entry.lastDismissedAt = now
        let until = now.addingTimeInterval(Self.quietInterval(forStreak: entry.dismissStreak, kind: kind))
        entry.quietUntil = max(entry.quietUntil ?? .distantPast, until)
        entries[kind] = entry
        persist()
        return until
    }

    /// The user recorded this kind of call (from the prompt, or by starting a
    /// meeting while it was going on). Clears the streak and any quiet window.
    func recordAccepted(kind: String, now: Date) {
        var entry = entry(for: kind, now: now)
        entry.dismissStreak = 0
        entry.quietUntil = nil
        entry.lastDismissedAt = nil
        entry.recordCount = min(entry.recordCount + 1, 1_000)
        entries[kind] = entry
        persist()
    }

    private func forgettingStaleStreak(_ entry: Entry, now: Date) -> Entry {
        guard let last = entry.lastDismissedAt,
              now.timeIntervalSince(last) > Self.streakForgetInterval else { return entry }
        var reset = entry
        reset.dismissStreak = 0
        reset.lastDismissedAt = nil
        return reset
    }

    private func persist() {
        guard let userDefaults,
              let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
