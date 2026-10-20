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
    fileprivate static var live: PersistentDictationInputSystem {
        PersistentDictationInputSystem(
            userDefaults: .standard,
            defaultInputMonitor: DefaultInputDeviceMonitor.shared,
            // Every Mac-wide input write goes through the shared monitor so
            // its echo is classified as a self-write for every subscriber.
            setDefaultInput: {
                try await DefaultInputDeviceMonitor.shared.setDefaultInputDevice($0, on: halWorkCoordinator)
            },
            // Runs on HALListenerRegistrationQueue through `registerListener`
            // below, never on main. Callbacks still arrive on main.
            addDeviceListListener: Self.addSystemDeviceListListener(handler:),
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
                try await halRead("persistent_input_selection") {
                    try CoreAudioInputDeviceLookup.preferredDictationInputSelection(
                        prefersBuiltInBluetoothInput: true
                    )
                }
            },
            availableInputs: {
                try await halRead("persistent_input_devices") { try CoreAudioInputDeviceLookup.availableInputDevices() }
            },
            currentDefaultInputID: {
                try await halRead("persistent_input_default") { try CoreAudioInputDeviceLookup.currentDefaultInputDeviceID() }
            },
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
            refreshDelay: { try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay) },
            // Same serial queue as DefaultInputDeviceMonitor's default-input
            // add, so the launch-time HAL client init happens off main.
            registerListener: { work, completion in
                HALListenerRegistrationQueue.run(work, then: completion)
            }
        )
    }

    /// This controller's own serial queue for HAL reads and its write, so a
    /// write never waits behind dictation's system-input work (the self-write
    /// echo window is 500 ms), and a stuck driver call trips the breaker.
    private static let halWorkCoordinator = ParakeetReplaceableSystemInputWorkCoordinator(
        label: "com.transcripted.persistent-input"
    )

    /// Runs one HAL read off main, timed. A timeout or open circuit throws.
    private static func halRead<T>(_ operation: String, _ read: @escaping () throws -> T) async throws -> T {
        try await halWorkCoordinator.run(
            operation: operation,
            timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout
        ) {
            Result { try read() }
        }.get()
    }

    /// Nonisolated on purpose: it runs on the registration queue.
    private static func addSystemDeviceListListener(
        handler: @escaping @MainActor () -> Void
    ) -> AudioObjectPropertyListenerBlock? {
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
    }

    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
