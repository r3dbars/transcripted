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

    /// Read at each dictation and meeting start. The chosen mic's UID is the
    /// one Faster Bluetooth dictation already saves
    /// (`DictationPersistentInputPreferences.preferredDeviceUID()`), so a mic
    /// picked there carries over as the choice until the user picks again.
    static func choice(userDefaults: UserDefaults = .standard) -> MicrophoneChoice {
        switch userDefaults.string(forKey: choiceKey) {
        case "automatic":
            return .automatic
        case "macos":
            return .macOSInput
        default:
            // "device", or never chosen.
            guard let uid = DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: userDefaults) else {
                return .automatic
            }
            return .device(uid: uid)
        }
    }

    static func setChoice(_ choice: MicrophoneChoice, userDefaults: UserDefaults = .standard) {
        switch choice {
        case .automatic:
            userDefaults.set("automatic", forKey: choiceKey)
        case let .device(uid):
            userDefaults.set("device", forKey: choiceKey)
            DictationPersistentInputPreferences.setPreferredDeviceUID(uid, userDefaults: userDefaults)
        case .macOSInput:
            userDefaults.set("macos", forKey: choiceKey)
        }
        NotificationCenter.default.post(name: .microphoneChoiceChanged, object: nil)
    }
}

extension Notification.Name {
    static let microphoneChoiceChanged = Notification.Name("microphoneChoiceChanged")
}
