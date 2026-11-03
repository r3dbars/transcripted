// CallSpeakerActivityStore.swift
// Finished call-app activity waiting for its meeting's transcription, keyed
// by the recording's start date (the same `Date` the pipeline receives as
// `recordingDate`). Bounded: a queue of unclaimed meetings can't grow it past
// `capacity`. Memory only; a meeting retried after relaunch has no call names.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct CallSpeakerActivityStore: Sendable {
    static let defaultCapacity = 8
    /// Dates match within this much. The key is passed through in memory, so
    /// it should be exact; the slack only absorbs a round trip through a
    /// serialized queue entry.
    static let matchTolerance: TimeInterval = 0.5

    struct Entry: Sendable {
        let recordingStartedAt: Date
        let activity: CallSpeakerActivity
    }

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    mutating func put(_ activity: CallSpeakerActivity, recordingStartedAt: Date) {
        drop(recordingStartedAt: recordingStartedAt)
        entries.append(Entry(recordingStartedAt: recordingStartedAt, activity: activity))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// The activity for a recording, removed so it is handed out once.
    mutating func take(recordingStartedAt: Date?) -> CallSpeakerActivity? {
        guard let index = index(for: recordingStartedAt) else { return nil }
        return entries.remove(at: index).activity
    }

    /// The pipeline's hand-out: the activity for a recording, or nil (and the
    /// activity dropped) when "Name speakers from the call app" is off now.
    /// Turning the setting off after a meeting, before its transcription
    /// runs, keeps call-app names out of that meeting too.
    mutating func take(recordingStartedAt: Date?, enabled: Bool) -> CallSpeakerActivity? {
        let activity = take(recordingStartedAt: recordingStartedAt)
        return enabled ? activity : nil
    }

    mutating func drop(recordingStartedAt: Date?) {
        while let index = index(for: recordingStartedAt) {
            entries.remove(at: index)
        }
    }

    private func index(for date: Date?) -> Int? {
        guard let date else { return nil }
        return entries.lastIndex { abs($0.recordingStartedAt.timeIntervalSince(date)) <= Self.matchTolerance }
    }
}
