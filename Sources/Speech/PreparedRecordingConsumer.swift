// PreparedRecordingConsumer.swift
// Stop resamples the take once for its persistence snapshot; inference then
// consumes that prepared snapshot instead of resampling again. The snapshot
// carries the claim it was taken under. A Stop that finishes late, after a
// newer recording began, must not clear that newer recording's samples, so
// the claim is checked before the timeline is cleared.

import Foundation

/// The recording a prepared snapshot claims, and the native timeline it
/// clears once consumed.
@MainActor
protocol PreparedRecordingTimeline: AnyObject {
    var recordingIdentity: UUID { get }
    var recordedSamplesRevision: UInt64 { get }
    func clearRecoveredRecordingTimeline(keepingCapacity: Bool)
}

@MainActor
enum PreparedRecordingConsumer {
    /// Clears the timeline and returns true only when `claim` still names
    /// the timeline's current recording. A stale or cancelled claim leaves
    /// the timeline untouched and returns false.
    static func consume<Timeline: PreparedRecordingTimeline>(
        claim: ParakeetRecordedSamplesClaim,
        cancelled: Bool,
        timeline: Timeline
    ) -> Bool {
        guard claim.isCurrent(
            recordingIdentity: timeline.recordingIdentity,
            revision: timeline.recordedSamplesRevision,
            cancelled: cancelled
        ) else { return false }
        timeline.clearRecoveredRecordingTimeline(keepingCapacity: true)
        return true
    }
}
