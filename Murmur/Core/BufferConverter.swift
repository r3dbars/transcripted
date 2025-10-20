import Foundation
import AVFoundation

/// Converts AVAudioPCMBuffer to a target audio format for SpeechAnalyzer
@available(macOS 26.0, *)
class BufferConverter {
    private let targetFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    init(to format: AVAudioFormat) {
        self.targetFormat = format
    }

    /// Converts an audio buffer to the target format
    /// Returns nil if conversion fails
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // If already in target format, return as-is
        if buffer.format == targetFormat {
            return buffer
        }

        // Create or recreate converter if input format changed
        if audioConverter == nil || lastInputFormat != buffer.format {
            audioConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            lastInputFormat = buffer.format
        }

        guard let converter = audioConverter else {
            print("❌ BufferConverter: Failed to create audio converter")
            return nil
        }

        // Calculate output buffer capacity based on sample rate ratio
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            print("❌ BufferConverter: Failed to create output buffer")
            return nil
        }

        // Perform conversion
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            if let error = error {
                print("❌ BufferConverter: Conversion failed - \(error.localizedDescription)")
            }
            return nil
        }

        return outputBuffer
    }
}
