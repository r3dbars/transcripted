import XCTest
import AVFoundation
@testable import TranscriptedCore

/// A dead tap does not always deliver exact zeros: denormals, float residue
/// or 24-bit dither kept the mid-recording watch from ever arming. Audible
/// hiss must still read as a quiet call, never a lost one.
final class CoreAudioSystemAudioSignalFloorTests: XCTestCase {
    private final class HAL: @unchecked Sendable {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var now: TimeInterval = 100
        var starts = 0
        var otherAudioPlaying = false

        func makeCapture() -> CoreAudioSystemAudioCapture {
            CoreAudioSystemAudioCapture(hardwareHooks: .init(
                prepare: { self.format },
                start: { self.starts += 1 },
                stop: {},
                currentFormat: { self.format },
                otherAudioIsPlaying: { self.otherAudioPlaying }
            ), clock: { self.now })
        }

        func buffer(frames: AVAudioFrameCount = 64, fill: (Int) -> Float = { _ in 0 }) -> AVAudioPCMBuffer {
            let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            result.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) {
                    result.floatChannelData![channel][frame] = fill(channel * Int(frames) + frame)
                }
            }
            return result
        }
    }

    /// Deterministic noise in [-amplitude, amplitude].
    private func noise(_ amplitude: Float) -> (Int) -> Float {
        { index in
            let x = sin(Float(index) * 12.9898) * 43758.5453
            return (x - x.rounded(.down) - 0.5) * 2 * amplitude
        }
    }

    func testSignalFloorClassification() {
        let hal = HAL()
        XCTAssertFalse(CoreAudioSystemAudioCapture.containsSignal(hal.buffer()), "exact zeros")
        XCTAssertFalse(CoreAudioSystemAudioCapture.containsSignal(hal.buffer { _ in -0.0 }), "negative zero")
        XCTAssertFalse(CoreAudioSystemAudioCapture.containsSignal(hal.buffer { _ in 1e-40 }), "denormal")
        XCTAssertFalse(CoreAudioSystemAudioCapture.containsSignal(hal.buffer(fill: noise(9e-7))), "noise peaking under -120 dBFS")
        XCTAssertTrue(CoreAudioSystemAudioCapture.containsSignal(hal.buffer { $0 == 5 ? 1e-6 : 0 }), "one sample at the floor")
        XCTAssertTrue(CoreAudioSystemAudioCapture.containsSignal(hal.buffer { $0 == 5 ? .nan : 0 }), "NaN still counts")
        XCTAssertTrue(CoreAudioSystemAudioCapture.containsSignal(hal.buffer(fill: noise(1e-4))), "-80 dBFS hiss is a quiet call")
    }

    private func runLapse(
        _ hal: HAL, _ capture: CoreAudioSystemAudioCapture, playing: Bool = true, seconds: Int,
        fill: @escaping (Int) -> Float
    ) {
        hal.otherAudioPlaying = playing
        let speech = hal.buffer { $0 == 0 ? 0.25 : 0 }
        hal.now += 0.1
        capture.receiveForTesting(speech)
        capture.drainForTesting()
        for _ in 0..<seconds {
            hal.now += 1
            capture.receiveForTesting(hal.buffer(fill: fill))
            capture.drainForTesting()
        }
    }

    func testSubFloorResidueAfterSignalWhileOtherAudioPlaysRebuildsOnce() throws {
        for (label, fill) in [("denormal", { (_: Int) -> Float in 1e-40 }), ("float residue", noise(5e-7))] {
            let hal = HAL(), capture = hal.makeCapture()
            try capture.start { _ in }
            runLapse(hal, capture, seconds: 30, fill: fill)
            XCTAssertEqual(hal.starts, 2, "\(label): a tap that only hears sub-floor residue gets one fresh tap")
            XCTAssertEqual(capture.diagnostics.silentPlaybackReconnects, 1, label)
            capture.stopSync()
        }
    }

    func testAudibleHissAfterSignalNeverRebuildsAQuietCall() throws {
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        runLapse(hal, capture, seconds: 120, fill: noise(1e-4))
        XCTAssertEqual(hal.starts, 1, "-80 dBFS hiss is a quiet call, not a dead tap")
        XCTAssertFalse(capture.isNotHearingPlayback)
    }

    func testSubFloorResidueWithNothingPlayingNeverRebuilds() throws {
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        runLapse(hal, capture, playing: false, seconds: 120, fill: { _ in 1e-40 })
        XCTAssertEqual(hal.starts, 1, "residue on a quiet Mac is not a lost call")
    }
}
