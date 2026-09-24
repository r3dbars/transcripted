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
                message: Self.infoMessage(dictationFollows: PinnedMicrophoneCapturePreferences.isEnabled())
            ),
            automationIdentifier: "transcripted.settings.meeting-system-microphone"
        )
    }

    /// The pinned Mac-mic recorder makes dictation follow this choice too,
    /// so say so while it is on.
    static func infoMessage(dictationFollows: Bool) -> String {
        let base = "Turn on to record the microphone selected in macOS Sound settings, including AirPods. Off prefers a built-in microphone during Bluetooth calls to avoid conflicts with your call app. Applies to the next recording. If your call loses your voice, turn this off or select a USB or built-in input."
        guard dictationFollows else { return base }
        return base + " Dictation uses the same choice, so with this off your AirPods keep playing clean audio while you dictate."
    }
}
