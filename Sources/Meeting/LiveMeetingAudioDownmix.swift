import Accelerate
@preconcurrency import AVFoundation

/// Averages a float PCM buffer's channels into mono for the live transcript.
/// Runs on Core's live-PCM delivery queue, never a CoreAudio callback.
/// Foundation and AVFoundation only, so the fast tests compile it.
enum LiveMeetingAudioDownmix {
    /// Nil for an empty, oversized or non-float buffer.
    static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, frames <= 192_000, channels > 0, channels <= 32, let data = buffer.floatChannelData else { return nil }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }
        let interleaved = buffer.format.isInterleaved
        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { out in
            let sum = out.baseAddress!
            let length = vDSP_Length(frames)
            // Summed channel by channel from zero, in channel order, then
            // divided: the same arithmetic as a per-sample loop.
            for channel in 0..<channels {
                if interleaved {
                    vDSP_vadd(sum, 1, data[0] + channel, vDSP_Stride(channels), sum, 1, length)
                } else {
                    vDSP_vadd(sum, 1, data[channel], 1, sum, 1, length)
                }
            }
            var divisor = Float(channels)
            vDSP_vsdiv(sum, 1, &divisor, sum, 1, length)
        }
        return mono
    }
}
