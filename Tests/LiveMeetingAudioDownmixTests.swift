import AVFoundation
import Foundation

func testLiveMeetingAudioDownmix() {
    func buffer(_ channels: [[Float]], interleaved: Bool) -> AVAudioPCMBuffer? {
        let frames = channels.first?.count ?? 0
        // Past two channels AVAudioFormat needs a layout.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels.count)),
              let format = channels.count > 2
                ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved, channelLayout: layout)
                : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: AVAudioChannelCount(channels.count), interleaved: interleaved),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let data = pcm.floatChannelData else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in channels.indices {
            for frame in 0..<frames {
                if interleaved { data[0][frame * channels.count + channel] = channels[channel][frame] }
                else { data[channel][frame] = channels[channel][frame] }
            }
        }
        return pcm
    }

    func near(_ actual: [Float]?, _ expected: [Float]) -> Bool {
        guard let actual, actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { abs($0 - $1) <= 1e-6 }
    }

    runSuite("The live transcript hears the average of the call's channels, interleaved or not") {
        let left: [Float] = [0.5, -0.25, 1, 0, 0.125]
        let right: [Float] = [-0.5, 0.75, 0.5, 0.25, 0.125]
        let expected: [Float] = [0, 0.25, 0.75, 0.125, 0.125]
        for interleaved in [false, true] {
            let mono = buffer([left, right], interleaved: interleaved).flatMap(LiveMeetingAudioDownmix.monoSamples)
            assertTrue(near(mono, expected), "stereo, interleaved: \(interleaved), got \(String(describing: mono))")
        }

        let third: [Float] = [0.3, 0, -0.75, 0.6, 0]
        let three = zip(zip(left, right), third).map { ($0.0 + $0.1 + $1) / 3 }
        for interleaved in [false, true] {
            let mono = buffer([left, right, third], interleaved: interleaved).flatMap(LiveMeetingAudioDownmix.monoSamples)
            assertTrue(near(mono, three), "three channels, interleaved: \(interleaved)")
        }
    }

    runSuite("Mono passes through unchanged and an empty buffer gives nothing") {
        let samples: [Float] = [0.1, -0.2, 0.3]
        assertEqual(buffer([samples], interleaved: false).flatMap(LiveMeetingAudioDownmix.monoSamples), samples)
        assertNil(buffer([[], []], interleaved: false).flatMap(LiveMeetingAudioDownmix.monoSamples))
    }
}
