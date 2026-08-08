import Foundation
@preconcurrency import AVFoundation

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

    private struct State {
        var activeGeneration: UInt64?
        var failedGeneration: UInt64?
        var pendingBytes = 0
    }

    let byteLimit: Int

    private let lock = NSLock()
    private var state = State()

    init(byteLimit: Int) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    func begin(generation: UInt64) {
        lock.lock()
        state.activeGeneration = generation
        state.failedGeneration = nil
        lock.unlock()
    }

    func close(generation: UInt64) {
        lock.lock()
        if state.activeGeneration == generation {
            state.activeGeneration = nil
        }
        lock.unlock()
    }

    func admit(bytes: Int, generation: UInt64) -> Admission {
        guard bytes > 0 else { return .closed }

        lock.lock()
        defer { lock.unlock() }

        guard state.activeGeneration == generation,
              state.failedGeneration != generation else {
            return .closed
        }

        guard bytes <= byteLimit,
              state.pendingBytes <= byteLimit - bytes else {
            state.failedGeneration = generation
            return .firstOverflow
        }

        state.pendingBytes += bytes
        return .accepted
    }

    func release(bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        state.pendingBytes = max(0, state.pendingBytes - bytes)
        lock.unlock()
    }

    var pendingBytesForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.pendingBytes
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
    private let lock = NSLock()
    private var activeGeneration: UInt64?
    private var claimed = false

    func begin(generation: UInt64) {
        lock.withLock {
            activeGeneration = generation
            claimed = false
        }
    }

    func claim(generation: UInt64) -> Bool {
        lock.withLock {
            guard activeGeneration == generation, !claimed else { return false }
            claimed = true
            return true
        }
    }

    func close(generation: UInt64) {
        lock.withLock {
            guard activeGeneration == generation else { return }
            activeGeneration = nil
            claimed = false
        }
    }
}
