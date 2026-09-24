import SwiftUI

struct MeetingMicrophoneSettingRow: View {
    @Binding var usesSystemInput: Bool

    var body: some View {
        GeneralToggleRow(
            title: "Use Mac-selected microphone",
            isOn: $usesSystemInput,
            help: usesSystemInput ? "Uses the input selected in Sound settings." : "Prefers a built-in mic for Bluetooth calls.",
            info: GeneralInfo(
                title: "Meeting microphone",
                message: Self.infoMessage(pinnedRecorderOn: PinnedMicrophoneCapturePreferences.isEnabled())
            ),
            automationIdentifier: "transcripted.settings.meeting-system-microphone"
        )
    }

    /// With the pinned Mac-mic recorder on, dictation skips a Bluetooth
    /// headset whatever this says, so tell people it doesn't follow along.
    static func infoMessage(pinnedRecorderOn: Bool) -> String {
        let base = "Turn on to record the microphone selected in macOS Sound settings, including AirPods. Off prefers a built-in microphone during Bluetooth calls to avoid conflicts with your call app. Applies to the next recording. If your call loses your voice, turn this off or select a USB or built-in input."
        guard pinnedRecorderOn else { return base }
        return base + " Dictation doesn't follow this setting. It always records your Mac's own mic (or a USB mic) instead of AirPods, so your AirPods keep playing clean audio while you dictate."
    }
}
