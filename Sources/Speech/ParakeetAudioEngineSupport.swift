@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import TranscriptedCore

func unregisterDefaultInputDeviceListener(_ listener: AudioObjectPropertyListenerBlock?) {
    guard let listener else { return }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        .main,
        listener
    )

    if status != noErr {
        AppLogger.audioMic.warning("PARAKEET | failed to remove default input listener (\(status))")
    }
}

struct RecordedSpeechSamples {
    let nativeSampleCount: Int
    let samples16k: [Float]
}

struct ParakeetAudioInputSnapshot {
    let outputFormat: ParakeetAudioFormatSummary
    let hwFormat: ParakeetAudioFormatSummary
    let selection: DictationInputDeviceSelection?
    let selectionApplication: ParakeetInputDeviceApplication?
    let engineWasRunning: Bool
    let stageTimings: [String: Int]
}

struct ParakeetAudioStartSnapshot {
    let engineWasRunning: Bool
    let stageTimings: [String: Int]
}

struct ParakeetInputDeviceApplication {
    let selection: DictationInputDeviceSelection
    let didApplyOverride: Bool
    let reportKey: String?
    let errorDescription: String?
}

final class ParakeetRetiredAudioEngineStore {
    static let shared = ParakeetRetiredAudioEngineStore()

    private let lock = NSLock()
    private var engines: [AVAudioEngine] = []

    func retire(_ engine: AVAudioEngine, reason: String) {
        lock.withLock {
            engines.append(engine)
        }

        let delay = ParakeetAudioEngineRetirementPolicy.deferredReleaseDelayNanoseconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self, engine] in
            guard let self else { return }
            self.lock.withLock {
                guard let index = self.engines.firstIndex(where: { $0 === engine }) else { return }
                self.engines.remove(at: index)
            }
        }
    }
}
