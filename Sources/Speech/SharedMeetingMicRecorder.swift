@preconcurrency import AVFoundation
import Foundation

/// Thread-safe storage for dictation samples borrowed from an active meeting.
/// MeetingCaptureBridge delivers buffers on its relay queue, never on the
/// CoreAudio tap thread. Synchronization makes MainActor start/stop atomic with
/// any buffers already queued for delivery.
final class SharedMeetingMicRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = false
    private var timeline = RecordedAudioTimeline()

    func begin() {
        lock.withLock {
            timeline.removeAll(keepingCapacity: true)
            isActive = true
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let monoSamples = Self.extractMonoSamples(from: buffer), !monoSamples.isEmpty else { return }
        let sampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
            bufferSampleRate: buffer.format.sampleRate
        )
        lock.withLock {
            guard isActive else { return }
            timeline.append(monoSamples, sampleRate: sampleRate)
        }
    }

    func finish() -> RecordedAudioTimeline {
        lock.withLock {
            isActive = false
            let finished = timeline
            timeline.removeAll(keepingCapacity: true)
            return finished
        }
    }

    func cancel() {
        lock.withLock {
            isActive = false
            timeline.removeAll(keepingCapacity: true)
        }
    }

    private static func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }

        if channelCount == 1 {
            guard let channelData = buffer.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        }

        var mono = Array<Float>(repeating: 0, count: frameCount)
        if buffer.format.isInterleaved {
            guard let interleaved = buffer.floatChannelData?[0] else { return nil }
            for frame in 0..<frameCount {
                let base = frame * channelCount
                var sum: Float = 0
                for channel in 0..<channelCount { sum += interleaved[base + channel] }
                mono[frame] = sum / Float(channelCount)
            }
            return mono
        }

        guard let channels = buffer.floatChannelData else { return nil }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }
}

/// Main-actor generation guard for the only suspending shared-mic transition:
/// resuming regular dictation capture after a meeting ends.
///
/// Relationship to `SharedMeetingMicClaim` (SharedMeetingMicClaim.swift):
/// these guard different failure classes and neither replaces the other.
/// `SharedMeetingMicClaim` answers "is the meeting session that lent this
/// mic still alive at all" — a claim can go stale across the *entire*
/// borrowed-mic lifetime, including while nothing is suspending. This type
/// answers a narrower question that only matters for the few `await`
/// boundaries inside `resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded`:
/// "is *this specific* resume attempt still the most recent one", so a
/// second resume (or a stop/cancel/wake) that starts after the first
/// suspends can't have its stale continuation finish the transition. A
/// claim can be perfectly current for the whole time this generation counter
/// is doing its job.
struct SharedMeetingMicTransitionState {
    private(set) var generation = 0
    private(set) var isResumeInProgress = false

    mutating func beginSharedRecording() {
        generation += 1
        isResumeInProgress = false
    }

    mutating func beginResume() -> Int {
        generation += 1
        isResumeInProgress = true
        return generation
    }

    mutating func finishResume(token: Int) -> Bool {
        guard isResumeInProgress, token == generation else { return false }
        isResumeInProgress = false
        return true
    }

    mutating func invalidate() {
        generation += 1
        isResumeInProgress = false
    }
}
