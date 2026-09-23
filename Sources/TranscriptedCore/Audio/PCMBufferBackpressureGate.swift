import Foundation
@preconcurrency import AVFoundation
import Synchronization

/// Hard admission limit for PCM buffers retained by asynchronous work.
///
/// Audio callbacks must never build an unlimited queue when disk or another
/// consumer stalls. The gate accounts for retained bytes before a buffer is
/// enqueued. The first overflow closes that recording generation; callers
/// surface the failure and stop instead of silently saving incomplete audio.
final class PCMBufferBackpressureGate: @unchecked Sendable {
    enum Admission: Equatable {
        case accepted
        case firstOverflow
        case closed
    }

    private enum GenerationState: UInt64 {
        case closed = 0
        case open = 1
        case failed = 2
        // Stop has moved the session boundary, but the producer may still
        // deliver audio it captured before Stop. Admission stays open for that
        // tail until the producer is torn down and the owner calls `close`.
        case finishing = 3
    }

    let byteLimit: Int

    // One atomic word keeps generation and lifecycle changes indivisible. Two
    // low bits hold the state; exhausting the remaining 62-bit generation
    // space would require billions of start/stop boundaries per nanosecond for
    // longer than the process can exist.
    private let generationState = Atomic<UInt64>(0)
    private let pendingBytes = Atomic<Int>(0)

    init(byteLimit: Int) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    func begin(generation: UInt64) {
        generationState.store(
            encoded(generation: generation, state: .open),
            ordering: .releasing
        )
    }

    /// Keeps `generation` admitting its already-captured tail after Stop.
    /// Only an open generation can start finishing: an overflowed or closed
    /// one stays shut, and a successor's `begin` replaces this state outright.
    func beginFinishing(generation: UInt64) {
        _ = generationState.compareExchange(
            expected: encoded(generation: generation, state: .open),
            desired: encoded(generation: generation, state: .finishing),
            ordering: .acquiringAndReleasing
        )
    }

    func isFinishing(generation: UInt64) -> Bool {
        generationState.load(ordering: .acquiring)
            == encoded(generation: generation, state: .finishing)
    }

    func close(generation: UInt64) {
        let closed = encoded(generation: generation, state: .closed)
        var observed = generationState.load(ordering: .acquiring)
        while decodedGeneration(of: observed) == generation {
            let result = generationState.compareExchange(
                expected: observed,
                desired: closed,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return }
            observed = result.original
        }
    }

    func admit(bytes: Int, generation: UInt64) -> Admission {
        guard bytes > 0 else { return .closed }
        let admitting = generationState.load(ordering: .acquiring)
        guard isAdmitting(admitting, generation: generation) else {
            return .closed
        }

        guard bytes <= byteLimit else {
            return failOpenGeneration(generation, expectedOpenState: admitting)
        }

        var observedBytes = pendingBytes.load(ordering: .relaxed)
        while true {
            guard observedBytes <= byteLimit - bytes else {
                return failOpenGeneration(generation, expectedOpenState: admitting)
            }

            let result = pendingBytes.compareExchange(
                expected: observedBytes,
                desired: observedBytes + bytes,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged {
                // Stop or overflow may have won while this reservation CAS was
                // in flight. Give the bytes back instead of queueing stale work.
                // Open -> finishing is not a loss: that tail is still wanted.
                guard isAdmitting(
                    generationState.load(ordering: .acquiring),
                    generation: generation
                ) else {
                    release(bytes: bytes)
                    return .closed
                }
                return .accepted
            }
            observedBytes = result.original
        }
    }

    func release(bytes: Int) {
        guard bytes > 0 else { return }
        var observed = pendingBytes.load(ordering: .relaxed)
        while true {
            let result = pendingBytes.compareExchange(
                expected: observed,
                desired: observed >= bytes ? observed - bytes : 0,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return }
            observed = result.original
        }
    }

    var pendingBytesForTesting: Int {
        pendingBytes.load(ordering: .acquiring)
    }

    private func isAdmitting(_ encodedState: UInt64, generation: UInt64) -> Bool {
        encodedState == encoded(generation: generation, state: .open)
            || encodedState == encoded(generation: generation, state: .finishing)
    }

    private func failOpenGeneration(
        _ generation: UInt64,
        expectedOpenState: UInt64
    ) -> Admission {
        let failed = encoded(generation: generation, state: .failed)
        let result = generationState.compareExchange(
            expected: expectedOpenState,
            desired: failed,
            ordering: .acquiringAndReleasing
        )
        // A finishing generation is already stopping; overflow there only
        // drops the rest of the tail and must not request a second stop.
        guard result.exchanged,
              expectedOpenState == encoded(generation: generation, state: .open) else {
            return .closed
        }
        return .firstOverflow
    }

    private func encoded(
        generation: UInt64,
        state: GenerationState
    ) -> UInt64 {
        (generation &* 4) | state.rawValue
    }

    private func decodedGeneration(of encodedState: UInt64) -> UInt64 {
        encodedState / 4
    }

    static func retainedByteCount(for buffer: AVAudioPCMBuffer) -> Int {
        var total = 0
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in buffers {
            total += Int(audioBuffer.mDataByteSize)
        }
        return total
    }
}

/// Allows at most one overflow-triggered stop request for a recording.
///
/// Mic and system callbacks run on different queues, so both streams can hit
/// their independent byte limits before the main queue processes either stop.
/// This tiny generation gate keeps that race from running `Audio.stop()` twice.
final class PCMBackpressureStopAdmission: @unchecked Sendable {
    private enum GenerationState: UInt64 {
        case closed = 0
        case open = 1
        case claimed = 2
    }

