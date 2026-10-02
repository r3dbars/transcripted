import Foundation

/// 16 kHz mono samples waiting for one track's recognizer. Filled from the
/// live-PCM delivery queue (never a CoreAudio callback), drained by the
/// track. A fixed ring: appending never moves the audio already queued, so a
/// full queue costs the same as an empty one. Past `capacity` the oldest
/// audio is overwritten and the track is told, so it can close the
/// utterance it was in.
final class LiveMeetingCaptionSampleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float]
    private var head = 0
    private var stored = 0
    private var overflowed = false
    let capacity: Int

    /// 30 seconds rides out a dictation (the tracks pause for it) and a
    /// slow first model load.
    init(capacity: Int = 16_000 * 30) {
        self.capacity = max(1, capacity)
        ring = [Float](repeating: 0, count: self.capacity)
    }

    var count: Int { lock.withLock { stored } }

    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        lock.withLock {
            // Only the newest `capacity` samples can survive anyway.
            let incoming = newSamples.count > capacity ? Array(newSamples.suffix(capacity)) : newSamples
            if newSamples.count > capacity { overflowed = true }
            let overflow = stored + incoming.count - capacity
            if overflow > 0 {
                head = (head + overflow) % capacity
                stored -= overflow
                overflowed = true
            }
            var write = (head + stored) % capacity
            incoming.withUnsafeBufferPointer { source in
                ring.withUnsafeMutableBufferPointer { target in
                    var offset = 0
                    while offset < source.count {
                        let run = min(source.count - offset, capacity - write)
                        target.baseAddress!.advanced(by: write)
                            .update(from: source.baseAddress!.advanced(by: offset), count: run)
                        offset += run
                        write = (write + run) % capacity
                    }
                }
            }
            stored += incoming.count
        }
    }

    /// Up to `limit` samples in arrival order, and whether audio was lost
    /// since the last take.
    func take(limit: Int) -> (samples: [Float], overflowed: Bool) {
        lock.withLock {
            let count = min(max(0, limit), stored)
            var taken = [Float]()
            taken.reserveCapacity(count)
            var read = head
            var remaining = count
            while remaining > 0 {
                let run = min(remaining, capacity - read)
                taken.append(contentsOf: ring[read..<(read + run)])
                remaining -= run
                read = (read + run) % capacity
            }
            head = read
            stored -= count
            defer { overflowed = false }
            return (taken, overflowed)
        }
    }

    func removeAll() {
        lock.withLock {
            head = 0
            stored = 0
            overflowed = false
        }
    }
}
