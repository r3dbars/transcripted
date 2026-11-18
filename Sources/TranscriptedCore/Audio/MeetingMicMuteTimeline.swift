import AVFoundation
import Synchronization

/// Confined to one engine tap or one pinned hardware stream's drain queue.
/// A new stream cannot vouch for capture before it was installed. A broken
/// sequence reanchors at receipt time, independently of the mute switches.
/// An invalid receipt/interval or an overlap raises the fence. Distinguish
/// a fresh regression from in-order buffers still catching up to that fence.
final class MicCaptureContinuity {
    private var earliestStart: Double
    private var previousEnd: Double?

    init(start: Double = PinnedMicrophoneBufferRing.hostSecondsNow()) {
        earliestStart = start
    }

    func isAdjacent(to start: Double) -> Bool {
        guard let previousEnd, start >= earliestStart else { return false }
        return abs(start - previousEnd) <= PinnedMicrophoneBufferRing.secondsPerHostTick + start.ulp
    }

    func reanchor(at received: Double) {
        earliestStart = max(earliestStart, received)
        previousEnd = nil
    }

    func ambiguousPrefix(start: Double, end: Double, received: Double, frames: Int) -> Int {
        guard start > 0, end > start, end <= received else {
            reanchor(at: received)
            return frames
        }
        defer { previousEnd = end }
        if let previousEnd, start >= earliestStart, start < previousEnd, end > previousEnd,
           previousEnd - start <= PinnedMicrophoneBufferRing.secondsPerHostTick + end.ulp {
            // Adjacent frame boundaries can round to different integer host
            // ticks. Only the first frame has ambiguous ownership in this case.
            return 1
        }
        if start < (previousEnd ?? earliestStart) {
            earliestStart = max(earliestStart, received)
        }
        return start >= earliestStart ? 0 : frames
    }
}

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
    func redact(_ buffer: AVAudioPCMBuffer, hostSeconds: Double, received: Double, continuity: MicCaptureContinuity) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let rate = buffer.format.sampleRate
        let end = hostSeconds + Double(frames) / rate
        let adjacent = continuity.isAdjacent(to: hostSeconds)
        let ambiguous = continuity.ambiguousPrefix(start: hostSeconds, end: end, received: received, frames: frames)
        let version = revision.load(ordering: .acquiring)
        var edge = head.load(ordering: .acquiring)
        guard version.isMultiple(of: 2), revision.load(ordering: .acquiring) == version else {
            clear(buffer, frames: 0..<frames)
            return
        }
        // A coherent empty history proves these frames cannot contain a muted
        // interval, even if the driver supplied no useful clock.
        guard edge != nil else { return }
        // Across a route start or gap, a plausible but stale stamp can put
        // the entire buffer before a switch that already happened by receipt.
        // A switch after receipt (e.g. while queued) cannot cause this ambiguity.
        if !adjacent, ambiguous < frames {
            var recent = edge
            while let transition = recent?.pointee, transition.seconds >= end {
                if transition.seconds <= received {
                    continuity.reanchor(at: received)
                    clear(buffer, frames: 0..<frames)
                    return
                }
                recent = transition.previous
            }
        }
        clear(buffer, frames: 0..<ambiguous)
        guard ambiguous < frames else { return }
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
