import Foundation

/// Pure start-path decisions for a meeting mic that is Bluetooth and not ready.
///
/// The capture engine still builds the graph and waits for the first frame.
/// These rules only say when to settle, retry a device lookup, or keep a
/// meeting that already has system audio instead of failing the outer start
/// deadline. They do not change stop ordering.
public enum MeetingStartMicFallbackPolicy {
    /// How long CoreAudio is given to finish a Bluetooth route switch before
    /// a second device lookup or the first bind. Tests pin the decision to
    /// wait, not this duration.
    public static let deviceLookupRetryDelay: TimeInterval = 0.3

    public static func isBluetoothInput(transportRawValue: String) -> Bool {
        transportRawValue == MeetingAudioTransport.bluetooth.rawValue
            || transportRawValue == MeetingAudioTransport.bluetoothLE.rawValue
    }

    public static func isBluetoothDeviceClass(_ deviceClass: String) -> Bool {
        deviceClass == "bluetooth"
    }

    /// Retry the built-in/USB fallback lookup once when the first pass found
    /// nothing. A Bluetooth route switch can list the Mac's mic with zero
    /// channels for a moment, which the device enumerator then drops.
    public static func shouldRetryDeviceLookup(foundFallback: Bool) -> Bool {
        !foundFallback
    }

    /// Wait once before the first bind when the macOS input or the selected
    /// meeting mic is Bluetooth. The default input can still be a headset
    /// even after automatic mode picks the built-in mic.
    public static func shouldSettleBeforeFirstBind(
        defaultInputIsBluetooth: Bool,
        selectedInputIsBluetooth: Bool
    ) -> Bool {
        defaultInputIsBluetooth || selectedInputIsBluetooth
    }

    /// The outer start deadline fired, but capture is already running with
    /// system audio and a Bluetooth mic that has not delivered a frame yet.
    /// Keep the meeting and let the existing mic watchdog keep trying,
    /// instead of tearing down call audio.
    public static func shouldAdmitSystemAudioFirst(
        isRecording: Bool,
        micStreaming: Bool,
        systemStreaming: Bool,
        selectedInputIsBluetooth: Bool,
        requiresSystemAudio: Bool
    ) -> Bool {
        isRecording
            && requiresSystemAudio
            && systemStreaming
            && !micStreaming
            && selectedInputIsBluetooth
    }
}

extension Audio {
    /// Peek the start pick without binding a graph. True when CoreAudio
    /// should be given a moment before the first `inputNode` touch, because
    /// a Bluetooth default input is mid-switch or is the mic this recording
    /// will use. A fresh engine still binds the macOS default input first;
    /// with AirPods as that default, that flip into call mode is the known
    /// trap. The settle happens in the meeting bridge, before `start()`, so
    /// this does not sleep inside a CoreAudio callback or the graph lock.
    public func shouldSettleMeetingInputBeforeStart() -> Bool {
        let peeked = try? MeetingInputDeviceLookup.preferredInputSelection(
            mode: meetingInputDeviceSelectionMode,
            preferredInputUID: meetingPreferredInputDeviceUID
        )
        guard let peeked else { return false }
        return MeetingStartMicFallbackPolicy.shouldSettleBeforeFirstBind(
            defaultInputIsBluetooth: MeetingStartMicFallbackPolicy.isBluetoothInput(
                transportRawValue: peeked.defaultInput.transport.rawValue
            ),
            selectedInputIsBluetooth: MeetingStartMicFallbackPolicy.isBluetoothInput(
                transportRawValue: peeked.selectedInput.transport.rawValue
            )
        )
    }
}
