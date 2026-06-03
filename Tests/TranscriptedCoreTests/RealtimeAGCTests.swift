import XCTest
import AVFoundation
@testable import TranscriptedCore

final class RealtimeAGCTests: XCTestCase {

    // MARK: - Helpers

    /// Build a non-interleaved mono Float32 buffer with the given samples.
    private func makeMonoBuffer(samples: [Float], sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for (index, sample) in samples.enumerated() {
            channelData[index] = sample
        }
        return buffer
    }

    /// Build a non-interleaved stereo Float32 buffer with different channel peaks.
    private func makeStereoBuffer(leftPeak: Float, rightPeak: Float, frames: Int = 4096, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        let twoPiF = 2.0 * Double.pi * 1_000.0
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            left[i] = leftPeak * Float(sin(twoPiF * t))
            right[i] = rightPeak * Float(sin(twoPiF * t))
        }
        return buffer
    }

    /// Read samples back out of a mono buffer.
    private func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        return (0..<count).map { channelData[$0] }
    }

    /// Buffer peak (max |x|).
    private func peak(of samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    private func peak(of buffer: AVAudioPCMBuffer, channel: Int) -> Float {
        let count = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData?[channel] else { return 0 }
        var result: Float = 0
        for index in 0..<count {
            result = max(result, abs(channelData[index]))
        }
        return result
    }

    /// Generate a 1 kHz sine at the given peak amplitude. Defaults match
    /// our typical 4096-frame tap callback at 48 kHz.
    private func sineSamples(peak: Float, frames: Int = 4096, sampleRate: Double = 48_000, frequency: Double = 1_000) -> [Float] {
        let twoPiF = 2.0 * Double.pi * frequency
        return (0..<frames).map { i in
            let t = Double(i) / sampleRate
            return peak * Float(sin(twoPiF * t))
        }
    }

    // MARK: - Tests

    func testAttenuatedInputRampsUpToTargetPeak() {
        // Simulate the moderate-attenuation case from issue #500's test
        // fixture (DictationAudioRecoveryTests uses 0.018 peak). With
        // targetPeak 0.45 and maxGain 12, this lets the AGC reach the
        // target without hitting the gain ceiling, so we can assert the
        // output actually lands near 0.45.
        let agc = RealtimeAGC()
        var lastPeak: Float = 0
        for _ in 0..<32 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.04))
            agc.process(buffer: buffer)
            lastPeak = peak(of: samples(from: buffer))
        }
        // After ramp-up, output peak should land near the 0.45 target.
        XCTAssertGreaterThan(lastPeak, 0.40, "AGC should boost attenuated input toward target peak")
        XCTAssertLessThanOrEqual(lastPeak, 0.50, "AGC should not overshoot beyond ~target")
    }

    func testGainCappedAtMaxGain() {
        // Input far below silence floor stays at silence-hold (gain=1).
        // Input that needs more than maxGain to reach target stays clamped:
        // peak 0.01 wants 45x gain, we cap at 12x → peak ≈ 0.12 after ramp.
        let agc = RealtimeAGC(maxGain: 12.0)
        var lastPeak: Float = 0
        for _ in 0..<32 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.01))
            agc.process(buffer: buffer)
            lastPeak = peak(of: samples(from: buffer))
        }
        XCTAssertLessThanOrEqual(lastPeak, 0.13, "AGC should respect maxGain cap")
        XCTAssertGreaterThan(lastPeak, 0.05, "AGC should still apply some boost at the cap")
        XCTAssertLessThanOrEqual(agc.appliedGain, 12.0 + 0.001, "appliedGain should not exceed maxGain")
    }

    func testIssue500VeryQuietMicReachesUsableProcessedPeak() {
        // Issue #500 voice-processing attenuation can be quieter than the
        // original scalar-drop case. At the old 12x default cap, a 0.005 peak
        // stayed below the 0.12 processed-peak diagnostics bar and still looked
        // unrecovered. The default realtime path should now cross that bar
        // without opting into Apple VPIO.
        let agc = RealtimeAGC()
        var lastPeak: Float = 0
        for _ in 0..<32 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.005))
            agc.process(buffer: buffer)
            lastPeak = peak(of: samples(from: buffer))
        }

        XCTAssertGreaterThanOrEqual(lastPeak, 0.12, "Severely attenuated issue #500 mic input should become diagnostically usable")
        XCTAssertLessThanOrEqual(lastPeak, 0.14, "Default cap should avoid a large overshoot for very quiet input")
        XCTAssertLessThanOrEqual(agc.appliedGain, 25.0 + 0.001, "default appliedGain should respect the raised cap")
    }

    func testNormalLevelInputPassesThrough() {
        // Speech already at the target peak should not be amplified or
        // attenuated meaningfully — gain stays near 1.0.
        let agc = RealtimeAGC()
        let originalPeak: Float = 0.45
        for _ in 0..<8 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: originalPeak))
            agc.process(buffer: buffer)
        }
        XCTAssertEqual(agc.appliedGain, 1.0, accuracy: 0.05, "Already-loud input should leave gain near 1.0")
    }

    func testLoudInputGainPulledBelowUnityNeverHappens() {
        // Loud (>target) input should leave gain at 1.0, not below — the
        // AGC is never a downward limiter (we hard-clip instead).
        let agc = RealtimeAGC()
        for _ in 0..<8 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.9))
            agc.process(buffer: buffer)
        }
        XCTAssertGreaterThanOrEqual(agc.appliedGain, 1.0 - 0.0001, "Gain should never drop below 1.0")
    }

    func testSilenceHoldsCurrentGainNoPumping() {
        // Build up gain on attenuated speech, then feed enough silence to
        // completely drain the rolling peak window (windowSize=16), so the
        // silence-hold path actually engages. After it does, gain must
        // hold steady — that's the no-pumping invariant.
        let agc = RealtimeAGC()
        for _ in 0..<32 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.005))
            agc.process(buffer: buffer)
        }
        XCTAssertGreaterThan(agc.appliedGain, 5.0, "Should have built up significant gain on attenuated input")

        // First fill the window fully with silence so windowPeak drops
        // below minPeak and silence-hold takes over.
        let silentSamples = [Float](repeating: 0.0, count: 4096)
        for _ in 0..<24 {
            let buffer = makeMonoBuffer(samples: silentSamples)
            agc.process(buffer: buffer)
        }

        // Now sample the gain after silence-hold has fully engaged, and
        // verify it doesn't continue to drift across many more silent
        // buffers (the actual no-pumping property).
        let heldGain = agc.appliedGain
        for _ in 0..<32 {
            let buffer = makeMonoBuffer(samples: silentSamples)
            agc.process(buffer: buffer)
        }
        XCTAssertEqual(agc.appliedGain, heldGain, accuracy: 0.0001,
                       "Once silence-hold engages, gain must be exactly steady to avoid pumping the next utterance")
    }

    func testResetReturnsGainToUnity() {
        let agc = RealtimeAGC()
        for _ in 0..<32 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.005))
            agc.process(buffer: buffer)
        }
        XCTAssertGreaterThan(agc.appliedGain, 5.0)

        agc.reset()
        XCTAssertEqual(agc.appliedGain, 1.0, accuracy: 0.0001, "reset() should return gain to 1.0")
    }

    func testEmptyBufferDoesNotCrash() {
        let agc = RealtimeAGC()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 0  // explicitly empty
        agc.process(buffer: buffer)
        XCTAssertEqual(agc.appliedGain, 1.0, accuracy: 0.0001, "Empty buffer should be a no-op")
    }

    func testLoudTransientHardClippedBelowOne() {
        // Single very loud buffer should not produce out-of-range samples
        // even before the attack ramp catches up.
        let agc = RealtimeAGC()
        // Prime with attenuated input so gain is high.
        for _ in 0..<32 {
            let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.005))
            agc.process(buffer: buffer)
        }
        // Now hit it with a moderately loud buffer; the cached gain (~12x)
        // would push samples past 1.0 without clipping.
        let buffer = makeMonoBuffer(samples: sineSamples(peak: 0.2))
        agc.process(buffer: buffer)
        let outputPeak = peak(of: samples(from: buffer))
        XCTAssertLessThanOrEqual(outputPeak, 1.0001, "Output samples must be hard-clipped to [-1, 1]")
    }

    func testInterleavedStereoBufferProcessedInPlace() {
        // Interleaved stereo should receive uniform gain across channels.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let frameCount = AVAudioFrameCount(4096)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        // Fill with a 0.005 peak signal across both channels.
        let interleaved = buffer.floatChannelData![0]
        let twoPiF = 2.0 * Double.pi * 1_000.0
        for i in 0..<Int(frameCount) {
            let t = Double(i) / 48_000.0
            let value = Float(0.005 * sin(twoPiF * t))
            interleaved[i * 2] = value
            interleaved[i * 2 + 1] = value
        }

        let agc = RealtimeAGC()
        // Run a handful of buffers worth to ramp up gain.
        for _ in 0..<32 {
            let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            copy.frameLength = frameCount
            let src = buffer.floatChannelData![0]
            let dst = copy.floatChannelData![0]
            memcpy(dst, src, Int(frameCount) * 2 * MemoryLayout<Float>.size)
            agc.process(buffer: copy)
        }

        // Process the original buffer one more time and inspect both channels.
        agc.process(buffer: buffer)
        let interleavedOut = buffer.floatChannelData![0]
        var maxLeft: Float = 0
        var maxRight: Float = 0
        for i in 0..<Int(frameCount) {
            maxLeft = max(maxLeft, abs(interleavedOut[i * 2]))
            maxRight = max(maxRight, abs(interleavedOut[i * 2 + 1]))
        }
        XCTAssertEqual(maxLeft, maxRight, accuracy: 0.001, "Interleaved channels should receive identical gain")
        XCTAssertGreaterThan(maxLeft, 0.04, "Interleaved stereo should also be boosted")
    }

    func testNonInterleavedStereoUsesLoudestChannelForSharedGain() {
        // Meeting mic buffers are commonly non-interleaved. A channel scan
        // regression here can make one quiet channel drive huge gain and clip
        // the louder channel, which looks like a channel/gain issue #500.
        let agc = RealtimeAGC()
        var finalBuffer: AVAudioPCMBuffer?
        for _ in 0..<40 {
            let buffer = makeStereoBuffer(leftPeak: 0.03, rightPeak: 0.30)
            agc.process(buffer: buffer)
            finalBuffer = buffer
        }

        let buffer = finalBuffer!
        let leftPeak = peak(of: buffer, channel: 0)
        let rightPeak = peak(of: buffer, channel: 1)

        XCTAssertGreaterThan(rightPeak, 0.40, "Louder channel should land near the AGC target peak")
        XCTAssertLessThan(rightPeak, 0.55, "Louder channel should not clip because a quieter sibling channel drove gain")
        XCTAssertGreaterThan(leftPeak, 0.035, "Quiet sibling channel should receive the same shared gain")
        XCTAssertLessThan(leftPeak, 0.07, "Quiet sibling channel should not get independent over-boost")
        XCTAssertEqual(leftPeak / rightPeak, 0.10, accuracy: 0.02, "Shared gain should preserve the stereo channel ratio")
    }
}
