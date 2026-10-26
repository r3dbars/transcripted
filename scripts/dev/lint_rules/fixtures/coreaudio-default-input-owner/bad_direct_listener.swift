// lint-fixture-path: Sources/Meeting/CallMicWatcher.swift
import CoreAudio

final class CallMicWatcher {
    func start(queue: DispatchQueue) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in }
    }
}
