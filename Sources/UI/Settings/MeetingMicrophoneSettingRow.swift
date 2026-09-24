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

    /// With the pinned Mac-mic recorder on, meetings and dictation skip a
    /// Bluetooth headset whatever this says, so say so instead of promising
    /// the AirPods mic.
    static func infoMessage(pinnedRecorderOn: Bool) -> String {
        guard pinnedRecorderOn else {
            return "Turn on to record the microphone selected in macOS Sound settings, including AirPods. Off prefers a built-in microphone during Bluetooth calls to avoid conflicts with your call app. Applies to the next recording. If your call loses your voice, turn this off or select a USB or built-in input."
        }
        return "Turn on to record the microphone selected in macOS Sound settings. AirPods and other Bluetooth headsets are the exception: meetings and dictation record your Mac's own mic (or a USB mic) instead whenever one is available, so your AirPods keep playing clean audio. Applies to the next recording."
    }
}
