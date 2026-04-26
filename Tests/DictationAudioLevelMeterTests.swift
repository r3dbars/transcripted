import AVFoundation
import Foundation

func testDictationAudioLevelMeter() {
    runSuite("DictationAudioLevelMeter sees energy across all non-interleaved channels") {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4),
        let data = buffer.floatChannelData else {
            assertTrue(false, "Expected test buffer to be created")
            return
        }

        buffer.frameLength = 4
        for frame in 0..<4 {
            data[0][frame] = 0.30
            data[1][frame] = -0.30
        }

        let naiveDownmix = (0..<4).map { frame in
            (data[0][frame] + data[1][frame]) / 2
        }
        assertEqual(naiveDownmix.allSatisfy { abs($0) < 0.0001 }, true, "test fixture should cancel under naive averaging")

        let level = DictationAudioLevelMeter.normalizedLevel(from: buffer)
        assertTrue(level > 0.5, "meter should use per-channel energy instead of a cancelling downmix")
    }

    runSuite("DictationAudioLevelMeter reports silence for empty buffers") {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            assertTrue(false, "Expected empty test buffer to be created")
            return
        }

        buffer.frameLength = 0
        assertEqual(DictationAudioLevelMeter.normalizedLevel(from: buffer), 0, "empty buffer should be silent")
    }
}
