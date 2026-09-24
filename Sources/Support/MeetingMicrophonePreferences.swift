import Foundation

/// Read at the next meeting start. Existing installs keep Bluetooth isolation
/// unless the user explicitly chooses to record the macOS input, e.g. AirPods.
enum MeetingMicrophonePreferences {
    private static let systemInputKey = "meeting-use-system-input"

    static func usesSystemInput(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: systemInputKey)
    }

    /// Whether the next meeting records the macOS input as-is. With the
    /// pinned Mac-mic recorder on, a Bluetooth headset input is skipped
    /// whatever this setting says: recording it is what flips AirPods into
    /// call mode and garbles their audio, the one thing that recorder exists
    /// to stop. Dictation already works this way. Only a headset differs:
    /// automatic selection keeps every other macOS input anyway, and still
    /// records the headset when no other mic is available.
    static func recordsMacOSInput(
        pinnedRecorderOn: Bool,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        usesSystemInput(userDefaults: userDefaults) && !pinnedRecorderOn
    }

    static func setUsesSystemInput(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: systemInputKey)
        NotificationCenter.default.post(name: .meetingMicrophonePreferenceChanged, object: nil)
    }
}

extension Notification.Name {
    static let meetingMicrophonePreferenceChanged = Notification.Name("meetingMicrophonePreferenceChanged")
}
