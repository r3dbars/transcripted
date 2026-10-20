import Foundation
import Accelerate
@preconcurrency import AVFoundation

/// Real-time automatic gain control for the meeting mic capture path.
///
/// Replaces the system-wide ducking side effect of Apple's
/// `setVoiceProcessingEnabled(true)` (VPIO / AUVoiceProcessingIO) for the
/// recording-only path. VPIO puts macOS into "voice communication" mode and
/// ducks audio output from other apps (e.g. Zoom playback gets quiet); a
/// recorder doesn't need that.
///
/// This class boosts attenuated mic streams (issue #500: Safari/Firefox
/// WebRTC contention can hand us a quiet shared-device stream) using a
/// peak-tracking AGC: rolling window of recent buffer peaks → target gain
/// `targetPeak / windowPeak`, clamped → smoothed via one-pole IIR with a
/// fast attack (lower gain quickly to avoid clipping on a sudden loud word)
/// and slow release (raise gain gradually to avoid audible pumping during
/// quiet stretches).
///
/// The default tuning (`targetPeak = 0.45`, `maxGain = 25.0`,
/// `minPeak = 0.0008`, `noiseGatePeak = 0.002`) gives the live mic copy enough
/// headroom for the more severe issue #500 voice-processing attenuation case
/// while still refusing to turn USB-mic idle hiss into saved speech-looking
/// audio. The post-processing path can normalize again before final
/// transcription; this real-time pass protects the saved WAV, borrowed-mic
/// dictation, and diagnostics without touching system audio.
///
/// Real-time safe: `process(buffer:)` performs zero allocations and no
/// locking. Safe to invoke from an `AVAudioEngine` tap callback.
public final class RealtimeAGC {

    // MARK: - Tunables

    /// Target peak amplitude. Gain ramps so the windowed peak lands here.
    public let targetPeak: Float

    /// Maximum gain we'll ever apply. Caps boost to avoid amplifying
    /// background noise on truly silent input.
    public let maxGain: Float

    /// Below this peak the input is treated as silence; current gain holds
    /// rather than dropping back to 1.0. Prevents pumping during pauses.
    public let minPeak: Float

    /// Below this raw peak, the buffer is treated as ambient idle noise and
    /// muted before gain is applied. This stays below the quiet-speech band
    /// used by issue #500 detection, but keeps held max gain from amplifying
    /// Blue Yeti-style USB mic self-noise during pauses.
    public let noiseGatePeak: Float

    /// Number of peak slots in the window. Each slot covers about
    /// `bufferTimeMs` of audio whatever the buffer size, so 16 × 85 ms ≈
    /// 1.4 s of history — long enough to ride past a single transient,
    /// short enough to track when WebRTC contention starts and stops
    /// mid-recording.
    public let windowSize: Int

    /// Gain smoothing time constants and peak-slot duration, in seconds.
    /// The per-buffer coefficient comes from each buffer's real duration,
    /// because the pinned recorder delivers ~10 ms buffers and the engine
    /// tap ~85 ms ones.
    private let attackTime: Float
    private let releaseTime: Float
    private let slotDuration: Float

    // MARK: - State

    private var recentPeaks: [Float]
    private var nextPeakIndex: Int = 0
    private var slotElapsed: Float = 0
    private var currentGain: Float = 1.0

    // MARK: - Init

    /// - Parameters:
    ///   - targetPeak: Desired peak after gain. 0.45 leaves headroom under 1.0.
    ///   - maxGain: Upper bound on applied gain. 25.0 lets a very quiet
    ///     but real shared-device mic stream reach the usable diagnostic bar
    ///     without opting into Apple's system-wide voice-processing ducking.
    ///   - minPeak: Silence threshold for hold behavior. 0.0008 matches
    ///     AudioSignalRecovery's lower bound for WebRTC-attenuated input.
    ///   - noiseGatePeak: Raw idle-noise threshold. 0.002 matches the
    ///     activity floor used by `QuietMicAttenuationDetector`; values below
    ///     this are not treated as voice-like input.
    ///   - windowSize: Slots of peak history, each `bufferTimeMs` long.
    ///   - attackTimeMs: Time constant for *reducing* gain when input
    ///     suddenly grows. Fast attack avoids clipping. 20ms.
    ///   - releaseTimeMs: Time constant for *raising* gain when input
    ///     stays quiet. Slow release avoids audible pumping. 300ms.
    ///   - bufferTimeMs: Duration of one peak-window slot in milliseconds.
    ///     85ms matches one 4096-frame engine tap buffer at 48 kHz; smaller
    ///     buffers share a slot until it holds this much audio.
    public init(
        targetPeak: Float = 0.45,
        maxGain: Float = 25.0,
        minPeak: Float = 0.0008,
        noiseGatePeak: Float = 0.002,
        windowSize: Int = 16,
        attackTimeMs: Float = 20,
        releaseTimeMs: Float = 300,
        bufferTimeMs: Float = 85
    ) {
        self.targetPeak = max(0.0001, min(1.0, targetPeak))
        self.maxGain = max(1.0, maxGain)
        self.minPeak = max(0.000001, minPeak)
        self.noiseGatePeak = max(self.minPeak, noiseGatePeak)
        self.windowSize = max(1, windowSize)
        self.recentPeaks = [Float](repeating: 0, count: max(1, windowSize))
        self.attackTime = max(0.1, attackTimeMs) / 1000
        self.releaseTime = max(0.1, releaseTimeMs) / 1000
        self.slotDuration = max(0.001, bufferTimeMs) / 1000
    }

