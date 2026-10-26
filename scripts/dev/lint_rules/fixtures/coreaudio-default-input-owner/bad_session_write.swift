// lint-fixture-path: Sources/Speech/ParakeetSystemInputCoordination.swift
import CoreAudio

enum DictationRouteOverride {
    static func pinBuiltInForThisTake(_ input: AudioDeviceID) throws {
        try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(input)
    }

    static func restore(_ previous: AudioDeviceID) throws {
        try DefaultInputDeviceMonitor.shared.setDefaultInputDevice(previous)
    }
}
