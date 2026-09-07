import AVFoundation

/// Microphone channels can be silent duplicates or opposite-polarity pairs.
/// Keep the strongest channel instead of cancelling speech by averaging them.
public enum MicrophoneDownmix {
    public static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        guard let data = buffer.floatChannelData else { return nil }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { destination in
            copyMonoSamples(from: buffer, to: destination.baseAddress!)
        }
        return output
    }

    /// Destination must have space for buffer.frameLength Float samples.
    static func copyMonoSamples(from buffer: AVAudioPCMBuffer, to destination: UnsafeMutablePointer<Float>) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return }
        let interleaved = buffer.format.isInterleaved
        var strongest = 0
        var strongestEnergy: Double = -1
        if channels > 1 {
            for channel in 0..<channels {
                var energy: Double = 0
                for frame in 0..<frames {
                    let sample = interleaved ? data[0][frame * channels + channel] : data[channel][frame]
                    energy += Double(sample) * Double(sample)
                }
                if energy > strongestEnergy {
                    strongestEnergy = energy
                    strongest = channel
                }
            }
        }
        if !interleaved || channels == 1 {
            destination.update(from: data[strongest], count: frames)
        } else {
            for frame in 0..<frames {
                destination[frame] = data[0][frame * channels + strongest]
            }
        }
    }
}
