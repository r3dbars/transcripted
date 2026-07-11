import Foundation

extension Notification.Name {
    static let dictationPersistentInputPreferenceChanged = Notification.Name(
        "dictationPersistentInputPreferenceChanged"
    )
}

enum DictationPersistentInputPreferences {
    private static let enabledKey = "dictationKeepRecommendedMicrophoneActive"
    private static let preferredDeviceUIDKey = "dictationPreferredInputDeviceUID"
    private static let recoverySelectedUIDKey = "dictationPersistentInputRecoverySelectedUID"
    private static let recoveryPreviousUIDKey = "dictationPersistentInputRecoveryPreviousUID"
    private static let temporaryRecoverySelectedUIDKey = "dictationTemporaryInputRecoverySelectedUID"
    private static let temporaryRecoveryPreviousUIDKey = "dictationTemporaryInputRecoveryPreviousUID"

    struct RecoveryMarker: Equatable {
        let selectedUID: String
        let previousUID: String
    }

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(
            name: .dictationPersistentInputPreferenceChanged,
            object: nil
        )
    }

    static func preferredDeviceUID(userDefaults: UserDefaults = .standard) -> String? {
        guard let value = userDefaults.string(forKey: preferredDeviceUIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func setPreferredDeviceUID(_ uid: String?, userDefaults: UserDefaults = .standard) {
        if let uid, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userDefaults.set(uid, forKey: preferredDeviceUIDKey)
        } else {
            userDefaults.removeObject(forKey: preferredDeviceUIDKey)
        }
        NotificationCenter.default.post(
            name: .dictationPersistentInputPreferenceChanged,
            object: nil
        )
    }

    static func recoveryMarker(userDefaults: UserDefaults = .standard) -> RecoveryMarker? {
        guard let selectedUID = userDefaults.string(forKey: recoverySelectedUIDKey),
              !selectedUID.isEmpty,
              let previousUID = userDefaults.string(forKey: recoveryPreviousUIDKey),
              !previousUID.isEmpty else {
            return nil
        }
        return RecoveryMarker(selectedUID: selectedUID, previousUID: previousUID)
    }

    static func setRecoveryMarker(
        _ marker: RecoveryMarker?,
        userDefaults: UserDefaults = .standard
    ) {
        if let marker {
            userDefaults.set(marker.selectedUID, forKey: recoverySelectedUIDKey)
            userDefaults.set(marker.previousUID, forKey: recoveryPreviousUIDKey)
        } else {
            userDefaults.removeObject(forKey: recoverySelectedUIDKey)
            userDefaults.removeObject(forKey: recoveryPreviousUIDKey)
        }
        userDefaults.synchronize()
    }

    static func temporaryRecoveryMarker(userDefaults: UserDefaults = .standard) -> RecoveryMarker? {
        guard let selectedUID = userDefaults.string(forKey: temporaryRecoverySelectedUIDKey),
              !selectedUID.isEmpty,
              let previousUID = userDefaults.string(forKey: temporaryRecoveryPreviousUIDKey),
              !previousUID.isEmpty else {
            return nil
        }
        return RecoveryMarker(selectedUID: selectedUID, previousUID: previousUID)
    }

    static func setTemporaryRecoveryMarker(
        _ marker: RecoveryMarker?,
        userDefaults: UserDefaults = .standard
    ) {
        if let marker {
            userDefaults.set(marker.selectedUID, forKey: temporaryRecoverySelectedUIDKey)
            userDefaults.set(marker.previousUID, forKey: temporaryRecoveryPreviousUIDKey)
        } else {
            userDefaults.removeObject(forKey: temporaryRecoverySelectedUIDKey)
            userDefaults.removeObject(forKey: temporaryRecoveryPreviousUIDKey)
        }
        userDefaults.synchronize()
    }
}

enum DictationPersistentInputRecoveryAction: Equatable {
    case none
    case adopt
    case restore
    case preserve
    case clear
}

enum DictationPersistentInputRecoveryPolicy {
    static func action(
        preferenceEnabled: Bool,
        currentUID: String?,
        marker: DictationPersistentInputPreferences.RecoveryMarker?,
        availableUIDs: Set<String>
    ) -> DictationPersistentInputRecoveryAction {
        guard let marker else { return .none }
        guard currentUID == marker.selectedUID else {
            return .clear
        }
        guard availableUIDs.contains(marker.previousUID) else { return .preserve }
        return preferenceEnabled ? .adopt : .restore
    }
}
