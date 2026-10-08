import Foundation

/// Why dictation picked the input it did. Lives in Support so Speech can set it
/// and Observability can bound the analytics `reason` value by this enum.
enum DictationInputDeviceSelectionReason: String {
    case defaultIsSafe
    case preferredBuiltInForBluetoothHeadset
    case builtInFallbackSuppressedForRecoveryAttempt
    case noBuiltInFallbackAvailable
    case preferredUserChosenForBluetoothHeadset
    case preferredExternalForBluetoothHeadset
    /// A mic picked in Settings, recorded over a non-Bluetooth macOS input.
    case userChosenInput
}
