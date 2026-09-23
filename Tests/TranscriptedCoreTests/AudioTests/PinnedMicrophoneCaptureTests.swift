import XCTest
import AVFoundation
import CoreAudio
@testable import TranscriptedCore

final class PinnedMicrophoneCaptureTests: XCTestCase {
    private let pinnedMic: AudioDeviceID = 41
    private let replacementMic: AudioDeviceID = 77

    func testDeliversContiguousBuffersWithoutEvents() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        var host = 100.0
        for _ in 0..<3 {
            capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: host)
            host += 0.01
        }
        capture.drainForTesting()
        XCTAssertEqual(sink.frames, 1440)
        XCTAssertTrue(sink.events.isEmpty)
        XCTAssertEqual(hal.startedDevices, [pinnedMic], "Only the pinned device is ever opened")
        XCTAssertEqual(capture.recordingFormat?.sampleRate, 48000)
    }

    func testHoleInCaptureTimePadsSilenceBeforeTheNextBuffer() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        capture.receiveForTesting(hal.buffer(frames: 480, value: 0.5), hostSeconds: 100)
        capture.receiveForTesting(hal.buffer(frames: 480, value: 0.5), hostSeconds: 100.51)
        capture.drainForTesting()
        XCTAssertEqual(sink.frames, 480 + 24000 + 480, "A 0.5s hole is filled with 0.5s of silence")
        XCTAssertEqual(sink.buffers.first?.floatChannelData?[0][0], 0.5)
        XCTAssertEqual(sink.buffers[1].floatChannelData?[0][0], 0, "Padding is silence")
        XCTAssertEqual(sink.buffers.last?.floatChannelData?[0][0], 0.5, "Real audio lands after the pad")
        guard case let .gap(seconds, padded)? = sink.events.first else { return XCTFail("Expected a gap event") }
        XCTAssertEqual(seconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(padded, 0.5, accuracy: 0.001)
        XCTAssertEqual(capture.diagnostics.gaps, 1)
    }

    func testJitterBelowThresholdIsNotAGap() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100)
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100.03)
        capture.drainForTesting()
        XCTAssertEqual(sink.frames, 960)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testPaddingCanBeTurnedOffOrCapped() throws {
        for (pads, cap, expectedPad) in [(false, 120.0, 0), (true, 0.25, 12000)] {
            let hal = HAL()
            let capture = hal.makeCapture(
                deviceID: pinnedMic,
                configuration: .init(padsGapsWithSilence: pads, maxSilencePadSeconds: cap)
            )
            let sink = Sink()
            try sink.start(capture)
            capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100)
            capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 101.01)
            capture.drainForTesting()
            XCTAssertEqual(sink.frames, 960 + expectedPad)
            guard case let .gap(seconds, padded)? = sink.events.first else { return XCTFail("Expected a gap event") }
            XCTAssertEqual(seconds, 1.0, accuracy: 0.001, "The full hole is still reported")
            XCTAssertEqual(padded, Double(expectedPad) / 48000, accuracy: 0.001)
            capture.stop()
        }
    }

    func testStallRestartsOnTheSameDeviceAndPadsTheHole() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100)
        capture.drainForTesting()
        hal.now += PinnedMicrophoneCapture.stallTimeoutSeconds + 0.5
        capture.drainForTesting()
        XCTAssertEqual(sink.events, [.restarted(.stall)])
        XCTAssertEqual(hal.startedDevices, [pinnedMic, pinnedMic], "A restart never opens another device")
        XCTAssertEqual(hal.stops, 1)
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 103.51)
        capture.drainForTesting()
        XCTAssertEqual(sink.frames, 480 + 168000 + 480)
        XCTAssertEqual(capture.diagnostics.restarts, 1)
    }

    func testRepeatedStallsWithoutAudioFailAfterTheRestartBudget() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        for _ in 0...PinnedMicrophoneCapture.maxConsecutiveRestarts {
            hal.now += PinnedMicrophoneCapture.stallTimeoutSeconds + 0.5
            capture.drainForTesting()
        }
        XCTAssertEqual(sink.events.filter { $0 == .restarted(.stall) }.count, PinnedMicrophoneCapture.maxConsecutiveRestarts)
        guard case .failed? = sink.events.last else { return XCTFail("Expected failure after the budget") }
        let starts = hal.startedDevices.count
        hal.now += 10
        capture.drainForTesting()
        XCTAssertEqual(hal.startedDevices.count, starts, "A failed capture stays down")
    }

    func testAudioBetweenStallsRefillsTheRestartBudget() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        var host = 100.0
        for _ in 0..<(PinnedMicrophoneCapture.maxConsecutiveRestarts + 3) {
            hal.now += PinnedMicrophoneCapture.stallTimeoutSeconds + 0.5
            capture.drainForTesting()
            host += 4
            capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: host)
            capture.drainForTesting()
        }
        XCTAssertFalse(sink.events.contains { if case .failed = $0 { return true } else { return false } })
    }

    func testSleepPendingSuppressesStallRestartAndWakeGivesAGracePeriod() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        capture.prepareForSystemSleep()
        capture.drainForTesting()
        hal.now += 10
        capture.drainForTesting()
        XCTAssertEqual(hal.startedDevices.count, 1, "Silence while falling asleep is not a stall")
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        hal.now += 1
        capture.drainForTesting()
        XCTAssertEqual(hal.startedDevices.count, 1, "A mic that may still be running is not rebuilt at wake")
        hal.now += PinnedMicrophoneCapture.stallTimeoutSeconds
        capture.drainForTesting()
        XCTAssertEqual(sink.events, [.restarted(.stall)], "A mic that really stopped restarts after the grace period")
    }

    func testFormatChangeRebuildsAndResamplesToTheRecordingFormat() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100)
        capture.drainForTesting()
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        XCTAssertEqual(sink.events, [.restarted(.formatChange)])
        XCTAssertEqual(hal.startedDevices, [pinnedMic, pinnedMic])
        let input = hal.buffer(frames: 2400)
        for index in 0..<2400 { input.floatChannelData![0][index] = sinf(Float(index) * 0.05) * 0.5 }
        capture.receiveForTesting(input, hostSeconds: 100.01)
        capture.drainForTesting()
        XCTAssertTrue(sink.buffers.allSatisfy { $0.format.sampleRate == 48000 }, "The recording format never changes")
        let converted = sink.frames - 480
        XCTAssertGreaterThan(converted, 3600, "2400 frames at 24 kHz are about 4800 at 48 kHz, less converter latency")
        XCTAssertLessThanOrEqual(converted, 4800 + 64)
        XCTAssertEqual(capture.recordingFormat?.sampleRate, 48000)
    }

    func testPolledFormatChangeAlsoRebuilds() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        hal.now += PinnedMicrophoneCapture.formatCheckIntervalSeconds
        capture.drainForTesting()
        XCTAssertEqual(sink.events, [.restarted(.formatChange)])
    }

    func testLostDeviceStopsOnceAndSwitchDeviceKeepsTheTimeline() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        defer { capture.stop() }
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100)
        capture.drainForTesting()
        hal.alive = false
        hal.now += PinnedMicrophoneCapture.formatCheckIntervalSeconds
        capture.drainForTesting()
        hal.now += 10
        capture.drainForTesting()
        XCTAssertEqual(sink.events, [.deviceLost], "Reported once, and no restart loop on a missing device")
        XCTAssertEqual(hal.startedDevices, [pinnedMic])
        XCTAssertTrue(capture.isActive)

        hal.alive = true
        try capture.switchDevice(to: replacementMic)
        XCTAssertEqual(capture.deviceID, replacementMic)
        XCTAssertEqual(hal.startedDevices, [pinnedMic, replacementMic])
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 101.01)
        capture.drainForTesting()
        XCTAssertEqual(sink.frames, 480 + 48000 + 480, "The switch hole is padded like any other")
    }

    func testFinishDrainsTheTailOnceAndStopDiscards() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        let sink = Sink()
        try sink.start(capture)
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100)
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100.01)
        capture.finishAndDrain()
        XCTAssertEqual(sink.frames, 960, "Words said just before Stop are kept")
        XCTAssertFalse(capture.isActive)
        capture.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100.02)
        capture.drainForTesting()
        capture.finishAndDrain()
        XCTAssertEqual(sink.frames, 960)
        XCTAssertEqual(hal.stops, 1)

        let discarding = hal.makeCapture(deviceID: pinnedMic)
        let discarded = Sink()
        try discarded.start(discarding)
        discarding.receiveForTesting(hal.buffer(frames: 480), hostSeconds: 100)
        discarding.stop()
        XCTAssertEqual(discarded.frames, 0)
        XCTAssertNil(discarding.recordingFormat)
    }

    func testPrepareReturnsFormatWithoutStartingAndStartIsIdempotent() throws {
        let hal = HAL(), capture = hal.makeCapture(deviceID: pinnedMic)
        XCTAssertEqual(try capture.prepare().sampleRate, 48000)
        XCTAssertEqual(try capture.prepare().sampleRate, 48000)
        XCTAssertTrue(hal.startedDevices.isEmpty)
        let sink = Sink()
        try sink.start(capture)
        try capture.start(bufferCallback: { _ in XCTFail("Second start replaced the consumer") }, eventHandler: { _ in })
        XCTAssertEqual(hal.prepares, 1)
        XCTAssertEqual(hal.startedDevices, [pinnedMic])
        capture.stop()
    }

    func testRejectedStartLeavesNothingRunning() {
        let hal = HAL()
        hal.rejectStart = true
        let capture = hal.makeCapture(deviceID: pinnedMic)
        XCTAssertThrowsError(try Sink().start(capture))
        XCTAssertFalse(capture.isActive)
        XCTAssertEqual(hal.stops, 1)
    }

    func testDeviceFormatMappingMatchesTheIOProcBufferLayout() throws {
        let mono = try PinnedMicrophoneCapture.deviceFormat(streamDescriptions: [Self.float32(rate: 48000, channels: 1)])
        XCTAssertEqual(mono.channelCount, 1)
        XCTAssertEqual(mono.sampleRate, 48000)

        let stereo = try PinnedMicrophoneCapture.deviceFormat(streamDescriptions: [Self.float32(rate: 44100, channels: 2)])
        XCTAssertEqual(stereo.channelCount, 2)
        XCTAssertTrue(stereo.isInterleaved, "One stereo stream arrives as one interleaved buffer")

        let array = try PinnedMicrophoneCapture.deviceFormat(streamDescriptions: [
            Self.float32(rate: 48000, channels: 1), Self.float32(rate: 48000, channels: 1), Self.float32(rate: 48000, channels: 1),
        ])
        XCTAssertEqual(array.channelCount, 3)
        XCTAssertFalse(array.isInterleaved, "Several mono streams arrive as one buffer per channel")

        var int16 = Self.float32(rate: 48000, channels: 1)
        int16.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        int16.mBitsPerChannel = 16
        int16.mBytesPerFrame = 2
        XCTAssertThrowsError(try PinnedMicrophoneCapture.deviceFormat(streamDescriptions: [int16]))
        XCTAssertThrowsError(try PinnedMicrophoneCapture.deviceFormat(streamDescriptions: []))
        XCTAssertThrowsError(try PinnedMicrophoneCapture.deviceFormat(streamDescriptions: [
            Self.float32(rate: 48000, channels: 1), Self.float32(rate: 44100, channels: 1),
        ]))
        XCTAssertThrowsError(try PinnedMicrophoneCapture.deviceFormat(streamDescriptions: [
            Self.float32(rate: 48000, channels: 2), Self.float32(rate: 48000, channels: 1),
        ]))
    }

    func testRingDropsWhenFullWithoutPoisoningLaterAudio() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let ring = PinnedMicrophoneBufferRing(format: format, capacity: 2, maximumFrames: 512)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        for index in 0..<3 { ring.push(buffer.audioBufferList, hostSeconds: 100 + Double(index)) }
        XCTAssertEqual(ring.dropped.load(ordering: .relaxed), 1)
        XCTAssertFalse(ring.formatInvalidated.load(ordering: .relaxed))
        XCTAssertEqual(ring.pop(format: format)?.hostSeconds, 100)
        XCTAssertEqual(ring.pop(format: format)?.hostSeconds, 101)
        XCTAssertNil(ring.pop(format: format))
        ring.push(buffer.audioBufferList, hostSeconds: 103)
        XCTAssertEqual(ring.pop(format: format)?.hostSeconds, 103, "A full ring recovers once the consumer catches up")
    }

    func testRingInvalidatesOnLayoutMismatch() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let ring = PinnedMicrophoneBufferRing(format: format, capacity: 4, maximumFrames: 512)
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let wrong = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 256)!
        wrong.frameLength = 256
        ring.push(wrong.audioBufferList, hostSeconds: 100)
        XCTAssertTrue(ring.formatInvalidated.load(ordering: .relaxed))
        XCTAssertNil(ring.pop(format: format))

        let tooLong = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        tooLong.frameLength = 1024
        let fresh = PinnedMicrophoneBufferRing(format: format, capacity: 4, maximumFrames: 512)
        fresh.push(tooLong.audioBufferList, hostSeconds: 100)
        XCTAssertTrue(fresh.formatInvalidated.load(ordering: .relaxed))
    }

    // MARK: - Fakes

    private static func float32(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private final class Sink: @unchecked Sendable {
        var buffers: [AVAudioPCMBuffer] = []
        var events: [PinnedMicrophoneCaptureEvent] = []
        var frames: Int { buffers.reduce(0) { $0 + Int($1.frameLength) } }
        func start(_ capture: PinnedMicrophoneCapture) throws {
            try capture.start(
                bufferCallback: { self.buffers.append($0) },
                eventHandler: { self.events.append($0) }
            )
        }
    }

    private final class HAL: @unchecked Sendable {
        var format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var now: TimeInterval = 100
        var alive = true
        var rejectStart = false
        var prepares = 0
        var stops = 0
        var startedDevices: [AudioDeviceID] = []

        func makeCapture(
            deviceID: AudioDeviceID,
            configuration: PinnedMicrophoneCapture.Configuration = .init()
        ) -> PinnedMicrophoneCapture {
            PinnedMicrophoneCapture(
                deviceID: deviceID,
                configuration: configuration,
                hardwareHooks: .init(
                    prepare: { _ in self.prepares += 1; return self.format },
                    start: { device in
                        if self.rejectStart { throw NSError(domain: "HALTest", code: 1) }
                        self.startedDevices.append(device)
                    },
                    stop: { self.stops += 1 },
                    currentFormat: { _ in self.format },
                    isAlive: { _ in self.alive }
                ),
                clock: { self.now }
            )
        }

        func buffer(frames: AVAudioFrameCount, value: Float = 0) -> AVAudioPCMBuffer {
            let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            result.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<Int(frames) { result.floatChannelData![channel][index] = value }
            }
            return result
        }
    }
}
