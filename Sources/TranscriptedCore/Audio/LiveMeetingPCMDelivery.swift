import Foundation
@preconcurrency import AVFoundation
import QuartzCore
import Synchronization

/// The capture track, not a claimed speaker identity.
public enum LiveMeetingAudioSource: String, Sendable {
    case microphone
    case system
}

/// Optional, lossy host delivery. A slow live preview never stops recording or
/// shares the durable audio writer's queue. Producers pass an already-owned copy.
final class LiveMeetingPCMDelivery: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer, LiveMeetingAudioSource, TimeInterval, UInt64) -> Void
    private let queue = DispatchQueue(label: "com.transcripted.live-meeting-pcm", qos: .utility)
    private let enabled = Atomic<Bool>(false)
    private let generation = Atomic<UInt64>(0)
    private let captureGeneration = Atomic<UInt64>(0)
    private let previewEpoch = Atomic<UInt64>(0)
    private let pendingBytes = Atomic<Int>(0)
    private let droppedBuffers = Atomic<Int>(0)
    private let byteLimit: Int
    /// The host's consumer; set once before capture, read on the enqueue path.
    var handler: Handler?

    init(byteLimit: Int = 2 * 1_024 * 1_024) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    func setEnabled(_ value: Bool, captureGeneration: UInt64 = 0, previewEpoch: UInt64 = 0) {
        enabled.store(false, ordering: .releasing)
        _ = generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
        self.captureGeneration.store(captureGeneration, ordering: .releasing)
        self.previewEpoch.store(previewEpoch, ordering: .releasing)
        droppedBuffers.store(0, ordering: .releasing)
        enabled.store(value, ordering: .releasing)
    }

    var dropCount: Int { droppedBuffers.load(ordering: .acquiring) }

    /// A barrier for already-admitted preview buffers; it never waits on ASR.
    func flush(completion: @escaping () -> Void) { queue.async(execute: completion) }

    func enqueue(_ buffer: AVAudioPCMBuffer, source: LiveMeetingAudioSource, captureGeneration: UInt64 = 0, handler: @escaping Handler) {
        let owner = generation.load(ordering: .acquiring)
        let admittedEpoch = previewEpoch.load(ordering: .acquiring)
        guard enabled.load(ordering: .acquiring), self.captureGeneration.load(ordering: .acquiring) == captureGeneration else { return }
        let bytes = PCMBufferBackpressureGate.retainedByteCount(for: buffer)
        guard bytes > 0, bytes <= byteLimit else {
            _ = droppedBuffers.wrappingAdd(1, ordering: .relaxed)
            return
        }
        var pending = pendingBytes.load(ordering: .relaxed)
        while true {
            guard pending <= byteLimit - bytes else {
                _ = droppedBuffers.wrappingAdd(1, ordering: .relaxed)
                return
            }
            let result = pendingBytes.compareExchange(expected: pending, desired: pending + bytes, ordering: .acquiringAndReleasing)
            if result.exchanged { break }
            pending = result.original
        }
        let capturedAt = CACurrentMediaTime()
        queue.async { [self] in
            defer { _ = pendingBytes.wrappingSubtract(bytes, ordering: .acquiringAndReleasing) }
            guard enabled.load(ordering: .acquiring), generation.load(ordering: .acquiring) == owner,
                  self.captureGeneration.load(ordering: .acquiring) == captureGeneration,
                  previewEpoch.load(ordering: .acquiring) == admittedEpoch else { return }
            // Carry the admission lease through any downstream conversion. A
            // sharing toggle can happen after this check while the handler runs.
            handler(buffer, source, capturedAt, admittedEpoch)
        }
    }
}