    private let generationState = Atomic<UInt64>(0)

    func begin(generation: UInt64) {
        generationState.store(
            encoded(generation: generation, state: .open),
            ordering: .releasing
        )
    }

    func claim(generation: UInt64) -> Bool {
        generationState.compareExchange(
            expected: encoded(generation: generation, state: .open),
            desired: encoded(generation: generation, state: .claimed),
            ordering: .acquiringAndReleasing
        ).exchanged
    }

    func close(generation: UInt64) {
        let closed = encoded(generation: generation, state: .closed)
        var observed = generationState.load(ordering: .acquiring)
        while decodedGeneration(of: observed) == generation {
            let result = generationState.compareExchange(
                expected: observed,
                desired: closed,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return }
            observed = result.original
        }
    }

    private func encoded(
        generation: UInt64,
        state: GenerationState
    ) -> UInt64 {
        (generation &* 4) | state.rawValue
    }

    private func decodedGeneration(of encodedState: UInt64) -> UInt64 {
        encodedState / 4
    }
}

/// Dedicated bounded handoff for app-host mic consumers.
///
/// File I/O and borrowed-mic dictation must not share a serial queue: a slow
/// disk would delay otherwise-available dictation audio. This relay uses the
/// same lock-free byte admission as file writes, then runs the host callback on
/// its own queue. Stop can enqueue a tail barrier so every admitted callback is
/// delivered before the host finalizes or clears its consumer.
final class BoundedPCMBufferFanout: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer) -> Void

    private let queue: DispatchQueue
    private let backpressure: PCMBufferBackpressureGate

    init(label: String, byteLimit: Int) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        backpressure = PCMBufferBackpressureGate(byteLimit: byteLimit)
    }

    var byteLimit: Int { backpressure.byteLimit }

    func begin(generation: UInt64) {
        backpressure.begin(generation: generation)
    }

    func enqueue(
        _ buffer: AVAudioPCMBuffer,
        generation: UInt64,
        handler: @escaping Handler
    ) -> PCMBufferBackpressureGate.Admission {
        let retainedBytes = PCMBufferBackpressureGate.retainedByteCount(for: buffer)
        let admission = backpressure.admit(
            bytes: retainedBytes,
            generation: generation
        )
        guard admission == .accepted else { return admission }

        let backpressure = self.backpressure
        queue.async {
            defer { backpressure.release(bytes: retainedBytes) }
            handler(buffer)
        }
        return .accepted
    }

    /// Closes admission immediately and places completion behind the exact tail
    /// already accepted for this generation.
    func close(generation: UInt64, completion: @escaping () -> Void) {
        backpressure.close(generation: generation)
        queue.async(execute: completion)
    }

    func flush(completion: @escaping () -> Void) {
        queue.async(execute: completion)
    }

    var pendingBytesForTesting: Int {
        backpressure.pendingBytesForTesting
    }
}
