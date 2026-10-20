// lint-fixture-path: Sources/Meeting/CallMicWatcher.swift
import CoreAudio

// Comments may name kAudioHardwarePropertyDefaultInputDevice and setDefaultInputDeviceID(_:).
final class CallMicWatcher {
    let note = "kAudioHardwarePropertyDefaultInputDevice"

    func currentInput() throws -> AudioDeviceID {
        try AudioDeviceID.readDefaultInputDevice()
    }

    func start() {
        DefaultInputDeviceMonitor.shared.subscribe { _ in }
    }
}
