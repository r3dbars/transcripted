// ParakeetInterruptionTerminal.swift
// The one place a dictation recording is marked interrupted. It drops the
// restart intent first and only then publishes, so a subscriber that reacts
// to the interruption never sees a recovery still planning to restart
// capture. It can't touch the captured audio: the retained take stays for an
// explicit recovery action.

import Foundation

/// The restart-intent flags a terminal interruption clears.
@MainActor
protocol ParakeetInterruptionTerminalState: AnyObject {
    var preservingRecordingAcrossRecovery: Bool { get set }
    var configChangeWasRecording: Bool { get set }
}

@MainActor
enum ParakeetInterruptionTerminal {
    /// Clears every restart flag, then calls `publish` (which sets
    /// `recordingInterrupted = true` and notifies its subscriber).
    static func apply<State: ParakeetInterruptionTerminalState>(
        state: State,
        publish: () -> Void
    ) {
        state.preservingRecordingAcrossRecovery = false
        state.configChangeWasRecording = false
        publish()
    }
}
