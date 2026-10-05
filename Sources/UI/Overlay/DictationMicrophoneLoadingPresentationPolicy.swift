import Foundation

struct DictationMicrophoneLoadingPresentationPolicy {
    struct Copy: Equatable {
        let title: String
        let detail: String
        let status: String?
    }

    static let switchingCopyDelay: TimeInterval = 0.6

    static func copy(
        elapsed: TimeInterval,
        deviceName: String,
        isRecovering: Bool,
        inputFormatReady: Bool,
        startAttempts: Int
    ) -> Copy {
        // Only a live route recovery is a switch. Readiness deferred by idle
        // route chatter (AirPods do this after nearly every take) is a normal
        // start, so it keeps "Starting microphone" however long it takes.
        let shouldShowSwitching = isRecovering && elapsed >= switchingCopyDelay
        let title = shouldShowSwitching ? "Switching microphone" : "Starting microphone"
        let detail = shouldShowSwitching
            ? "Connecting to the new audio device."
            : "Opening the selected audio input."
        let status: String?
        if startAttempts > 1 && elapsed >= switchingCopyDelay {
            status = "Retrying \(deviceName)"
        } else if elapsed > 1.5 {
            status = "Still connecting to \(deviceName)\u{2026}"
        } else {
            status = nil
        }

        return Copy(title: title, detail: detail, status: status)
    }
}
