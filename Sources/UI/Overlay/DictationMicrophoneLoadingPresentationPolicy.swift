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
        startAttempts: Int,
        switchedMic: DictationHeadsetMicChoice? = nil
    ) -> Copy {
        // The first mic on a headset route stalled and dictation moved to
        // the other one. Say so plainly; it keeps going on its own.
        switch switchedMic {
        case .some(.macMic):
            return Copy(
                title: "Using your Mac's mic",
                detail: "Your Bluetooth mic isn't ready yet.",
                status: nil
            )
        case .some(.headsetMic):
            return Copy(
                title: "Using your Bluetooth mic",
                detail: "Your Mac's mic isn't ready.",
                status: nil
            )
        case .none:
            break
        }
        let shouldShowSwitching = (isRecovering || !inputFormatReady) && elapsed >= switchingCopyDelay
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
