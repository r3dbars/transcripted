import CoreAudio
import Foundation

// The production wiring for `PersistentDictationInputController`. Kept out of
// the controller file so the fast test runner can compile the controller
// against fakes without CoreAudio's HAL, `DefaultInputDeviceMonitor`, or
// `EventReporter`.

extension PersistentDictationInputController {
    convenience init(
        isDictationActive: @escaping () -> Bool = { false },
        isMeetingCaptureActive: @escaping () -> Bool = { false }
    ) {
        self.init(
            isDictationActive: isDictationActive,
            isMeetingCaptureActive: isMeetingCaptureActive,
            system: .live
        )
    }
}

extension PersistentDictationInputSystem {
    @MainActor
    static var live: PersistentDictationInputSystem {
        PersistentDictationInputSystem(
            userDefaults: .standard,
            defaultInputMonitor: DefaultInputDeviceMonitor.shared,
            // Every Mac-wide input write goes through the shared monitor so
            // its echo is classified as a self-write for every subscriber.
            setDefaultInput: { try DefaultInputDeviceMonitor.shared.setDefaultInputDevice($0) },
            addDeviceListListener: { handler in
                var address = deviceListAddress
                let listener: AudioObjectPropertyListenerBlock = { _, _ in
                    Task { @MainActor in
                        handler()
                    }
                }
                let status = AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    DispatchQueue.main,
                    listener
                )
                return status == noErr ? listener : nil
            },
            removeDeviceListListener: { listener in
                var address = deviceListAddress
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    DispatchQueue.main,
                    listener
                )
            },
            recommendedSelection: {
                try CoreAudioInputDeviceLookup.preferredDictationInputSelection(
                    prefersBuiltInBluetoothInput: true
                )
            },
            availableInputs: { try CoreAudioInputDeviceLookup.availableInputDevices() },
            currentDefaultInputID: { try CoreAudioInputDeviceLookup.currentDefaultInputDeviceID() },
            hasExternalInputActivity: { try CoreAudioInputDeviceLookup.hasExternalInputActivity() },
            report: { report in
                EventReporter.shared.capture(
                    level: report.level == .warning ? .warning : .info,
                    engine: "parakeet",
                    event: report.event,
                    message: report.message,
                    context: report.context
                )
            },
            refreshDelay: { try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay) }
        )
    }

    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
