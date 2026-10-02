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

    /// Stop still works while the mic is engaging (it joins the pending
    /// start); once the audio is being saved there is nothing left to stop.
    var allowsStop: Bool {
        self != .saving
    }
}

/// What the menu's meeting button does for a given session state. Starting,
/// recording, and saving all mean Stop (steady-state `isRecording` would
/// double-start during the starting and saving windows), and a Stop while
/// the mic is still engaging joins the pending start.
enum MenuBarMeetingMenuAction: Equatable {
    case start
    case stop
    case stopJoiningPendingStart

    static func resolve(_ state: MeetingSessionState) -> MenuBarMeetingMenuAction {
        switch state {
        case .startingRecording:
            return .stopJoiningPendingStart
        case .recording, .stoppingRecording:
            return .stop
        case .idle, .loadingModels, .ready, .transcribing, .error:
            return .start
        }
    }

    var analyticsActionID: String {
        self == .start ? "start_meeting" : "stop_meeting"
    }
}
