import AVFoundation
import Foundation

/// One reading of the dictation waveform meter, on `DictationAudioLevelMeter`'s
/// 0...1 scale (the same floor and ceiling as always).
struct DictationAudioLevel: Equatable, Sendable {
    /// RMS of every frame since the last reading.
    let level: Float
    /// The loudest single buffer in that span, so a short syllable the
    /// average would flatten can still show at its height. Never below
    /// `level`.
    let peak: Float

    init(level: Float, peak: Float? = nil) {
        self.level = level
        self.peak = max(level, peak ?? level)
    }

    static let silent = DictationAudioLevel(level: 0)
}

enum DictationAudioLevelMeter {
    static func normalizedLevel(
        from buffer: AVAudioPCMBuffer,
        floorDB: Float = TranscriptedConstants.audioLevelFloorDB,
        ceilingDB: Float = TranscriptedConstants.audioLevelCeilingDB
    ) -> Float {
        normalizedLevel(
            from: buffer,
            frames: 0..<Int(buffer.frameLength),
            floorDB: floorDB,
            ceilingDB: ceilingDB
        )
    }

    /// Level of one slice of `buffer`, on the same scale as the whole-buffer
    /// meter. Borrowed meeting-mic dictation uses it to meter a long relayed
    /// buffer in dictation-sized windows.
    static func normalizedLevel(
        from buffer: AVAudioPCMBuffer,
        frames: Range<Int>,
        floorDB: Float = TranscriptedConstants.audioLevelFloorDB,
        ceilingDB: Float = TranscriptedConstants.audioLevelCeilingDB
    ) -> Float {
        guard ceilingDB > floorDB,
              let energy = energy(of: buffer, frames: frames) else { return 0 }
        return normalizedLevel(
            meanSquare: energy.sumOfSquares / Float(energy.sampleCount),
            floorDB: floorDB,
            ceilingDB: ceilingDB
        )
    }

    /// The sum of squares over every channel of `frames` (per-channel energy,
    /// so stereo can't cancel out the way a downmix would), and how many
    /// samples that was. Nil for no samples.
    static func energy(of buffer: AVAudioPCMBuffer, frames: Range<Int>) -> (sumOfSquares: Float, sampleCount: Int)? {
        guard let channelData = buffer.floatChannelData else { return nil }

        let frames = frames.clamped(to: 0..<Int(buffer.frameLength))
        let channelCount = Int(buffer.format.channelCount)
        guard !frames.isEmpty, channelCount > 0 else { return nil }

        var sumOfSquares: Float = 0
        if buffer.format.isInterleaved {
            let samples = channelData[0]
            for index in (frames.lowerBound * channelCount)..<(frames.upperBound * channelCount) {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in frames {
                    let sample = samples[frame]
                    sumOfSquares += sample * sample
                }
            }
        }
        return (sumOfSquares, frames.count * channelCount)
    }

    /// The meter's 0...1 scale for a mean square: the dB of its RMS, placed
    /// between the floor and the ceiling.
    static func normalizedLevel(
        meanSquare: Float,
        floorDB: Float = TranscriptedConstants.audioLevelFloorDB,
        ceilingDB: Float = TranscriptedConstants.audioLevelCeilingDB
    ) -> Float {
        guard ceilingDB > floorDB else { return 0 }
        let rms = sqrt(max(0, meanSquare))
        let dB = rms > 0.0001 ? 20.0 * log10(rms) : -60.0
        return max(0.0, min(1.0, (dB - floorDB) / (ceilingDB - floorDB)))
    }
}

/// Meters every buffer a dictation records, for the island's waveform.
///
/// The capture paths used to meter one ~10 ms buffer per 50 ms or more and
/// skip the rest, so about 80% of the audio never moved the waveform, and
/// what did was whichever slice happened to be sampled. This adds up every
/// buffer and hands back a reading once the buffers since the last reading
/// hold `windowSeconds` of audio (about 25 readings a second): `level` is the
/// RMS of all of it and `peak` the loudest single buffer, both on
/// `DictationAudioLevelMeter`'s scale, so a steady sound reads exactly as it
/// did. Audio time, not wall time, so a late callback can't stretch or skip
/// a window.
///
/// One window per recording, fed from that recording's capture queue (the
/// pinned recorder's queue or the engine tap's thread, never the real-time
/// audio thread). The lock is uncontended; it's there so a feed that moves
/// threads can't tear the sums.
final class DictationAudioLevelWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let windowSeconds: TimeInterval
    private var seconds: Double = 0
    private var sumOfSquares: Double = 0
    private var sampleCount = 0
    private var loudestMeanSquare: Float = 0

    init(windowSeconds: TimeInterval = TranscriptedConstants.dictationLevelReadingInterval) {
        self.windowSeconds = windowSeconds
    }

    /// Adds one buffer. Returns a reading once the buffers since the last
    /// reading hold at least `windowSeconds` of audio, else nil. An empty
    /// buffer adds nothing.
    func add(_ buffer: AVAudioPCMBuffer) -> DictationAudioLevel? {
        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, sampleRate > 0,
              let energy = DictationAudioLevelMeter.energy(of: buffer, frames: 0..<frameCount) else { return nil }
        let bufferMeanSquare = energy.sumOfSquares / Float(energy.sampleCount)
        return lock.withLock { () -> DictationAudioLevel? in
            seconds += Double(frameCount) / sampleRate
            sumOfSquares += Double(energy.sumOfSquares)
            sampleCount += energy.sampleCount
            loudestMeanSquare = max(loudestMeanSquare, bufferMeanSquare)
            // A hair of slack, so a window that's exactly full isn't held back
            // a buffer by rounding.
            guard seconds + 1e-9 >= windowSeconds else { return nil }
            let reading = DictationAudioLevel(
                level: DictationAudioLevelMeter.normalizedLevel(meanSquare: Float(sumOfSquares / Double(sampleCount))),
                peak: DictationAudioLevelMeter.normalizedLevel(meanSquare: loudestMeanSquare)
            )
            seconds = 0
            sumOfSquares = 0
            sampleCount = 0
            loudestMeanSquare = 0
            return reading
        }
    }
}
