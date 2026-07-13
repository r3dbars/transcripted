@preconcurrency import AVFoundation
import Foundation

struct SharedMeetingMicChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

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

    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> SharedMeetingMicChunk? {
        guard let monoSamples = Self.extractMonoSamples(from: buffer), !monoSamples.isEmpty else { return nil }
        let sampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
            bufferSampleRate: buffer.format.sampleRate
        )
        return lock.withLock {
            guard isActive else { return nil }
            timeline.append(monoSamples, sampleRate: sampleRate)
            return SharedMeetingMicChunk(samples: monoSamples, sampleRate: sampleRate)
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
