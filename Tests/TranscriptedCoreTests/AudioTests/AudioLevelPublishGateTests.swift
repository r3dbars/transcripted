import XCTest
import Combine
import AVFoundation
@testable import TranscriptedCore

/// Contract tests for the level-publish time gate: buffer callbacks arrive at
/// 12–100Hz, but `audioLevel` / `audioLevelHistory` / `systemAudioLevelHistory`
/// must only publish once per `Audio.levelPublishInterval` so SwiftUI observers
/// of the capture mirrors stop re-rendering at buffer rate.
@available(macOS 14.0, *)
final class AudioLevelPublishGateTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func makeAudio() -> Audio {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLevelPublishGateTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeBuffer(sampleValue: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let frameCount: AVAudioFrameCount = 1600
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            channel[frame] = sampleValue
        }
        return buffer
    }

    /// Yield until calculateLevel's queued publish lands without blocking main.
    @MainActor
    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    @MainActor
    func testBackToBackMicBuffersPublishOnce() async {
        let audio = makeAudio()
        let buffer = makeBuffer(sampleValue: 0.5)

        var levelPublishes = 0
        var historyPublishes = 0
        audio.$audioLevel.dropFirst()
            .sink { _ in levelPublishes += 1 }
            .store(in: &cancellables)
        audio.$audioLevelHistory.dropFirst()
            .sink { _ in historyPublishes += 1 }
            .store(in: &cancellables)

        // Both calls land well inside one publish interval — the gate lets
        // the first through and drops the second.
        audio.calculateLevel(buffer: buffer)
        audio.calculateLevel(buffer: buffer)
        await drainMainQueue()

        XCTAssertEqual(levelPublishes, 1, "second buffer inside the interval must not publish")
        XCTAssertEqual(historyPublishes, 1, "history must publish on the same gate as the level")
    }

    @MainActor
    func testMicLevelPublishesAgainAfterInterval() async {
        let audio = makeAudio()
        let buffer = makeBuffer(sampleValue: 0.5)

        var levelPublishes = 0
        audio.$audioLevel.dropFirst()
            .sink { _ in levelPublishes += 1 }
            .store(in: &cancellables)

        audio.calculateLevel(buffer: buffer)
        // Age the gate's last-publish stamp past the interval instead of
        // sleeping through it, so the test never depends on the runner's clock.
        // Two intervals, not one, so float rounding can't land it a hair short.
        audio.micLevelPublishLock.withLock {
            audio.lastMicLevelPublishTime -= 2 * Audio.levelPublishInterval
        }
        audio.calculateLevel(buffer: buffer)
        await drainMainQueue()

        XCTAssertEqual(levelPublishes, 2, "a buffer after the interval elapses must publish the fresh level")
    }

    @MainActor
    func testBackToBackSystemBuffersPublishHistoryOnce() async {
        let audio = makeAudio()
        let buffer = makeBuffer(sampleValue: 0.5)

        var historyPublishes = 0
        audio.$systemAudioLevelHistory.dropFirst()
            .sink { _ in historyPublishes += 1 }
            .store(in: &cancellables)

        audio.calculateSystemLevel(buffer: buffer)
        audio.calculateSystemLevel(buffer: buffer)
        await drainMainQueue()

        XCTAssertEqual(historyPublishes, 1, "second system buffer inside the interval must not publish")
    }

    @MainActor
    func testMicAndSystemGatesAreIndependent() async {
        let audio = makeAudio()
        let buffer = makeBuffer(sampleValue: 0.5)

        var levelPublishes = 0
        var systemHistoryPublishes = 0
        audio.$audioLevel.dropFirst()
            .sink { _ in levelPublishes += 1 }
            .store(in: &cancellables)
        audio.$systemAudioLevelHistory.dropFirst()
            .sink { _ in systemHistoryPublishes += 1 }
            .store(in: &cancellables)

        // A mic publish must not consume the system gate, and vice versa.
        audio.calculateLevel(buffer: buffer)
        audio.calculateSystemLevel(buffer: buffer)
        await drainMainQueue()

        XCTAssertEqual(levelPublishes, 1)
        XCTAssertEqual(systemHistoryPublishes, 1)
    }
}
