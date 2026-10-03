import AVFoundation
import Foundation

// Expected values come from the existing per-buffer meter run over one buffer
// that holds the same samples, never from the window itself.

private let windowTestSampleRate: Double = 48_000
private let windowTestTolerance: Float = 1e-4

/// A non-interleaved Float32 buffer whose channel `c` holds `channels[c]`.
private func makeWindowTestBuffer(_ channels: [[Float]], capacity: Int? = nil) -> AVAudioPCMBuffer {
    let frames = channels.first?.count ?? 0
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: windowTestSampleRate,
        channels: AVAudioChannelCount(channels.count),
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, capacity ?? frames)))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData!
    for (channel, samples) in channels.enumerated() {
        for (frame, sample) in samples.enumerated() {
            data[channel][frame] = sample
        }
    }
    return buffer
}

/// Mono samples alternating +amplitude / -amplitude, so the RMS is `amplitude`.
private func toneSamples(_ amplitude: Float, frames: Int = 480) -> [Float] {
    (0..<frames).map { $0 % 2 == 0 ? amplitude : -amplitude }
}

private func monoBuffer(_ amplitude: Float, frames: Int = 480) -> AVAudioPCMBuffer {
    makeWindowTestBuffer([toneSamples(amplitude, frames: frames)])
}

/// The existing meter's level for all of these channel arrays played back to back.
private func meterLevel(ofConcatenated pieces: [[[Float]]]) -> Float {
    let channelCount = pieces[0].count
    let joined = (0..<channelCount).map { channel in pieces.flatMap { $0[channel] } }
    return DictationAudioLevelMeter.normalizedLevel(from: makeWindowTestBuffer(joined))
}

private func monoMeterLevel(_ amplitudes: [Float], frames: Int = 480) -> Float {
    meterLevel(ofConcatenated: amplitudes.map { [toneSamples($0, frames: frames)] })
}

private func assertClose(_ actual: Float?, _ expected: Float, _ message: String, file: String = #file, line: Int = #line) {
    guard let actual else {
        assertTrue(false, "\(message): expected \(expected), got nil", file: file, line: line)
        return
    }
    assertTrue(abs(actual - expected) <= windowTestTolerance, "\(message): expected \(expected), got \(actual)", file: file, line: line)
}

/// Feeds every buffer and returns what each add returned.
private func feed(_ window: DictationAudioLevelWindow, _ buffers: [AVAudioPCMBuffer]) -> [DictationAudioLevel?] {
    buffers.map { window.add($0) }
}

