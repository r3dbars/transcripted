// MenuBarMeetingCapturePhase.swift
// Foundation-pure name for where a meeting capture is, so the menu bar says
// "Starting…" and "Saving…" instead of a red "Recording" while the mic is
// still engaging or the audio is being handed off.

import Foundation

enum MenuBarMeetingCapturePhase: Equatable {
    case starting
    case recording
    case saving

    /// Nil when no capture is in flight (the same states
    /// `isCaptureSessionActive` treats as inactive).
    static func resolve(_ state: MeetingSessionState) -> MenuBarMeetingCapturePhase? {
        switch state {
        case .startingRecording:
            return .starting
        case .recording:
            return .recording
        case .stoppingRecording:
            return .saving
        case .idle, .loadingModels, .ready, .transcribing, .error:
            return nil
        }
    }

    var headerText: String {
        switch self {
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .saving: return "Saving…"
        }
    }

    /// The status-item right-click menu's meeting item.
    var quickMenuTitle: String {
        switch self {
        case .starting, .recording: return "Stop Meeting"
        case .saving: return "Saving Meeting…"
        }
    }

    /// Stop still works while the mic is engaging (it joins the pending
    /// start); once the audio is being saved there is nothing left to stop.
    var allowsStop: Bool {
        self != .saving
    }
}
