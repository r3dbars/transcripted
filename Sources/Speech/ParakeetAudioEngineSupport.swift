@preconcurrency import AVFoundation
import CoreAudio
import Foundation

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
        print("⚠️ PARAKEET | failed to remove default input listener (\(status))")
    }
}

// FluidAudio 0.7.9 no longer exposes the older streaming EOU manager used by
// this dormant live-display path. Keep a no-op shim so the disabled code path
// still compiles until we rewire live transcripts to the newer streaming API.
actor StreamingEouAsrManager {
    enum ChunkSize {
        case ms320
    }

    init(chunkSize: ChunkSize, eouDebounceMs: Int) {}

    func loadModels(modelDir: URL) async throws {}

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {}

    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {}

    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String { "" }

    func reset() async {}
}

enum ParakeetModelState {
    case notLoaded
    case downloading(progress: Double)
    case cached
    case loading
    case ready
    case failed(String)
}

extension ParakeetModelState {
    var diagnosticName: String {
        switch self {
        case .notLoaded: return "not_loaded"
        case .downloading: return "downloading"
        case .cached: return "cached"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
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
