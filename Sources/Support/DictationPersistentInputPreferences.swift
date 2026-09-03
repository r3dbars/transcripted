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

enum DictationPersistentInputRuntimeAction: Equatable {
    case reconcile
    case preserveExternalSelection
}

/// Decides whether a default-input notification represents an external choice
/// that the persistent preference must preserve. Device removal remains a
/// topology recovery; a live device changed away from Transcripted's last
/// maintained target relinquishes ownership for the rest of the app session.
enum DictationPersistentInputRuntimePolicy {
    static func action<ID: Equatable>(
        preferenceEnabled: Bool,
        runtimeOwnershipRelinquished: Bool,
        defaultInputChanged: Bool,
        deviceListChanged: Bool,
        currentInputID: ID,
        desiredInputID: ID,
        lastMaintainedInputID: ID?,
        lastMaintainedInputIsAvailable: Bool
    ) -> DictationPersistentInputRuntimeAction {
        guard preferenceEnabled else { return .reconcile }
        guard !runtimeOwnershipRelinquished else { return .preserveExternalSelection }
        guard defaultInputChanged, currentInputID != desiredInputID else { return .reconcile }

        if let lastMaintainedInputID {
            guard lastMaintainedInputIsAvailable else { return .reconcile }
            if lastMaintainedInputID == desiredInputID {
                return .preserveExternalSelection
            }
        }

        return deviceListChanged ? .reconcile : .preserveExternalSelection
    }
}

enum DictationPersistentInputRefreshPolicy {
    static func shouldSchedule(
        preferenceChanged: Bool,
        preferenceEnabled: Bool,
        hasRecoveryMarker: Bool
    ) -> Bool {
        preferenceChanged
            || preferenceEnabled
            || hasRecoveryMarker
    }

    /// The live speech engine already owns its selected input while dictation
    /// is active. Changing the system-wide default at that point can stop an
    /// otherwise healthy graph, so persistent preference maintenance waits
    /// until the recording has finished.
    static func shouldDefer(isDictationActive: Bool) -> Bool {
        isDictationActive
    }
}
