import Foundation

/// The one Settings "Microphone" choice, for dictation and meetings alike.
/// It only applies while the Mac mic recorder
/// (`PinnedMicrophoneCapturePreferences`) is on. With the recorder off, the
/// older controls still decide: Faster Bluetooth dictation with its mic
/// picker, and meetings' "Use Mac-selected microphone".
enum MicrophoneChoice: Hashable {
    /// The macOS input, except a Bluetooth headset such as AirPods is skipped
    /// for the Mac's own mic (or a wired/USB mic on a Mac without one), so the
    /// headset never drops into call mode.
    case automatic
    /// This mic, by Core Audio UID, whatever the macOS input is. While it is
    /// unplugged, recording falls back to `automatic`.
    case device(uid: String)
    /// Whatever macOS Sound settings has selected, AirPods included. Recording
    /// a Bluetooth headset mic puts it in call mode.
    case macOSInput

    var deviceUID: String? {
        if case let .device(uid) = self { return uid }
        return nil
    }

    /// Bounded value for analytics. Never the device UID.
    var analyticsValue: String {
        switch self {
        case .automatic: return "automatic"
        case .device: return "device"
        case .macOSInput: return "macos_input"
        }
    }
}

enum MicrophoneChoicePreferences {
    static let choiceKey = "microphone-choice"

    /// Read at each dictation and meeting start. The picked mic's UID is the
    /// one Faster Bluetooth dictation already saves
    /// (`DictationPersistentInputPreferences.preferredDeviceUID()`).
    static func choice(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MicrophoneChoice {
        switch userDefaults.string(forKey: choiceKey) {
        case "automatic":
            return .automatic
        case "macos":
            return .macOSInput
        case "device":
            guard let uid = DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: userDefaults) else {
                return .automatic
            }
            return .device(uid: uid)
        default:
            let carriedOver = carriedOverChoice(userDefaults: userDefaults)
            // Settled once, the first time the choice is read with the
            // recorder on, so a later change to the old toggle can't move it.
            // The carried-over UID is already saved where `store` keeps it.
            if PinnedMicrophoneCapturePreferences.isEnabled(userDefaults: userDefaults, environment: environment) {
                userDefaults.set(storedValue(for: carriedOver), forKey: choiceKey)
            }
            return carriedOver
        }
    }

    static func setChoice(_ choice: MicrophoneChoice, userDefaults: UserDefaults = .standard) {
        store(choice, userDefaults: userDefaults)
    }

    /// A mic picked under Faster Bluetooth dictation carries over only while
    /// that toggle is on. Once it's off the old pick did nothing, so it must
    /// not come back as a mic forced for dictation and meetings.
    private static func carriedOverChoice(userDefaults: UserDefaults) -> MicrophoneChoice {
        guard DictationPersistentInputPreferences.isStoredOn(userDefaults: userDefaults),
              let uid = DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: userDefaults) else {
            return .automatic
        }
        return .device(uid: uid)
    }

    private static func store(_ choice: MicrophoneChoice, userDefaults: UserDefaults) {
        userDefaults.set(storedValue(for: choice), forKey: choiceKey)
        if let uid = choice.deviceUID {
            DictationPersistentInputPreferences.setPreferredDeviceUID(uid, userDefaults: userDefaults)
        }
    }

    private static func storedValue(for choice: MicrophoneChoice) -> String {
        switch choice {
        case .automatic: return "automatic"
        case .device: return "device"
        case .macOSInput: return "macos"
        }
    }
}
