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
        guard ceilingDB > floorDB else { return 0 }
        guard let channelData = buffer.floatChannelData else { return 0 }

        let frames = frames.clamped(to: 0..<Int(buffer.frameLength))
        let channelCount = Int(buffer.format.channelCount)
        guard !frames.isEmpty, channelCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        var sampleCount = 0

        if buffer.format.isInterleaved {
            let samples = channelData[0]
            for index in (frames.lowerBound * channelCount)..<(frames.upperBound * channelCount) {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }
            sampleCount = frames.count * channelCount
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in frames {
                    let sample = samples[frame]
                    sumOfSquares += sample * sample
                }
            }
            sampleCount = frames.count * channelCount
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumOfSquares / Float(sampleCount))
        let dB = rms > 0.0001 ? 20.0 * log10(rms) : -60.0
        return max(0.0, min(1.0, (dB - floorDB) / (ceilingDB - floorDB)))
    }
}
