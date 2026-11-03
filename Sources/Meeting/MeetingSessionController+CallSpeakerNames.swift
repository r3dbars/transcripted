// MeetingSessionController+CallSpeakerNames.swift
// Call-app speaker names: while a meeting records, `CallSpeakerActivityRecorder`
// reads who the call app shows as speaking. The finished activity waits in a
// small store, keyed by the recording's start date, until the pipeline asks
// for it (`TranscriptionTaskManager.callSpeakerActivityProvider`).
//
// Lifecycle: starts when state enters `.recording`, stops whenever state
// leaves it (stop, cancel, unexpected stop, termination all go through
// `transition`), and again from the capture-stopped sink as a backstop. A
// confirmed discard drops the activity.
//
// Privacy: names never reach logs or telemetry. The one log line per
// recording carries counts and status names only.

import ApplicationServices
import Foundation
import TranscriptedCore

/// Owns the recorder and the hand-off store for one controller.
@MainActor
final class MeetingCallSpeakerNames {
    let recorder: CallSpeakerActivityRecorder
    private var store = CallSpeakerActivityStore()
    /// Read again at hand-out, not only while recording.
    private let isEnabled: @MainActor () -> Bool

    init(
        recorder: CallSpeakerActivityRecorder? = nil,
        isEnabled: @escaping @MainActor () -> Bool = { CallSpeakerNamesPreferences.isEnabled() }
    ) {
        self.isEnabled = isEnabled
        self.recorder = recorder ?? CallSpeakerActivityRecorder(environment: .init(
            isEnabled: { CallSpeakerNamesPreferences.isEnabled() },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            reader: CallSpeakerAXTreeReader(),
            clock: .live
        ))
    }

    func recordingStarted(at recordingStartedAt: Date) {
        store.drop(recordingStartedAt: recordingStartedAt)
        recorder.start(recordingStartedAt: recordingStartedAt)
    }

    /// Stops the recorder (if running) and keeps what it saw for the pipeline.
    func recordingEnded() {
        guard recorder.isRunning, let key = recorder.recordingStartedAt else { return }
        let activity = recorder.stop()
        Self.logSummary(recorder.lastSummary, kept: activity != nil)
        if let activity {
            store.put(activity, recordingStartedAt: key)
        }
    }

    func discard(recordingStartedAt: Date?) {
        if recorder.isRunning, recorder.recordingStartedAt == recordingStartedAt {
            _ = recorder.stop()
        }
        store.drop(recordingStartedAt: recordingStartedAt)
    }

    /// Nil when the setting is off by the time the pipeline asks.
    func take(recordingDate: Date?) -> CallSpeakerActivity? {
        store.take(recordingStartedAt: recordingDate, enabled: isEnabled())
    }

    private static func logSummary(_ summary: CallSpeakerRecorderSummary?, kept: Bool) {
        guard let summary else { return }
        var context: [String: String] = [
            "polls": "\(summary.polls)",
            "gated_checks": "\(summary.gatedChecks)",
            "intervals": "\(summary.intervalCount)",
            "roster_count": "\(summary.rosterCount)",
            "saw_indicator": summary.sawSpeakingIndicator ? "true" : "false",
            "kept": kept ? "true" : "false",
        ]
        for (status, count) in summary.statusCounts {
            context["status_\(status.rawValue)"] = "\(count)"
        }
        AppLogger.pipeline.info("Call app activity finished", context)
    }
}

@available(macOS 14.0, *)
extension MeetingSessionController {
    /// Hands the pipeline each recording's call-app activity once.
    func wireCallSpeakerNames() {
        let names = callSpeakerNames
        taskManager.callSpeakerActivityProvider = { [weak names] recordingDate in
            await names?.take(recordingDate: recordingDate)
        }
    }

    /// Called from `transition` before `state` changes. Also starts the live
    /// transcript capture on entering `.recording`, as before.
    func recordingStateHooks(from oldState: State, to newState: State) {
        if case .recording = newState {
            beginLiveTranscriptCaptureIfNeeded()
            if oldState != .recording, let startedAt = activeRecordingStartedAt {
                callSpeakerNames.recordingStarted(at: startedAt)
            }
        } else if case .recording = oldState {
            callSpeakerNames.recordingEnded()
        }
    }
}
