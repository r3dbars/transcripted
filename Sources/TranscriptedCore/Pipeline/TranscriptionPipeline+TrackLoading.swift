import Foundation
import Accelerate

/// How loud the local mic was in each 100 ms frame of a meeting. The system
/// phase reads it to down-weight remote voiceprints taken while the local user
/// was talking (their voice echoes into the call track). Small enough to keep
/// for the whole job, so the whole-meeting mic buffer doesn't have to be.
struct MeetingMicActivity: Sendable {
    static let frameDuration = 0.1  // 100ms frames

    let energyPerFrame: [Float]
    let activeThreshold: Float

    nonisolated init(samples: [Float], analysis: AudioSignalAnalysis?) {
        let frameSize = Int(16000.0 * Self.frameDuration)  // 1600 samples
        let frameCount = samples.count / frameSize
        var energy = [Float](repeating: 0, count: frameCount)

        samples.withUnsafeBufferPointer { ptr in
            // Security: guard against nil baseAddress (empty buffer) before pointer arithmetic
            guard let baseAddr = ptr.baseAddress else { return }
            for i in 0..<frameCount {
                let start = i * frameSize
                var sumSquares: Float = 0
                vDSP_dotpr(baseAddr + start, 1,
                           baseAddr + start, 1,
                           &sumSquares,
                           vDSP_Length(frameSize))
                energy[i] = sqrt(sumSquares / Float(frameSize))
            }
        }
        energyPerFrame = energy
        activeThreshold = AudioSignalRecovery.speechDetectionThreshold(
            for: analysis ?? AudioSignalRecovery.analyze(samples: [], sampleRate: 16000)
        )
    }

    /// Returns the fraction of a time range where the local mic was active (0.0-1.0).
    nonisolated func activeFraction(startTime: Double, endTime: Double) -> Double {
        let startFrame = max(0, Int(startTime / Self.frameDuration))
        let endFrame = min(energyPerFrame.count, Int(endTime / Self.frameDuration))
        guard endFrame > startFrame else { return 0 }
        var activeCount = 0
        for i in startFrame..<endFrame where energyPerFrame[i] >= activeThreshold { activeCount += 1 }
        return Double(activeCount) / Double(endFrame - startFrame)
    }
}

extension Transcription {

    /// Whether the default (single "You") mic path can drop its whole-meeting
    /// 16 kHz buffer (~230 MB per hour) while the call track is diarized and
    /// transcribed, and load it again for the mic phase. Split mode and
    /// engines that scan both tracks for language windows still need the mic
    /// buffer during the system phase, so they keep today's single load.
    nonisolated static func releasesMicDuringSystemPhase(
        micURL: URL?,
        splitLocalSpeakers: Bool,
        wantsLanguageSamples: Bool
    ) -> Bool {
        micURL != nil && !splitLocalSpeakers && !wantsLanguageSamples
    }

    /// Unpacks the call-track load. A failure is kept, not thrown: a damaged
    /// or empty remote track must not erase a valid local conversation, and
    /// the too-short check routes to the mic-only pipeline when the mic is
    /// usable.
    nonisolated static func systemTrack(
        from loadResult: Result<[Float], Error>?
    ) -> (samples: [Float], loadError: Error?) {
        do {
            return (try loadResult?.get() ?? [], nil)
        } catch {
            AppLogger.transcription.warning("System audio could not be loaded; will fall back to microphone-only if usable", [
                "fallback": "microphone_only"
            ])
            return ([], error)
        }
    }

    /// Unpacks the mic-track load. A damaged/empty local track must not erase
    /// a valid remote conversation: keep the artifact for retry, but run the
    /// transcription as system-audio-only partial success.
    nonisolated static func micTrack(
        from loadResult: Result<[Float], Error>?
    ) -> (samples: [Float], outcome: TranscriptionResult.MicrophoneAudioOutcome) {
        guard let loadResult else { return ([], .notProvided) }
        do {
            let samples = try loadResult.get()
            return (samples, samples.isEmpty ? .unusable : .usable)
        } catch {
            AppLogger.transcription.warning("Microphone audio could not be loaded; continuing with system audio", [
                "fallback": "system_audio_only"
            ])
            return ([], .unusable)
        }
    }

    /// Measures the loaded mic track and empties it (marking it unusable) when
    /// it has no usable capture signal. Returns the analysis of the samples
    /// that remain, or nil when none do.
    nonisolated static func screenMicCaptureSignal(
        micURL: URL?,
        samples micSamples: inout [Float],
        outcome microphoneAudioOutcome: inout TranscriptionResult.MicrophoneAudioOutcome
    ) -> AudioSignalAnalysis? {
        guard micURL != nil, !micSamples.isEmpty else { return nil }
        let rawMicAnalysis = AudioSignalRecovery.analyze(samples: micSamples, sampleRate: 16000)
        var context = rawMicAnalysis.context
        context["suggested_gain"] = String(format: "%.2f", AudioSignalRecovery.normalizationGain(for: rawMicAnalysis))
        AppLogger.transcription.info("Analyzed meeting mic signal", context)
        if AudioSignalRecovery.hasUsableCaptureSignal(samples: micSamples, sampleRate: 16000) {
            return rawMicAnalysis
        }
        context["fallback"] = "system_audio_only"
        AppLogger.transcription.warning("Microphone artifact had no usable capture signal; continuing with system audio", context)
        micSamples = []
        microphoneAudioOutcome = .unusable
        return nil
    }

    /// Loads the mic track again for the mic phase after it was released
    /// during the system phase. Same file, same resampler, so it is the same
    /// buffer the earlier analysis measured; a mismatch is only logged
    /// (`detectSpeechSegments` re-analyzes when the lengths differ).
    nonisolated static func reloadReleasedMicTrack(url: URL, expectedSampleCount: Int) throws -> [Float] {
        let samples = try AudioResampler.loadAndResample(url: url, targetRate: 16000)
        if samples.count != expectedSampleCount {
            AppLogger.transcription.warning("Reloaded microphone audio length changed", [
                "expectedSamples": "\(expectedSampleCount)",
                "samples": "\(samples.count)"
            ])
        }
        return samples
    }
}
