import AVFoundation
import Foundation

enum DictationAudioLevelMeter {
    static func normalizedLevel(
        from buffer: AVAudioPCMBuffer,
        floorDB: Float = TranscriptedConstants.audioLevelFloorDB,
        ceilingDB: Float = TranscriptedConstants.audioLevelCeilingDB
    ) -> Float {
        guard ceilingDB > floorDB else { return 0 }
        guard let channelData = buffer.floatChannelData else { return 0 }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        var sampleCount = 0

        if buffer.format.isInterleaved {
            let samples = channelData[0]
            let totalSamples = frameCount * channelCount
            for index in 0..<totalSamples {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }
            sampleCount = totalSamples
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameCount {
                    let sample = samples[frame]
                    sumOfSquares += sample * sample
                }
            }
            sampleCount = frameCount * channelCount
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumOfSquares / Float(sampleCount))
        let dB = rms > 0.0001 ? 20.0 * log10(rms) : -60.0
        return max(0.0, min(1.0, (dB - floorDB) / (ceilingDB - floorDB)))
    }
}
