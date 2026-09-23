import SwiftUI

/// Read by meetings (`MeetingCaptureBridge`) and by dictation's first mic
/// choice on a Bluetooth headset route (`DictationHeadsetMicPolicy`).
struct MeetingMicrophoneSettingRow: View {
    @Binding var usesSystemInput: Bool

    var body: some View {
        GeneralToggleRow(
            title: "Use Mac-selected microphone",
            isOn: $usesSystemInput,
            help: usesSystemInput ? "Uses the input selected in Sound settings." : "Uses your Mac's mic when Bluetooth headphones are on.",
            info: GeneralInfo(
                title: "Microphone with Bluetooth headphones",
                message: "Applies to dictation and meetings. Off uses your Mac's built-in mic while AirPods or other Bluetooth headphones are connected, so what you're listening to keeps full sound quality and your call app keeps its mic. On records the microphone selected in macOS Sound settings, including AirPods. If the first mic doesn't start, dictation switches to the other one. Applies to the next recording."
            ),
            automationIdentifier: "transcripted.settings.meeting-system-microphone"
        )
    }
}
