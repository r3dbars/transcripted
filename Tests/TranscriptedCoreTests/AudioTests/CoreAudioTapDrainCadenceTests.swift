import XCTest
import AVFoundation
import CoreAudio
import Combine
@testable import TranscriptedCore

/// The system tap drains every 10 ms until buffers flow, then in ~50 ms
/// bursts. These pin what must not change when the drain runs less often:
/// the writer gets the same PCM in the same order, a missed format
/// notification is still caught every steady tick, and a reconnect's pad
/// still measures the real host-time hole.
///
/// Synthetic only: the real timer, CPU and wakeup savings and an AirPods HFP
/// flip mid-call still need `bash check.sh hardware` on a Mac.
final class CoreAudioTapDrainCadenceTests: XCTestCase {

    // MARK: - Cadence policy

    func testSteadyTickStillPollsTheFormatOnEveryDrain() {
        let fast = CoreAudioTapDrainCadence.fast
        let steady = CoreAudioTapDrainCadence.steady
        XCTAssertEqual(fast, .init(intervalMilliseconds: 10, leewayMilliseconds: 2), "start and rebuild keep today's prompt drain")
        XCTAssertEqual(steady, .init(intervalMilliseconds: 50, leewayMilliseconds: 10))
        // Ticks are never early. Keep 5 ms of slack under the shortest gap
        // between steady drains so each one runs the backstop poll.
        let poll = CoreAudioTapDrainCadence.formatPollSeconds
        XCTAssertLessThanOrEqual(poll, Double(steady.intervalMilliseconds - steady.leewayMilliseconds - 5) / 1000)
        XCTAssertGreaterThan(poll, 0)
    }

    func testDrainStaysFastUntilTheFirstBufferThenSettlesOnce() {
        let queue = DispatchQueue(label: "CoreAudioTapDrainCadenceTests")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        defer { timer.cancel() }
        var cadence = CoreAudioTapDrainCadence()
        XCTAssertFalse(cadence.isFast)
        cadence.start(timer)
        timer.resume()
        XCTAssertTrue(cadence.isFast, "a fresh start drains at the fast cadence")
        XCTAssertFalse(cadence.settle(timer, hasDeliveredBuffer: false), "no buffer yet: stay fast")
        XCTAssertTrue(cadence.isFast)
        XCTAssertFalse(cadence.settle(nil, hasDeliveredBuffer: true), "the hooks path has no timer to move")
        XCTAssertTrue(cadence.settle(timer, hasDeliveredBuffer: true), "first buffer moves to the steady tick")
        XCTAssertFalse(cadence.isFast)
        XCTAssertFalse(cadence.settle(timer, hasDeliveredBuffer: true), "settles once, not every drain")
        cadence.start(timer)
        XCTAssertTrue(cadence.isFast, "a rebuild starts fast again")
    }

    // MARK: - Capture through the HAL seam

    func testBurstDrainsHandTheWriterTheSamePCMInTheSameOrder() throws {
        let everyBuffer = try runDeliveryScenario(drainEvery: 1)
        let bursts = try runDeliveryScenario(drainEvery: 5)
        XCTAssertEqual(everyBuffer.frames.count, 40)
        XCTAssertEqual(bursts.frames, everyBuffer.frames)
        XCTAssertEqual(bursts.checksums, everyBuffer.checksums)
        XCTAssertEqual(bursts.successRate, everyBuffer.successRate)
        XCTAssertEqual(bursts.events, everyBuffer.events)
        XCTAssertEqual(bursts.notHearing, everyBuffer.notHearing)
        XCTAssertEqual(bursts.diagnostics, everyBuffer.diagnostics)
        XCTAssertEqual(bursts.starts, 1, "bursts are not a reason to reconnect")
    }

    func testEverySteadyDrainChecksTheFormatAndCatchesAMissedRouteChange() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        defer { capture.stopSync() }
        try capture.start { frames += Int($0.frameLength) }
        let readsBefore = hal.formatReads
        for _ in 0..<4 {
            hal.now += 0.040
            capture.receiveForTesting(hal.buffer(frames: 512, seed: 1))
            capture.drainForTesting()
        }
        XCTAssertEqual(hal.formatReads - readsBefore, 4, "one backstop format read per 40 ms drain")
        XCTAssertEqual(frames, 4 * 512)

