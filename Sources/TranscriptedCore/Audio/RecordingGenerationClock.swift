import Foundation
import Synchronization

/// The existing recording epoch and its lock-free callback mirror. Artifact
/// boundaries share this lock; no graph, format or health state lives here.
final class RecordingGenerationClock: @unchecked Sendable {
    let generationLock = NSLock()
    private var epoch: SupersessionEpoch
    private let mirror: Atomic<UInt64>
    private var stoppingGeneration: UInt64?
    private var advanceHook: ((UInt64) -> Void)?

    init(rawGeneration: UInt64 = 0) {
        epoch = SupersessionEpoch(testRawValue: rawGeneration)
        mirror = Atomic(rawGeneration)
    }

    var current: UInt64 { mirror.load(ordering: .acquiring) }
    var inFlightStopGeneration: UInt64? {
        get {
            generationLock.lock(); defer { generationLock.unlock() }
            return stoppingGeneration == epoch.snapshot().rawValue ? stoppingGeneration : nil
        }
        set {
            generationLock.lock(); stoppingGeneration = newValue; generationLock.unlock()
        }
    }
    var afterAdvanceForTesting: ((UInt64) -> Void)? {
        get { generationLock.lock(); defer { generationLock.unlock() }; return advanceHook }
        set { generationLock.lock(); advanceHook = newValue; generationLock.unlock() }
    }
    func predictedNext() -> UInt64 {
        generationLock.lock(); defer { generationLock.unlock() }
        return epoch.predictedNext().rawValue
    }

    // Only the owner or an existing Audio generation critical section calls
    // these methods with generationLock held. Publishing follows O mutation.
    func currentWhileLocked() -> UInt64 { epoch.snapshot().rawValue }
    func advanceEpochWhileLocked() -> UInt64 { epoch.begin().rawValue }
    func publishMirrorWhileLocked(_ value: UInt64) { mirror.store(value, ordering: .releasing) }
    func advanceHookSnapshotWhileLocked() -> ((UInt64) -> Void)? { advanceHook }
    func setInFlightWhileLocked(_ value: UInt64?) { stoppingGeneration = value }
    func replaceEpochWhileLocked(_ value: UInt64) { epoch = SupersessionEpoch(testRawValue: value) }
}
