@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import TranscriptedCore

struct RecordedSpeechSamples {
    let nativeSampleCount: Int
    let samples16k: [Float]
    let claim: ParakeetRecordedSamplesClaim
}

struct ParakeetAudioInputSnapshot {
    let outputFormat: ParakeetAudioFormatSummary
    let hwFormat: ParakeetAudioFormatSummary
    let selection: DictationInputDeviceSelection?
    let selectionApplication: ParakeetInputDeviceApplication?
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

    @discardableResult
    func retire(_ engine: AVAudioEngine, reason: String) -> Bool {
        let accepted = lock.withLock {
            guard engines.count < ParakeetAudioEngineRetirementPolicy.maximumRetainedEngineCount else {
                return false
            }
            engines.append(engine)
            return true
        }
        guard accepted else { return false }

        let delay = ParakeetAudioEngineRetirementPolicy.deferredReleaseDelayNanoseconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self, engine] in
            guard let self else { return }
            self.lock.withLock {
                guard let index = self.engines.firstIndex(where: { $0 === engine }) else { return }
                self.engines.remove(at: index)
            }
        }
        return true
    }
}

/// The live `AVAudioEngine` behind `ParakeetNativeInputGraphTeardown`. It
/// finds the input node only among nodes the engine already has; reading
/// `AVAudioEngine.inputNode` here would create one on an idle engine and bind
/// the macOS default input.
struct LiveParakeetInputGraph: ParakeetNativeInputGraph {
    let engine: AVAudioEngine

    var isRunning: Bool { engine.isRunning }

    var existingInputNode: AVAudioInputNode? {
        engine.attachedNodes.compactMap { $0 as? AVAudioInputNode }.first
    }

    func stop() {
        engine.stop()
    }

    func waitForStoppedInputCallbacks() {
        // Runs on the graph queue; blocks that queue briefly, never the
        // CoreAudio render thread.
        Thread.sleep(forTimeInterval: AudioInputTapTeardownPolicy.inputCallbackDrainDelay)
    }

    func removeTap(from node: AVAudioInputNode) {
        node.removeTap(onBus: 0)
    }

    func releaseVoiceProcessing(on node: AVAudioInputNode) -> Bool {
        ParakeetEngine.applyDictationVoiceProcessingPreference(false, to: node)
    }

    func isVoiceProcessingEnabled(on node: AVAudioInputNode) -> Bool {
        node.isVoiceProcessingEnabled
    }
}
