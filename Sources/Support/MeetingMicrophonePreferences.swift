import Foundation

/// Read at the next meeting start. Existing installs keep Bluetooth isolation
/// unless the user explicitly chooses to record the macOS input, e.g. AirPods.
enum MeetingMicrophonePreferences {
    private static let systemInputKey = "meeting-use-system-input"

    static func usesSystemInput(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: systemInputKey)
    }

    /// Whether the next meeting records the macOS input as-is. With the
    /// pinned Mac-mic recorder on, this setting is hidden and the one
    /// Settings "Microphone" choice decides instead: only "Same as macOS
    /// Sound settings" keeps a Bluetooth headset input. Recording one is what
    /// flips AirPods into call mode and garbles their audio, the thing that
    /// recorder exists to stop. Automatic selection keeps every other macOS
    /// input anyway, and still records the headset when no other mic is
    /// available.
    static func recordsMacOSInput(
        pinnedRecorderOn: Bool,
        microphoneChoice: MicrophoneChoice,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard pinnedRecorderOn else { return usesSystemInput(userDefaults: userDefaults) }
        return microphoneChoice == .macOSInput
    }

    static func setUsesSystemInput(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: systemInputKey)
        NotificationCenter.default.post(name: .meetingMicrophonePreferenceChanged, object: nil)
    }
}

extension Notification.Name {
    static let meetingMicrophonePreferenceChanged = Notification.Name("meetingMicrophonePreferenceChanged")
}