        // The route drops to 24 kHz with the same buffer size and no
        // listener callback. The poll alone must catch it before any
        // new-rate samples reach the writer.
        let delivered = frames
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false)!
        for _ in 0..<5 { capture.receiveForTesting(hal.buffer(frames: 512, seed: 2)) }
        hal.now += 0.040
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "the missed format change reconnects")
        XCTAssertEqual(frames, delivered, "no new-rate frames go out under the old format")
    }

    func testReconnectPadMatchesTheHostTimeHoleAfterABurst() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        let bufferSeconds = 512.0 / 48_000
        var lastTicks: UInt64 = 0
        for index in 0..<5 {
            lastTicks = hostTicks(200 + Double(index) * bufferSeconds)
            capture.receiveForTesting(hal.buffer(frames: 512, seed: Float(index)), hostTime: lastTicks)
        }
        hal.now += 0.050
        capture.drainForTesting()

        capture.invalidateFormatForTesting()
        hal.now += 0.050
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "the invalidated format reconnects")

        let newTicks = hostTicks(200.4)
        hal.now += 0.400
        capture.receiveForTesting(hal.buffer(frames: 512, seed: 9), hostTime: newTicks)
        capture.drainForTesting()

        guard case .gap(let duration) = events.last else { return XCTFail("The reconnect must be padded") }
        let lastEnd = try XCTUnwrap(CoreAudioSystemAudioCapture.hostSeconds(lastTicks)) + bufferSeconds
        let firstNew = try XCTUnwrap(CoreAudioSystemAudioCapture.hostSeconds(newTicks))
        XCTAssertEqual(duration, firstNew - lastEnd, accuracy: 1e-6, "the pad covers the host-time hole, not the drain-tick spacing")
    }

    // MARK: - Helpers

    private struct DeliveryResult {
        var frames: [AVAudioFrameCount] = []
        var checksums: [Double] = []
        var successRate: Double = 0
        var events: [SystemAudioRecoveryEvent] = []
        var notHearing = false
        var diagnostics = SystemAudioTapDiagnostics()
        var starts = 0
    }

    private func runDeliveryScenario(drainEvery stride: Int) throws -> DeliveryResult {
        let hal = HAL(), capture = hal.makeCapture()
        var result = DeliveryResult()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {} }
        try capture.start { buffer in
            result.frames.append(buffer.frameLength)
            result.checksums.append(Self.checksum(buffer))
        }
        for index in 0..<40 {
            hal.now += 512.0 / 48_000
            let ticks = hostTicks(300 + Double(index) * 512.0 / 48_000)
            capture.receiveForTesting(hal.buffer(frames: 512, seed: Float(index)), hostTime: ticks)
            if (index + 1) % stride == 0 { capture.drainForTesting() }
        }
        capture.drainForTesting()
        result.successRate = capture.bufferSuccessRate
        result.notHearing = capture.isNotHearingPlayback
        result.diagnostics = capture.diagnostics
        result.starts = hal.starts
        capture.stopSync()
        result.events = events
        return result
    }

    private static func checksum(_ buffer: AVAudioPCMBuffer) -> Double {
        var sum = 0.0
        guard let channels = buffer.floatChannelData else { return .nan }
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<Int(buffer.frameLength) {
                sum += Double(channels[channel][index]) * Double(index + 1 + channel * 100_000)
            }
        }
        return sum
    }

    private func hostTicks(_ seconds: TimeInterval) -> UInt64 {
        AudioConvertNanosToHostTime(UInt64(seconds * 1_000_000_000))
    }

    private final class HAL: @unchecked Sendable {
        var format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var now: TimeInterval = 100
        var starts = 0
        var formatReads = 0

        func makeCapture() -> CoreAudioSystemAudioCapture {
            CoreAudioSystemAudioCapture(hardwareHooks: .init(
                prepare: { self.format },
                start: { self.starts += 1 },
                stop: {},
                currentFormat: { self.formatReads += 1; return self.format }
            ), clock: { self.now })
        }

        /// A distinct ramp per buffer so reordering or a dropped buffer
        /// changes the checksums.
        func buffer(frames: AVAudioFrameCount, seed: Float) -> AVAudioPCMBuffer {
            let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            result.frameLength = frames
            for (channel, item) in UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList).enumerated() {
                let samples = item.mData!.assumingMemoryBound(to: Float.self)
                for index in 0..<Int(frames) {
                    samples[index] = 0.01 * (seed + 1) + Float(index) / 100_000 + Float(channel) * 0.001
                }
            }
            return result
        }
    }
}
