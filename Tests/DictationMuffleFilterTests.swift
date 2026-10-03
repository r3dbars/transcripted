import CoreAudio
import Foundation

func testDictationMuffleFilter() {
    let sampleRate = 48_000.0
    let rampFrames = Int((DictationMuffleFilter.rampSeconds * sampleRate).rounded(.up))

    runSuite("With muffle off, the filter passes audio through untouched") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        var maxError: Float = 0
        var maxMix: Float = 0
        for frame in 0..<4_800 {
            let left = Float(sin(Double(frame) * 0.37)) * 0.8
            let right = Float(cos(Double(frame) * 1.91)) * 0.5
            let (outLeft, outRight) = filter.process(left: left, right: right, target: 0)
            maxError = max(maxError, abs(outLeft - left), abs(outRight - right))
            maxMix = max(maxMix, filter.mix)
        }
        assertTrue(maxError <= 1e-6, "target 0 should leave samples unchanged, max error \(maxError)")
        assertEqual(maxMix, 0, "mix should stay 0 while target is 0")
    }

    runSuite("Fully muffled, high frequencies are cut hard") {
        let ratios = muffledRMSRatio(frequencyHz: 5_000, sampleRate: sampleRate)
        assertTrue(ratios.left < 0.05, "5 kHz left should drop below 5% of input RMS, got \(ratios.left)")
        assertTrue(ratios.right < 0.05, "5 kHz right should drop below 5% of input RMS, got \(ratios.right)")
    }

    runSuite("Fully muffled, low frequencies keep most of their level") {
        let ratios = muffledRMSRatio(frequencyHz: 100, sampleRate: sampleRate)
        let expected = DictationMuffleFilter.wetGain
        let tolerance: Float = 0.1
        assertTrue(abs(ratios.left - expected) <= tolerance, "100 Hz left should sit near wetGain \(expected), got \(ratios.left)")
        assertTrue(abs(ratios.right - expected) <= tolerance, "100 Hz right should sit near wetGain \(expected), got \(ratios.right)")
    }

    runSuite("Muffle fades in gradually over rampSeconds instead of jumping") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        _ = filter.process(left: 0.1, right: 0.1, target: 1)
        assertTrue(filter.mix > 0, "mix should start moving after one frame, got \(filter.mix)")
        assertTrue(filter.mix < 0.01, "mix should still be near 0 after one frame, got \(filter.mix)")

        for _ in 1..<(rampFrames / 2) {
            _ = filter.process(left: 0.1, right: 0.1, target: 1)
        }
        assertTrue(filter.mix > 0.25 && filter.mix < 0.75, "mix should be partway at half the ramp, got \(filter.mix)")

        for _ in (rampFrames / 2)..<(rampFrames + 2) {
            _ = filter.process(left: 0.1, right: 0.1, target: 1)
        }
        assertTrue(abs(filter.mix - 1) < 1e-3, "mix should reach 1 after rampSeconds of frames, got \(filter.mix)")

        for _ in 0..<1_000 {
            _ = filter.process(left: 0.1, right: 0.1, target: 1)
        }
        assertTrue(filter.mix <= 1, "mix should never overshoot 1, got \(filter.mix)")
    }

    runSuite("Muffle fades back out gradually when the target returns to 0") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        for _ in 0..<(rampFrames * 2) {
            _ = filter.process(left: 0.1, right: 0.1, target: 1)
        }
        assertTrue(abs(filter.mix - 1) < 1e-3, "precondition: fully muffled, got \(filter.mix)")

        _ = filter.process(left: 0.1, right: 0.1, target: 0)
        assertTrue(filter.mix < 1, "mix should start falling after one frame, got \(filter.mix)")
        assertTrue(filter.mix > 0.99, "mix should still be near 1 after one frame, got \(filter.mix)")

        for _ in 1..<(rampFrames / 2) {
            _ = filter.process(left: 0.1, right: 0.1, target: 0)
        }
        assertTrue(filter.mix > 0.25 && filter.mix < 0.75, "mix should be partway at half the ramp, got \(filter.mix)")

        for _ in (rampFrames / 2)..<(rampFrames + 2) {
            _ = filter.process(left: 0.1, right: 0.1, target: 0)
        }
        assertTrue(filter.mix < 1e-3, "mix should be back to 0 after rampSeconds of frames, got \(filter.mix)")
        assertTrue(filter.mix >= 0, "mix should never undershoot 0, got \(filter.mix)")
    }

    runSuite("Render copies interleaved stereo straight through when muffle is off") {
        let frames = 256
        let input = TestAudioBufferList(layout: [2], frames: frames)
        let output = TestAudioBufferList(layout: [2], frames: frames, fill: 0.9)
        input.write(buffer: 0) { frame, channel in channel == 0 ? Float(frame) * 0.001 : -Float(frame) * 0.002 }

        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        filter.render(input: input.constPointer, output: output.mutablePointer, target: 0)

        let out = output.samples(buffer: 0)
        var mismatches = 0
        for frame in 0..<frames {
            if abs(out[frame * 2] - Float(frame) * 0.001) > 1e-6 { mismatches += 1 }
            if abs(out[frame * 2 + 1] + Float(frame) * 0.002) > 1e-6 { mismatches += 1 }
        }
        assertEqual(mismatches, 0, "every L/R sample should come through unchanged")
    }

    runSuite("Render to a mono output gives the average of left and right") {
        let frames = 128
        let input = TestAudioBufferList(layout: [2], frames: frames)
        let output = TestAudioBufferList(layout: [1], frames: frames, fill: 0.9)
        input.write(buffer: 0) { frame, channel in channel == 0 ? 0.6 : Float(frame) * -0.001 }

        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        filter.render(input: input.constPointer, output: output.mutablePointer, target: 0)

        let out = output.samples(buffer: 0)
        var mismatches = 0
        for frame in 0..<frames {
            let expected = (0.6 + Float(frame) * -0.001) / 2
            if abs(out[frame] - expected) > 1e-6 { mismatches += 1 }
        }
        assertEqual(mismatches, 0, "mono output should be (L + R) / 2 for every frame")
    }

    runSuite("Render zeroes interleaved output channels beyond the second") {
        let frames = 64
        let input = TestAudioBufferList(layout: [2], frames: frames)
        let output = TestAudioBufferList(layout: [4], frames: frames, fill: 0.9)
        input.write(buffer: 0) { _, channel in channel == 0 ? 0.25 : -0.5 }

        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        filter.render(input: input.constPointer, output: output.mutablePointer, target: 0)

        let out = output.samples(buffer: 0)
        var wrongFront = 0
        var leftoverExtra = 0
        for frame in 0..<frames {
            if abs(out[frame * 4] - 0.25) > 1e-6 || abs(out[frame * 4 + 1] + 0.5) > 1e-6 { wrongFront += 1 }
            if out[frame * 4 + 2] != 0 || out[frame * 4 + 3] != 0 { leftoverExtra += 1 }
        }
        assertEqual(wrongFront, 0, "channels 1 and 2 should carry L and R")
        assertEqual(leftoverExtra, 0, "channels 3 and 4 should be silent")
    }

    runSuite("Render zeroes non-interleaved output buffers beyond the second") {
        let frames = 64
        let input = TestAudioBufferList(layout: [2], frames: frames)
        let output = TestAudioBufferList(layout: [1, 1, 1], frames: frames, fill: 0.9)
        input.write(buffer: 0) { _, channel in channel == 0 ? 0.25 : -0.5 }

        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        filter.render(input: input.constPointer, output: output.mutablePointer, target: 0)

        assertTrue(output.samples(buffer: 0).allSatisfy { abs($0 - 0.25) <= 1e-6 }, "buffer 1 should carry L")
        assertTrue(output.samples(buffer: 1).allSatisfy { abs($0 + 0.5) <= 1e-6 }, "buffer 2 should carry R")
        assertTrue(output.samples(buffer: 2).allSatisfy { $0 == 0 }, "buffer 3 should be silent")
    }

    runSuite("Render with no input writes silence, not leftover samples") {
        for target: Float in [0, 1] {
            let output = TestAudioBufferList(layout: [2], frames: 128, fill: 0.5)
            var filter = DictationMuffleFilter(sampleRate: sampleRate)
            filter.render(input: nil, output: output.mutablePointer, target: target)
            let leftovers = output.samples(buffer: 0).filter { $0 != 0 }.count
            assertEqual(leftovers, 0, "nil input at target \(target) should leave only zeros in the output")
        }

        let mono = TestAudioBufferList(layout: [1], frames: 32, fill: -0.7)
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        filter.render(input: nil, output: mono.mutablePointer, target: 0)
        assertEqual(mono.samples(buffer: 0).filter { $0 != 0 }.count, 0, "nil input should silence a mono output too")
    }

    runSuite("Render reads non-interleaved input buffers as left and right") {
        let frames = 96
        let input = TestAudioBufferList(layout: [1, 1], frames: frames)
        let output = TestAudioBufferList(layout: [2], frames: frames, fill: 0.9)
        input.write(buffer: 0) { frame, _ in Float(frame) * 0.003 }
        input.write(buffer: 1) { frame, _ in 0.4 - Float(frame) * 0.001 }

        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        filter.render(input: input.constPointer, output: output.mutablePointer, target: 0)

        let out = output.samples(buffer: 0)
        var mismatches = 0
        for frame in 0..<frames {
            if abs(out[frame * 2] - Float(frame) * 0.003) > 1e-6 { mismatches += 1 }
            if abs(out[frame * 2 + 1] - (0.4 - Float(frame) * 0.001)) > 1e-6 { mismatches += 1 }
        }
        assertEqual(mismatches, 0, "buffer 1 should land in L and buffer 2 in R")
    }
}

