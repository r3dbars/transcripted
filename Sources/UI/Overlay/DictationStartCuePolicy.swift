import Foundation

/// When the dictation start click plays.
///
/// On a built-in or wired mic it plays the moment the key press is accepted,
/// so it answers the press instead of waiting ~100 ms for the mic to open.
/// Playing before the mic opens also keeps more of the click out of the take;
/// it used to play entirely after recording started.
///
/// Any other recorded input keeps the old timing, after recording starts.
/// Opening a Bluetooth headset's own mic flips it into call mode, which cuts
/// off a click already playing through it. Aggregate and virtual inputs can
/// wrap a headset, and an input not seen yet could be one. So does a mic
/// moved back to the slower engine start (`PinnedDictationSpeedPath`).
enum DictationStartCuePolicy {
    static func playsOnKeyPress(
        recordedInput: DictationAudioDevice?,
        speedPathIsOff: (DictationAudioDevice) -> Bool = { PinnedDictationSpeedPath.isTurnedOff(for: $0) }
    ) -> Bool {
        guard let recordedInput else { return false }
        switch DictationInputDeviceSelectionPolicy.deviceClass(for: recordedInput) {
        case "built_in", "external":
            return !speedPathIsOff(recordedInput)
        default:
            return false
        }
    }
}
