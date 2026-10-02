import Foundation

/// Which microphone rows General settings shows. Foundation-pure so the
/// visibility rules can be tested without SwiftUI.
struct MicrophoneSettingsRows: Equatable {
    /// The one "Microphone" picker for dictation and meetings.
    var showsMicrophoneChoicePicker: Bool
    /// The "Faster Bluetooth dictation" toggle.
    var showsFasterBluetoothDictationToggle: Bool
    /// The older mic picker that goes with Faster Bluetooth dictation.
    var showsFasterBluetoothMicPicker: Bool
    /// Meetings' "Use Mac-selected microphone" toggle.
    var showsMeetingMacInputToggle: Bool
}

/// One entry in the "Microphone" picker menu, in display order.
enum MicrophoneChoicePickerOption: Equatable {
    case automatic
    /// A connected mic, by Core Audio UID.
    case device(uid: String, name: String)
    /// The saved pick while it is unplugged, so the menu isn't blank.
    case savedDeviceNotConnected(uid: String)
    case divider
    /// "Same as macOS Sound settings": records AirPods too, on purpose.
    case macOSInput

    /// The choice this entry selects. Nil for the divider.
    var choice: MicrophoneChoice? {
        switch self {
        case .automatic: return .automatic
        case let .device(uid, _): return .device(uid: uid)
        case let .savedDeviceNotConnected(uid): return .device(uid: uid)
        case .divider: return nil
        case .macOSInput: return .macOSInput
        }
    }
}

enum MicrophoneSettingsPolicy {
    /// With the Mac mic recorder on, the one Microphone picker replaces
    /// Faster Bluetooth dictation, its mic picker, and meetings' "Use
    /// Mac-selected microphone". Apple voice processing keeps dictation off
    /// the recorder, so those users keep the Faster Bluetooth dictation
    /// toggle, whose Mac-wide switch still keeps dictation off AirPods.
    /// With the recorder off, the older controls stay.
    static func rows(recorderOn: Bool, usesAppleVoiceProcessing: Bool) -> MicrophoneSettingsRows {
        guard recorderOn else {
            return MicrophoneSettingsRows(
                showsMicrophoneChoicePicker: false,
                showsFasterBluetoothDictationToggle: true,
                showsFasterBluetoothMicPicker: true,
                showsMeetingMacInputToggle: true
            )
        }
        return MicrophoneSettingsRows(
            showsMicrophoneChoicePicker: true,
            showsFasterBluetoothDictationToggle: usesAppleVoiceProcessing,
            showsFasterBluetoothMicPicker: false,
            showsMeetingMacInputToggle: false
        )
    }

    /// The Microphone picker's entries: Automatic, each connected mic that
    /// has a UID, the saved pick if it is unplugged, then "Same as macOS
    /// Sound settings" so the AirPods mic can still be recorded on purpose.
    static func pickerOptions(
        candidates: [(uid: String?, name: String)],
        selection: MicrophoneChoice
    ) -> [MicrophoneChoicePickerOption] {
        var options: [MicrophoneChoicePickerOption] = [.automatic]
        for candidate in candidates {
            if let uid = candidate.uid {
                options.append(.device(uid: uid, name: candidate.name))
            }
        }
        if let savedUID = selection.deviceUID,
           !candidates.contains(where: { $0.uid == savedUID }) {
            options.append(.savedDeviceNotConnected(uid: savedUID))
        }
        options.append(.divider)
        options.append(.macOSInput)
        return options
    }
}
