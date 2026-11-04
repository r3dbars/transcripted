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
    /// Shared across queued recordings, not a separate 40 MiB journal per row.
    static let defaultMaximumTimelineSegments = 1_048_576
    /// Dates match within this much. The key is passed through in memory, so
    /// it should be exact; the slack only absorbs a round trip through a
    /// serialized queue entry.
    static let matchTolerance: TimeInterval = 0.5

    struct Entry: Sendable {
        let recordingStartedAt: Date
        let activity: CallSpeakerActivity?
        let observation: CallSpeakerObservedActivity?
        var timeline: RecordedSystemAudioTimeline?

        func alignedActivity() -> CallSpeakerActivity? {
            observation?.aligned(to: timeline) ?? activity
        }
    }

    let capacity: Int
    let maximumTimelineSegments: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int = defaultCapacity, maximumTimelineSegments: Int = defaultMaximumTimelineSegments) {
        self.capacity = max(1, capacity)
        self.maximumTimelineSegments = max(0, min(maximumTimelineSegments, Self.defaultMaximumTimelineSegments))
    }

    var count: Int { entries.count }
    var storedTimelineSegmentCount: Int { entries.reduce(0) { $0 + ($1.timeline?.segmentCount ?? 0) } }

    mutating func put(_ activity: CallSpeakerActivity, recordingStartedAt: Date) {
        drop(recordingStartedAt: recordingStartedAt)
        entries.append(Entry(recordingStartedAt: recordingStartedAt, activity: activity, observation: nil))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func put(_ observation: CallSpeakerObservedActivity, recordingStartedAt: Date) {
        drop(recordingStartedAt: recordingStartedAt)
        entries.append(Entry(recordingStartedAt: recordingStartedAt, activity: nil, observation: observation))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    mutating func attach(_ timeline: RecordedSystemAudioTimeline?, recordingStartedAt: Date?) {
        guard let index = index(for: recordingStartedAt) else { return }
        entries[index].timeline = nil
        guard let timeline, timeline.segmentCount <= maximumTimelineSegments else { return }
        entries[index].timeline = timeline
        var storedSegments = storedTimelineSegmentCount
        // Capture artifacts and observed metadata survive. Only optional old
        // coordinate maps are evicted, so their queued jobs withhold names.
        for older in entries.indices where storedSegments > maximumTimelineSegments {
            storedSegments -= entries[older].timeline?.segmentCount ?? 0
            entries[older].timeline = nil
        }
    }

    mutating func takeEntry(recordingStartedAt: Date?) -> Entry? {
        guard let index = index(for: recordingStartedAt) else { return nil }
        return entries.remove(at: index)
    }

    /// The activity for a recording, removed so it is handed out once.
    mutating func take(recordingStartedAt: Date?) -> CallSpeakerActivity? {
        takeEntry(recordingStartedAt: recordingStartedAt)?.alignedActivity()
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
