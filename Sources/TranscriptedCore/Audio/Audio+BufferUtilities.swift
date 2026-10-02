import Foundation
import Darwin
@preconcurrency import AVFoundation

extension Audio {

    // MARK: - Buffer Utilities

    /// Manually downmix multi-channel mic audio to mono by taking the dominant
    /// channel for this buffer. Averaging can halve a real mic when the second
    /// channel is silent, and opposite-polarity channel pairs can cancel speech.
    func manualDownmix(buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.channelCount > 0,
              buffer.floatChannelData != nil,
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = monoBuffer.floatChannelData?[0] else { return nil }
        monoBuffer.frameLength = buffer.frameLength
        MicrophoneDownmix.copyMonoSamples(from: buffer, to: destination)
        return monoBuffer
    }

    /// Deep copy an AVAudioPCMBuffer to ensure data safety across async dispatch
    /// Required because system audio buffers use bufferListNoCopy and don't own their memory
    func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        // Copy audio data based on format (interleaved vs non-interleaved)
        if buffer.format.isInterleaved {
            // Interleaved: single contiguous buffer
            if let srcData = buffer.floatChannelData?[0],
               let dstData = copy.floatChannelData?[0] {
                let bytesToCopy = Int(buffer.frameLength) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
                memcpy(dstData, srcData, bytesToCopy)
            }
        } else {
            // Non-interleaved: separate buffer per channel
            if let srcChannels = buffer.floatChannelData,
               let dstChannels = copy.floatChannelData {
                let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Float>.size
                for channel in 0..<Int(buffer.format.channelCount) {
                    memcpy(dstChannels[channel], srcChannels[channel], bytesPerChannel)
                }
            }
        }

        return copy
    }
}
