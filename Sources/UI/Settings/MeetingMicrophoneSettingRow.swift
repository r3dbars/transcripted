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
                message: "Turn on to record the microphone selected in macOS Sound settings, including AirPods. Off prefers a built-in microphone during Bluetooth calls to avoid conflicts with your call app. Applies to the next recording. If your call loses your voice, turn this off or select a USB or built-in input."
            ),
            automationIdentifier: "transcripted.settings.meeting-system-microphone"
        )
    }
}
