// MeetingCallAudioAsk.swift
// Foundation-pure rule for the Notch island's "can't hear the other side"
// ask. The session raises it from the start's own outcome
// (`MeetingSystemAudioAccessFlow.Outcome.recordMicOnlyAskingWhileRecording`),
// so it covers every way a start lands there, including a first-time macOS
// Don't Allow. It belongs to that one start attempt: a start that ends
// without recording drops it, and so does the recording ending, so the next
// meeting never shows a stale ask. One ask per meeting.

import Foundation

struct MeetingCallAudioAsk: Equatable {
    /// The island should ask about call audio now.
    private(set) var isAsking = false
    /// A start is between its first check and its result. State changes in
    /// that window (models loading, the permission preamble) don't end it.
    private var startInFlight = false

    /// A new start began. Any earlier ask is gone.
    mutating func startAttemptBegan() {
        isAsking = false
        startInFlight = true
    }

    /// The start decided how to handle system audio. Only a mic-only start
    /// that asks while recording raises the ask.
    mutating func accessResolved(_ outcome: MeetingSystemAudioAccessFlow.Outcome) {
        guard startInFlight else { return }
        isAsking = outcome == .recordMicOnlyAskingWhileRecording
    }

    /// The start returned. Without a recording there is nothing to ask about.
    mutating func startAttemptEnded(recording: Bool) {
        startInFlight = false
        if !recording { isAsking = false }
    }

    /// The meeting state moved. Once no start is in flight, leaving the live
    /// phases (starting, recording) ends the ask with the meeting.
    mutating func meetingStateChanged(isStartingOrRecording: Bool) {
        guard !startInFlight, !isStartingOrRecording else { return }
        isAsking = false
    }

    /// The person answered or dismissed it on the island.
    mutating func dismissed() {
        isAsking = false
    }
}
