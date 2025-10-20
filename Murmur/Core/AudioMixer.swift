import Foundation
import AVFoundation

/// Mixes microphone and system audio buffers into a single stream for transcription
class AudioMixer {
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var mixCount = 0
    private let monitor = AudioDebugMonitor.shared
    private var conversionCount = 0  // Track conversions for diagnostic logging

    /// Target format - can be set externally to match SpeechAnalyzer requirements exactly
    private var targetFormat: AVAudioFormat?

    /// Default format for speech recognition (16kHz, mono, PCM Int16)
    private lazy var defaultSpeechFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    }()

    init() {}

    /// Set the target format to match SpeechAnalyzer's requirements
    func setTargetFormat(_ format: AVAudioFormat) {
        self.targetFormat = format
        // Logging disabled for performance
    }

    /// Get the active target format
    private var activeFormat: AVAudioFormat? {
        return targetFormat ?? defaultSpeechFormat
    }

    /// Mixes microphone and system audio buffers, converting both to target format
    /// Returns nil if unable to create mixed buffer
    func mix(micBuffer: AVAudioPCMBuffer?, systemBuffer: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let speechFormat = activeFormat else {
            return nil
        }

        // If we only have one source, just convert it
        if let micBuffer = micBuffer, systemBuffer == nil {
            return convert(buffer: micBuffer, to: speechFormat)
        }
        if let systemBuffer = systemBuffer, micBuffer == nil {
            return convert(buffer: systemBuffer, to: speechFormat)
        }

        // If we have both, convert each then mix
        guard let micBuffer = micBuffer,
              let systemBuffer = systemBuffer else {
            return nil
        }

        guard let convertedMic = convert(buffer: micBuffer, to: speechFormat) else {
            return nil
        }

        guard let convertedSystem = convert(buffer: systemBuffer, to: speechFormat) else {
            return nil
        }

        // Create output buffer for mixed audio
        let frameCount = min(convertedMic.frameLength, convertedSystem.frameLength)

        if frameCount == 0 {
            return nil
        }

        guard let mixedBuffer = AVAudioPCMBuffer(
            pcmFormat: speechFormat,
            frameCapacity: frameCount
        ) else {
            return nil
        }

        mixedBuffer.frameLength = frameCount

        // Mix the audio with RMS-based normalization for balanced levels
        if let micData = convertedMic.int16ChannelData,
           let systemData = convertedSystem.int16ChannelData,
           let mixedData = mixedBuffer.int16ChannelData {

            let micPtr = micData[0]
            let systemPtr = systemData[0]
            let mixedPtr = mixedData[0]

            // Calculate RMS levels for both sources
            var micRMS: Float = 0.0
            var systemRMS: Float = 0.0
            let count = Int(frameCount)

            for i in 0..<count {
                let micSample = Float(micPtr[i]) / Float(Int16.max)
                let systemSample = Float(systemPtr[i]) / Float(Int16.max)
                micRMS += micSample * micSample
                systemRMS += systemSample * systemSample
            }

            micRMS = sqrt(micRMS / Float(count))
            systemRMS = sqrt(systemRMS / Float(count))

            // Silence detection threshold - very low to catch quiet system audio
            let silenceThreshold: Float = 0.001  // Below this = considered silent

            // Detect if mic is silent
            let micIsSilent = micRMS < silenceThreshold
            let systemIsSilent = systemRMS < silenceThreshold

            if micIsSilent && !systemIsSilent {
                // Mic is silent, use only system audio with aggressive gain boost
                let targetRMS: Float = 0.15  // Higher target for better recognition
                let systemGain = systemRMS > 0.0001 ? min(targetRMS / systemRMS, 10.0) : 1.0

                for i in 0..<count {
                    let boosted = Float(systemPtr[i]) * systemGain
                    mixedPtr[i] = Int16(max(Float(Int16.min), min(Float(Int16.max), boosted)))
                }
            } else if systemIsSilent && !micIsSilent {
                // System audio is silent, use only mic
                for i in 0..<count {
                    mixedPtr[i] = micPtr[i]
                }
            } else if !micIsSilent && !systemIsSilent {
                // Both have audio - normalize and mix
                let targetRMS: Float = 0.1 // Target RMS level
                let micGain = targetRMS / micRMS
                let systemGain = targetRMS / systemRMS

                // Limit gain to prevent over-amplification
                let maxGain: Float = 4.0
                let finalMicGain = min(micGain, maxGain)
                let finalSystemGain = min(systemGain, maxGain)

                // Mix with normalization and 50/50 blend
                for i in 0..<count {
                    let micNormalized = Float(micPtr[i]) * finalMicGain
                    let systemNormalized = Float(systemPtr[i]) * finalSystemGain
                    let mixed = (micNormalized + systemNormalized) * 0.5 // 50/50 mix
                    let clamped = max(Float(Int16.min), min(Float(Int16.max), mixed))
                    mixedPtr[i] = Int16(clamped)
                }
            } else {
                // Both silent - just pass through zeros
                for i in 0..<count {
                    mixedPtr[i] = 0
                }
            }

            mixCount += 1
            // Verbose logging disabled for performance
        }

        return mixedBuffer
    }

    /// Converts an audio buffer to the target format with high-quality downsampling
    private func convert(buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        // If already in target format, return as-is
        if buffer.format.sampleRate == targetFormat.sampleRate &&
           buffer.format.channelCount == targetFormat.channelCount &&
           buffer.format.commonFormat == targetFormat.commonFormat {
            return buffer
        }

        // Create or reuse converter with maximum quality settings
        let converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        guard let converter = converter else {
            print("❌ Unable to create audio converter from \(buffer.format) to \(targetFormat)")
            return nil
        }

        // Configure for maximum quality downsampling
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal

        // Enable dithering for better quality when converting to Int16
        if targetFormat.commonFormat == .pcmFormatInt16 {
            converter.dither = true
        }

        // Calculate output frame capacity
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            print("❌ Unable to create output buffer")
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if error != nil || status == .error {
            // Conversion error - silently fail
            return nil
        }

        return outputBuffer
    }

    /// Helper to convert a single buffer to target format (used by Audio.swift)
    func convertToSpeechFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let speechFormat = activeFormat else { return nil }
        return convert(buffer: buffer, to: speechFormat)
    }
}
