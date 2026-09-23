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

struct ParakeetAudioStartSnapshot {
    let engineWasRunning: Bool
    let stageTimings: [String: Int]
}

struct ParakeetInputDeviceApplication {
    let selection: DictationInputDeviceSelection
    let didApplyOverride: Bool
    let reportKey: String?
    let errorDescription: String?
    /// Log-safe failure category. `errorDescription` is redacted from local
    /// logs (its key contains "error"), which hid why a cold bind failed.
    var failureKind: String? = nil
    var statusCode: Int? = nil
    /// Set when a rebind didn't settle in time. There is no OS status for
    /// that case; the window and the time waited say how close it came.
    var settleTimeoutMs: Int? = nil
    var settleWaitMs: Int? = nil

    static func failureKind(for error: Error) -> (kind: String, statusCode: Int?) {
        switch error as? DictationInputDeviceBindingError {
        case .selectedDeviceNotBound?:
            return ("binding_not_settled", nil)
        case .applicationFailed?:
            return ("binding_application_failed", nil)
        case .selectionUnavailable?:
            return ("selection_unavailable", nil)
        case nil:
            return ("set_device_failed", (error as NSError).code)
        }
    }
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
