import XCTest
import Combine
import AVFoundation
import QuartzCore
@testable import TranscriptedCore

/// The system tap hands the meter its buffers in ~50 ms bursts (50-60 ms
/// with timer leeway). The call meter must still publish about every 150 ms:
/// on every third burst, never the fourth, and never slower than the mic.
@available(macOS 14.0, *)
final class SystemLevelPublishCadenceTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    @MainActor
    func testCallMeterPublishesOnEveryThirdSteadyBurst() {
        let gate = Audio.systemLevelPublishInterval
        let steady = CoreAudioTapDrainCadence.steady
        let shortestBurst = Double(steady.intervalMilliseconds) / 1000
        let longestBurst = Double(steady.intervalMilliseconds + steady.leewayMilliseconds) / 1000
        XCTAssertGreaterThan(gate, 2 * longestBurst, "two late bursts never publish twice")
        XCTAssertLessThanOrEqual(gate, 3 * shortestBurst, "the third on-time burst always publishes")
        XCTAssertLessThanOrEqual(gate, Audio.levelPublishInterval, "the call meter never scrolls slower than the mic's")
    }

    @MainActor
    func testSystemGateOpensBetweenThirteenAndFifteenHundredths() async {
        let audio = makeAudio()
        let buffer = makeBuffer()
        var publishes = 0
        audio.$systemAudioLevelHistory.dropFirst()
            .sink { _ in publishes += 1 }
            .store(in: &cancellables)

        audio.calculateSystemLevel(buffer: buffer)
        await drainMainQueue()
        XCTAssertEqual(publishes, 1)

        // Set the stamp's age instead of sleeping. Well under the gate: held.
        audio.systemLevelLock.withLock { audio.lastSystemLevelPublishTime = CACurrentMediaTime() - 0.08 }
        audio.calculateSystemLevel(buffer: buffer)
        await drainMainQueue()
        XCTAssertEqual(publishes, 1, "a burst ~80 ms after a publish must not publish")

        // 140 ms is past the system gate but short of the mic's 150 ms.
        audio.systemLevelLock.withLock { audio.lastSystemLevelPublishTime = CACurrentMediaTime() - 0.14 }
        audio.calculateSystemLevel(buffer: buffer)
        await drainMainQueue()
        XCTAssertEqual(publishes, 2, "the third burst (~140 ms) publishes")
    }

    // MARK: - Helpers

    private func makeAudio() -> Audio {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemLevelPublishCadenceTests-\(UUID().uuidString)", isDirectory: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        return Audio(paths: paths)
    }

    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        for channel in 0..<2 {
            for frame in 0..<512 { buffer.floatChannelData![channel][frame] = 0.25 }
        }
        return buffer
    }

    @MainActor
    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}
