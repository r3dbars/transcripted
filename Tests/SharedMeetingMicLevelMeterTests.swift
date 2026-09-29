import AVFoundation
import Foundation

private final class FakeMeterClock: @unchecked Sendable {
    var now: CFAbsoluteTime = 1_000
}

private func makeLevelMeterTestBuffer(amplitude: Float, frames: Int = 480) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ),
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
    let data = buffer.floatChannelData else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames {
        data[0][frame] = frame.isMultiple(of: 2) ? amplitude : -amplitude
    }
    return buffer
}

func testSharedMeetingMicLevelMeter() {
    runSuite("Borrowed meeting-mic dictation meters at dictation's cadence, not the meeting's 0.15 s") {
        let clock = FakeMeterClock()
        let meter = SharedMeetingMicLevelMeter(
            interval: TranscriptedConstants.audioMeteringInterval,
            now: { clock.now }
        )
        meter.begin()

        // Relayed buffers every 1/64 s (exact in binary, so no float drift)
        // for about 450 ms, with a rising level.
        var publishedAt: [Int] = []
        var levels: [Float] = []
        var expected: [Float] = []
        for step in 0..<30 {
            clock.now = 1_000 + Double(step) / 64
            guard let buffer = makeLevelMeterTestBuffer(amplitude: 0.01 + Float(step) * 0.01) else {
                assertTrue(false, "Expected test buffer to be created")
                return
            }
            if let reading = meter.levels(for: buffer).first {
                publishedAt.append(step)
                levels.append(reading.level)
                expected.append(DictationAudioLevelMeter.normalizedLevel(from: buffer))
            }
        }

        // First buffer is published right away, then the first one more than
        // 50 ms later: every 4th buffer (62.5 ms). The meeting's 0.15 s meter
        // would have moved only 3 times over this span.
        assertEqual(publishedAt, Array(stride(from: 0, to: 30, by: 4)), "level should update on dictation's 50 ms cadence")
        assertEqual(levels, expected, "level should match the normal dictation meter's scaling")
        assertTrue(levels.last ?? 0 > levels.first ?? 1, "fixture should exercise a changing level")
    }

    runSuite("A meeting tap's long buffer is shown as dictation-sized steps, not one ~85 ms step") {
        let clock = FakeMeterClock()
        let meter = SharedMeetingMicLevelMeter(
            interval: TranscriptedConstants.audioMeteringInterval,
            now: { clock.now }
        )
        meter.begin()

        // The meeting engine tap's 4096-frame buffer at 48 kHz (~85 ms): quiet
        // first half, loud second half.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
        let data = buffer.floatChannelData else {
            assertTrue(false, "Expected test buffer to be created")
            return
        }
        buffer.frameLength = 4096
        for frame in 0..<4096 {
            data[0][frame] = frame < 2048 ? 0.01 : 0.3
        }

        var steps: [TimeInterval] = []
        var levels: [Float] = []
        for arrival in 0..<3 {
            // Buffers arrive back to back, closer than the throttle would allow
            // if each were a single reading.
            clock.now = 1_000 + Double(arrival) * 4096 / 48_000
            for reading in meter.levels(for: buffer) {
                steps.append(clock.now - 1_000 + reading.delay)
                levels.append(reading.level)
            }
        }

        let expectedSteps = (0..<6).map { Double($0) * 2048 / 48_000 }
        assertEqual(steps.count, expectedSteps.count, "each ~85 ms buffer should give two readings")
        assertTrue(
            zip(steps, expectedSteps).allSatisfy { abs($0 - $1) < 1e-9 },
            "readings should be spaced ~43 ms apart, near dictation's 50 ms cadence"
        )
        let quiet = DictationAudioLevelMeter.normalizedLevel(from: buffer, frames: 0..<2048)
        let loud = DictationAudioLevelMeter.normalizedLevel(from: buffer, frames: 2048..<4096)
        assertEqual(levels, [quiet, loud, quiet, loud, quiet, loud], "each window uses dictation's meter scaling")
        assertTrue(loud > quiet, "fixture should give two different levels")
    }

    runSuite("Borrowed meeting-mic level is silent before dictation borrows the mic and after it ends") {
        let clock = FakeMeterClock()
        let meter = SharedMeetingMicLevelMeter(interval: 0.05, now: { clock.now })
        guard let buffer = makeLevelMeterTestBuffer(amplitude: 0.2) else {
            assertTrue(false, "Expected test buffer to be created")
            return
        }

        assertTrue(meter.levels(for: buffer).isEmpty, "no level before begin")

        meter.begin()
        guard let reading = meter.levels(for: buffer).first else {
            assertTrue(false, "first buffer after begin should publish")
            return
        }
        assertTrue(meter.isCurrent(session: reading.session), "reading from the live borrow is current")

        meter.end()
        clock.now += 1
        assertTrue(meter.levels(for: buffer).isEmpty, "no level after end")
        assertFalse(meter.isCurrent(session: reading.session), "an in-flight reading from an ended borrow is dropped")
    }

    runSuite("A reading from a previous borrow can't land on the next dictation") {
        let clock = FakeMeterClock()
        let meter = SharedMeetingMicLevelMeter(interval: 0.05, now: { clock.now })
        guard let buffer = makeLevelMeterTestBuffer(amplitude: 0.2) else {
            assertTrue(false, "Expected test buffer to be created")
            return
        }

        meter.begin()
        let first = meter.levels(for: buffer).first
        meter.end()
        meter.begin()
        let second = meter.levels(for: buffer).first

        assertTrue(first != nil && second != nil, "a new borrow publishes its first buffer right away")
        assertFalse(meter.isCurrent(session: first?.session ?? 0), "old borrow's reading is stale")
        assertTrue(meter.isCurrent(session: second?.session ?? 0), "new borrow's reading is current")
    }
}
