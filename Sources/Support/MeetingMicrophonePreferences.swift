import Foundation

/// Read at the next meeting start. Existing installs keep Bluetooth isolation
/// unless the user explicitly chooses to record the macOS input, e.g. AirPods.
enum MeetingMicrophonePreferences {
    private static let systemInputKey = "meeting-use-system-input"

    static func usesSystemInput(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: systemInputKey)
    }

    static func setUsesSystemInput(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: systemInputKey)
        NotificationCenter.default.post(name: .meetingMicrophonePreferenceChanged, object: nil)
    }
}

extension Notification.Name {
    static let meetingMicrophonePreferenceChanged = Notification.Name("meetingMicrophonePreferenceChanged")
}
