// lint-fixture-path: Sources/Speech/DefaultInputDeviceMonitor.swift
import CoreAudio

final class DefaultInputDeviceMonitor {
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
        try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(deviceID)
    }

    func register() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = address
    }
}
