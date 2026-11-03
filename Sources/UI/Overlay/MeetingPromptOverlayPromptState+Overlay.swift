import Foundation

@available(macOS 14.0, *)
extension MeetingPromptOverlayPromptState {
    init(_ state: MeetingOverlayController.OverlayState) {
        switch state {
        case .idle:
            self = .idle
        case .prompt:
            self = .prompt
        case .preparing:
            self = .preparing
        case .recording:
            self = .recording
        case .transcribing:
            self = .transcribing
        case .saved:
            self = .saved
        case .error:
            self = .error
        }
    }
}
