import AVFoundation
import Synchronization

/// One timeline per recording. Recovered routes and finishing writers keep
/// the same reference. Only the control thread allocates transition nodes.
final class MeetingMicMuteTimeline: @unchecked Sendable {
    private struct Edge {
        let seconds: Double
        let muted: Bool
        let previous: UnsafeMutablePointer<Edge>?
    }

    private let head = Atomic<UnsafeMutablePointer<Edge>?>(nil)
    private let revision = Atomic<UInt64>(0)
    private let writer = NSLock()

    deinit {
        var edge = head.load(ordering: .relaxed)
        while let current = edge {
            edge = current.pointee.previous
            current.deinitialize(count: 1)
            current.deallocate()
        }
    }

    var isMuted: Bool { head.load(ordering: .acquiring)?.pointee.muted ?? false }

    func setMuted(_ muted: Bool, clock: () -> Double = PinnedMicrophoneBufferRing.hostSecondsNow) {
        writer.lock()
        defer { writer.unlock() }
        guard muted != isMuted else { return }
        revision.wrappingAdd(1, ordering: .acquiringAndReleasing)
        let seconds = clock()
        let edge = UnsafeMutablePointer<Edge>.allocate(capacity: 1)
        edge.initialize(to: Edge(seconds: seconds, muted: muted, previous: head.load(ordering: .relaxed)))
        head.store(edge, ordering: .releasing)
        revision.wrappingAdd(1, ordering: .releasing)
    }

    /// Called only with owned native PCM, before any resampler can retain
    /// filter history. Frame intervals and mute intervals are half-open.
    func redact(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let rate = buffer.format.sampleRate
        let end = hostSeconds + Double(frames) / rate
        let version = revision.load(ordering: .acquiring)
        let now = PinnedMicrophoneBufferRing.hostSecondsNow()
        var edge = head.load(ordering: .acquiring)
        guard hostSeconds > 0, rate.isFinite, rate > 0, end <= now,
              version.isMultiple(of: 2), revision.load(ordering: .acquiring) == version else {
            clear(buffer, frames: 0..<frames)
            return
        }
        var until = end
        while let current = edge {
            let transition = current.pointee
            if until <= hostSeconds { break }
            if transition.muted, transition.seconds < end {
                // Compare frame edges in host seconds. Subtracting a large host
                // time then rounding can erase a neighbour at an exact boundary.
                var first = 0, last = frames
                while first < last && hostSeconds + Double(first + 1) / rate <= transition.seconds { first += 1 }
                while last > first && hostSeconds + Double(last - 1) / rate >= until { last -= 1 }
                clear(buffer, frames: first..<last)
            }
            until = min(until, transition.seconds)
            edge = transition.previous
        }
    }

    private func clear(_ buffer: AVAudioPCMBuffer, frames: Range<Int>) {
        guard !frames.isEmpty else { return }
        let stride = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = plane.mData {
                memset(data.advanced(by: frames.lowerBound * stride), 0, frames.count * stride)
            }
        }
    }
}

/// Used only when installing a tap or changing mute from the UI.
final class MeetingMicMuteSessions: @unchecked Sendable {
    private let state = Mutex((generation: UInt64(0), timeline: MeetingMicMuteTimeline()))

    func timeline(for generation: UInt64) -> MeetingMicMuteTimeline {
        state.withLock { current in
            if generation > current.generation {
                current = (generation, MeetingMicMuteTimeline())
            }
            if generation == current.generation { return current.timeline }
            let retired = MeetingMicMuteTimeline()
            retired.setMuted(true, clock: { 0 })
            return retired
        }
    }
}
