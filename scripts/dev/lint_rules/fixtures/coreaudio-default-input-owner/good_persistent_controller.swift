// lint-fixture-path: Sources/Speech/PersistentDictationInputController+Live.swift
import CoreAudio

extension PersistentDictationInputController {
    static func live() -> PersistentDictationInputController {
        PersistentDictationInputController(
            setDefaultInput: { try DefaultInputDeviceMonitor.shared.setDefaultInputDevice($0) }
        )
    }
}