func testDictationAudioLevelWindow() {
    runSuite("The meter counts every buffer since the last reading, not one sampled buffer") {
        let amplitudes: [Float] = [0.01, 0.03, 0.1, 0.2]
        let window = DictationAudioLevelWindow()
        let results = feed(window, amplitudes.map { monoBuffer($0) })

        assertNil(results[0], "10 ms of audio is not a full reading yet")
        assertNil(results[1], "20 ms of audio is not a full reading yet")
        assertNil(results[2], "30 ms of audio is not a full reading yet")
        let reading = results[3]
        let expected = monoMeterLevel(amplitudes)
        assertClose(reading?.level, expected, "reading should be the level of all four buffers together")
        for amplitude in amplitudes {
            let single = monoMeterLevel([amplitude])
            assertTrue(abs((reading?.level ?? single) - single) > 0.01, "reading should not be just the \(amplitude) buffer's level (\(single))")
        }
    }

    runSuite("Readings come once per 1/30 s of audio") {
        let tenMillisecond = DictationAudioLevelWindow()
        let tenMsResults = feed(tenMillisecond, (0..<100).map { monoBuffer(Float($0 % 7 + 1) / 20, frames: 480) })
        let tenMsReadingIndexes = tenMsResults.indices.filter { tenMsResults[$0] != nil }
        assertEqual(tenMsReadingIndexes.count, 25, "1 s of 10 ms buffers should give 25 readings")
        assertEqual(tenMsReadingIndexes, Array(stride(from: 3, to: 100, by: 4)), "a reading should come on every 4th 10 ms buffer")

        let largeBuffers = DictationAudioLevelWindow()
        let largeResults = feed(largeBuffers, (0..<46).map { monoBuffer(Float($0 % 5 + 1) / 20, frames: 1024) })
        let largeReadingIndexes = largeResults.indices.filter { largeResults[$0] != nil }
        assertEqual(largeReadingIndexes, Array(stride(from: 1, to: 46, by: 2)), "a reading should come on every 2nd 1024-frame buffer")
    }

    runSuite("A steady sound reads the same as the old per-buffer meter (calibration unchanged)") {
        for amplitude: Float in [0.01, 0.05, 0.1, 0.3] {
            let window = DictationAudioLevelWindow()
            let buffers = (0..<4).map { _ in monoBuffer(amplitude) }
            let reading = feed(window, buffers)[3]
            let oldMeter = DictationAudioLevelMeter.normalizedLevel(from: buffers[0])
            assertClose(reading?.level, oldMeter, "steady \(amplitude) level should match the per-buffer meter")
            assertClose(reading?.peak, oldMeter, "steady \(amplitude) peak should match its level")
        }

        // The scale itself: 0.1 RMS is -20 dB, which sits at 30/44 between -50 dB and -6 dB.
        let reading = feed(DictationAudioLevelWindow(), (0..<4).map { _ in monoBuffer(0.1) })[3]
        assertClose(reading?.level, 30.0 / 44.0, "a -20 dB tone should read 30/44 on the -50...-6 dB scale")
    }

    runSuite("A short loud buffer between quiet ones still shows at full height in the peak") {
        let quiet: Float = 0.01
        let loud: Float = 0.3
        let reading = feed(DictationAudioLevelWindow(), [quiet, loud, quiet, quiet].map { monoBuffer($0) })[3]
        let loudAlone = monoMeterLevel([loud])
        let quietAlone = monoMeterLevel([quiet])

        assertClose(reading?.peak, loudAlone, "peak should be the loud buffer's own level")
        assertClose(reading?.level, monoMeterLevel([quiet, loud, quiet, quiet]), "level should cover all four buffers")
        if let reading {
            assertTrue(reading.level > quietAlone, "the loud buffer should lift the level above the quiet level")
            assertTrue(reading.level < reading.peak, "the quiet buffers should keep the level below the peak")
        }
    }

    runSuite("Consecutive readings neither overlap nor skip audio") {
        let loud: Float = 0.2
        let quiet: Float = 0.02
        let window = DictationAudioLevelWindow()
        let results = feed(window, (0..<4).map { _ in monoBuffer(loud) } + (0..<4).map { _ in monoBuffer(quiet) })
        let readings = results.compactMap { $0 }

        assertEqual(readings.count, 2, "8 x 10 ms should give two readings")
        assertNotNil(results[3], "first reading on the 4th buffer")
        assertNotNil(results[7], "second reading on the 8th buffer")
        assertClose(results[3]?.level, monoMeterLevel([loud]), "first reading should be only the loud audio")
        assertClose(results[3]?.peak, monoMeterLevel([loud]), "first reading's peak should be only the loud audio")
        assertClose(results[7]?.level, monoMeterLevel([quiet]), "second reading should be only the quiet audio")
        assertClose(results[7]?.peak, monoMeterLevel([quiet]), "second reading's peak should not carry the loud audio")
    }

    runSuite("Silence reads zero, and an empty buffer adds nothing") {
        let silentReading = feed(DictationAudioLevelWindow(), (0..<4).map { _ in monoBuffer(0) })[3]
        assertEqual(silentReading?.level, 0, "silence should read level 0")
        assertEqual(silentReading?.peak, 0, "silence should read peak 0")

        let window = DictationAudioLevelWindow()
        let empty = makeWindowTestBuffer([[]], capacity: 4_800)
        assertNil(window.add(empty), "an empty buffer should not produce a reading")
        let firstThree = feed(window, [0.05, 0.1, 0.2].map { monoBuffer($0) })
        assertTrue(firstThree.allSatisfy { $0 == nil }, "30 ms of audio is not a full reading yet")
        for _ in 0..<20 {
            assertNil(window.add(empty), "empty buffers should not push the window to a reading")
        }
        let reading = window.add(monoBuffer(0.4))
        assertClose(reading?.level, monoMeterLevel([0.05, 0.1, 0.2, 0.4]), "empty buffers should add no samples to the reading")
        assertClose(reading?.peak, monoMeterLevel([0.4]), "empty buffers should not change the peak")
    }

    runSuite("Stereo energy isn't cancelled by channel phase") {
        let left = toneSamples(0.3)
        let right = left.map { -$0 }
        let window = DictationAudioLevelWindow()
        let reading = feed(window, (0..<4).map { _ in makeWindowTestBuffer([left, right]) })[3]

        assertTrue((reading?.level ?? 0) > 0.5, "opposite-phase stereo should still read loud")
        assertClose(reading?.level, meterLevel(ofConcatenated: Array(repeating: [left, right], count: 4)), "stereo level should match the per-buffer meter")
    }
}
