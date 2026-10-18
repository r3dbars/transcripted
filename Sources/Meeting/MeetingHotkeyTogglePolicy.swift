import Foundation

/// What ⌥M does for the current meeting session. An auto-start that is
/// still loading must not be stopped (or double-started) by the hotkey.
enum MeetingHotkeyTogglePolicy {
    enum Action: Equatable {
        case start
        case stop
        case ignore
    }

    static func action(
        for state: MeetingSessionState,
        startCallInFlight: Bool
    ) -> Action {
        if startCallInFlight { return .ignore }
        switch state {
        case .idle, .ready, .transcribing, .error:
            return .start
        case .loadingModels, .startingRecording, .stoppingRecording:
            return .ignore
        case .recording:
            return .stop
        }
    }
}