/// Holds the filter at target 1 well past the ramp, then compares output RMS to input RMS.
private func muffledRMSRatio(frequencyHz: Double, sampleRate: Double) -> (left: Float, right: Float) {
    var filter = DictationMuffleFilter(sampleRate: sampleRate)
    let warmupFrames = Int(sampleRate) // 1 s, several times rampSeconds
    let measureFrames = Int(sampleRate / 10)
    var inSquares: Double = 0
    var outLeftSquares: Double = 0
    var outRightSquares: Double = 0
    for frame in 0..<(warmupFrames + measureFrames) {
        let phase = 2 * Double.pi * frequencyHz * Double(frame) / sampleRate
        let sample = Float(sin(phase)) * 0.5
        let (left, right) = filter.process(left: sample, right: sample, target: 1)
        if frame >= warmupFrames {
            inSquares += Double(sample * sample)
            outLeftSquares += Double(left * left)
            outRightSquares += Double(right * right)
        }
    }
    let inRMS = sqrt(inSquares / Double(measureFrames))
    return (
        Float(sqrt(outLeftSquares / Double(measureFrames)) / inRMS),
        Float(sqrt(outRightSquares / Double(measureFrames)) / inRMS)
    )
}

/// An AudioBufferList backed by allocated Float32 memory. `layout` lists the
/// channel count of each buffer, so [2] is interleaved stereo and [1, 1] is
/// non-interleaved stereo.
private final class TestAudioBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private let storages: [UnsafeMutablePointer<Float>]
    private let layout: [Int]
    private let frames: Int

    init(layout: [Int], frames: Int, fill: Float = 0) {
        self.layout = layout
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        var storages: [UnsafeMutablePointer<Float>] = []
        for (index, channels) in layout.enumerated() {
            let count = frames * channels
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
            storage.initialize(repeating: fill, count: count)
            storages.append(storage)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage)
            )
        }
        self.storages = storages
    }

    deinit {
        for storage in storages { storage.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var mutablePointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }
    var constPointer: UnsafePointer<AudioBufferList> { UnsafePointer(list.unsafeMutablePointer) }

    func write(buffer: Int, _ value: (_ frame: Int, _ channel: Int) -> Float) {
        let channels = layout[buffer]
        for frame in 0..<frames {
            for channel in 0..<channels {
                storages[buffer][frame * channels + channel] = value(frame, channel)
            }
        }
    }

    func samples(buffer: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: storages[buffer], count: frames * layout[buffer]))
    }
}