    // MARK: - Public API

    /// Current applied gain. Diagnostic only; do not use for control.
    public var appliedGain: Float { currentGain }

    /// Reset state. Call when the engine restarts or the device changes so
    /// gain history doesn't leak across captures.
    public func reset() {
        for index in recentPeaks.indices {
            recentPeaks[index] = 0
        }
        nextPeakIndex = 0
        slotElapsed = 0
        currentGain = 1.0
    }

    /// Apply AGC to `buffer` in place. Real-time safe.
    ///
    /// Process per-buffer: compute this buffer's peak, slot it into a
    /// rolling window, derive a target gain from the windowed peak,
    /// smooth toward that target with attack/release coefficients, multiply
    /// the buffer by the smoothed gain, and hard-clip to `[-1, 1]`.
    public func process(buffer: AVAudioPCMBuffer) {
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return }
        let sampleRate = Float(buffer.format.sampleRate)
        guard sampleRate > 0 else { return }
        let bufferTime = Float(buffer.frameLength) / sampleRate

        // 1. Buffer peak across all channels (vDSP_maxmgv = max |x|).
        var bufferPeak: Float = 0
        if buffer.format.isInterleaved {
            // Interleaved: a single buffer of length frameCount * channelCount.
            let totalLength = vDSP_Length(buffer.frameLength) * vDSP_Length(channelCount)
            var p: Float = 0
            vDSP_maxmgv(channelData[0], 1, &p, totalLength)
            bufferPeak = p
        } else {
            for ch in 0..<channelCount {
                var p: Float = 0
                vDSP_maxmgv(channelData[ch], 1, &p, frameCount)
                if p > bufferPeak { bufferPeak = p }
            }
        }

        // 2. Gate sub-activity ambient noise before it can be amplified.
        // Keep the gain state steady so the next real utterance still starts
        // from the current recovery level instead of pumping up from unity.
        if bufferPeak > 0, bufferPeak < noiseGatePeak {
            clear(buffer: buffer, frameCount: frameCount, channelCount: channelCount)
            recordPeak(0, duration: bufferTime)
            return
        }

        // 3. Slot into rolling peak window and pick window peak.
        recordPeak(bufferPeak, duration: bufferTime)
        var windowPeak: Float = 0
        for value in recentPeaks {
            if value > windowPeak { windowPeak = value }
        }

        // 4. Target gain. Hold during silence so a long pause doesn't make
        // gain race back to 1.0 and then jump up again on the next word.
        let targetGain: Float
        if windowPeak < minPeak {
            targetGain = currentGain
        } else {
            targetGain = max(1.0, min(maxGain, targetPeak / windowPeak))
        }

        // 5. Smooth gain via one-pole IIR. Fast when reducing (attack),
        // slow when raising (release). α = 1 − exp(−Δt / τ).
        let timeConstant = (targetGain < currentGain) ? attackTime : releaseTime
        let coef = 1.0 - expf(-bufferTime / timeConstant)
        currentGain = currentGain + coef * (targetGain - currentGain)

        // 6. Apply gain in place. vDSP_vsmul works for both interleaved
        // (treat as a single contiguous block) and non-interleaved (per
        // channel pointer).
        var gain = currentGain
        if buffer.format.isInterleaved {
            let totalLength = vDSP_Length(buffer.frameLength) * vDSP_Length(channelCount)
            vDSP_vsmul(channelData[0], 1, &gain, channelData[0], 1, totalLength)
        } else {
            for ch in 0..<channelCount {
                vDSP_vsmul(channelData[ch], 1, &gain, channelData[ch], 1, frameCount)
            }
        }

        // 7. Hard-clip to [-1, 1]. With targetPeak = 0.45 and a maxGain of
        // 25.0 we shouldn't exceed unity often; this is a safety net for
        // transients above the windowed peak.
        var lo: Float = -1.0
        var hi: Float = 1.0
        if buffer.format.isInterleaved {
            let totalLength = vDSP_Length(buffer.frameLength) * vDSP_Length(channelCount)
            vDSP_vclip(channelData[0], 1, &lo, &hi, channelData[0], 1, totalLength)
        } else {
            for ch in 0..<channelCount {
                vDSP_vclip(channelData[ch], 1, &lo, &hi, channelData[ch], 1, frameCount)
            }
        }
    }

    /// Max `peak` into the current slot; move to the next slot once this one
    /// holds `slotDuration` of audio, so window length doesn't depend on
    /// buffer size.
    private func recordPeak(_ peak: Float, duration: Float) {
        if slotElapsed == 0 {
            recentPeaks[nextPeakIndex] = peak
        } else if peak > recentPeaks[nextPeakIndex] {
            recentPeaks[nextPeakIndex] = peak
        }
        slotElapsed += duration
        if slotElapsed >= slotDuration {
            nextPeakIndex = (nextPeakIndex + 1) % recentPeaks.count
            slotElapsed = 0
        }
    }

    private func clear(buffer: AVAudioPCMBuffer, frameCount: vDSP_Length, channelCount: Int) {
        guard let channelData = buffer.floatChannelData else { return }
        if buffer.format.isInterleaved {
            let totalLength = frameCount * vDSP_Length(channelCount)
            vDSP_vclr(channelData[0], 1, totalLength)
        } else {
            for ch in 0..<channelCount {
                vDSP_vclr(channelData[ch], 1, frameCount)
            }
        }
    }
}
