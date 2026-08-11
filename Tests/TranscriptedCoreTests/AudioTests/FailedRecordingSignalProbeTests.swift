import XCTest
import AVFoundation
@testable import TranscriptedCore

/// Covers the retry-availability probe.
///
/// The contract that matters most is the fail-safe direction: `.absent` is the
/// only verdict that can take the retry button away, so it must never be
/// returned for a file that has audio anywhere in it, including audio far from
/// the start. Everything uncertain must land on `.inconclusive`.
final class FailedRecordingSignalProbeTests: XCTestCase {

    private var testRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FailedRecordingSignalProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private static let sampleRate: Double = 48_000

    /// Writes a mono WAV of `duration` seconds, filling only `toneRange`
    /// (in seconds) with an audible tone and leaving the rest silent.
    private func writeWAV(
        named name: String,
        duration: Double,
        toneRange: Range<Double>? = nil,
        amplitude: Float = 0.3
    ) throws -> URL {
        let url = testRoot.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let totalFrames = Int(Self.sampleRate * duration)
        let chunkFrames = Int(Self.sampleRate)
        var written = 0
        while written < totalFrames {
            let frames = min(chunkFrames, totalFrames - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            for frame in 0..<frames {
                let time = Double(written + frame) / Self.sampleRate
                if let toneRange, toneRange.contains(time) {
                    channel[frame] = amplitude * sinf(Float(2 * Double.pi * 440 * time))
                } else {
                    channel[frame] = 0
                }
            }
            try file.write(from: buffer)
            written += frames
        }
        return url
    }

    // MARK: - Silence is only asserted after a full read

    func testProbeReportsAbsentForFullySilentRecording() throws {
        let url = try writeWAV(named: "silent.wav", duration: 40)
        XCTAssertEqual(
            FailedRecordingSignalProbe.probe(url: url),
            .absent,
            "a silent artifact cannot produce a transcript, so retry should be withdrawn"
        )
    }

    func testProbeReportsAbsentForZeroLengthRecording() throws {
        let url = try writeWAV(named: "empty.wav", duration: 0)
        XCTAssertEqual(FailedRecordingSignalProbe.probe(url: url), .absent)
    }

    // MARK: - Any audio anywhere must be found

    func testProbeFindsAudioAtTheStart() throws {
        let url = try writeWAV(named: "front-loaded.wav", duration: 40, toneRange: 0..<5)
        XCTAssertEqual(FailedRecordingSignalProbe.probe(url: url), .present)
    }

    func testProbeFindsAudioStrandedInTheMiddle() throws {
        // The case sparse sampling gets wrong: a call that opens and closes with
        // silence but has real conversation in the middle. Getting `.absent`
        // here would hide the retry button on a recoverable meeting.
        let url = try writeWAV(named: "mid-loaded.wav", duration: 120, toneRange: 55..<65)
        XCTAssertEqual(
            FailedRecordingSignalProbe.probe(url: url),
            .present,
            "audio away from the file edges must still count as usable"
        )
    }

    func testProbeFindsAudioOnlyAtTheVeryEnd() throws {
        let url = try writeWAV(named: "tail-loaded.wav", duration: 90, toneRange: 84..<90)
        XCTAssertEqual(FailedRecordingSignalProbe.probe(url: url), .present)
    }

    func testProbeFindsAudioSpanningAWindowBoundary() throws {
        // Windows are 8s; a burst straddling one boundary must not be split into
        // two sub-threshold halves that both read as silence.
        let url = try writeWAV(named: "boundary.wav", duration: 40, toneRange: 7.5..<8.5)
        XCTAssertEqual(FailedRecordingSignalProbe.probe(url: url), .present)
    }

    func testProbeFindsAudioInRecordingShorterThanOneWindow() throws {
        let url = try writeWAV(named: "short.wav", duration: 3, toneRange: 0..<3)
        XCTAssertEqual(FailedRecordingSignalProbe.probe(url: url), .present)
    }

    // MARK: - Unreadable input never suppresses retry

    func testProbeReportsInconclusiveForMissingFile() {
        XCTAssertEqual(
            FailedRecordingSignalProbe.probe(
                url: testRoot.appendingPathComponent("does-not-exist.wav")
            ),
            .inconclusive,
            "a file we cannot open must not be reported as silent"
        )
    }

    func testProbeReportsInconclusiveForNonAudioFile() throws {
        let url = testRoot.appendingPathComponent("not-audio.wav")
        try Data("this is not audio".utf8).write(to: url)
        XCTAssertEqual(FailedRecordingSignalProbe.probe(url: url), .inconclusive)
    }

    // MARK: - Budget

    func testScanBudgetCoversOrdinaryMeetingLengths() {
        XCTAssertGreaterThanOrEqual(
            FailedRecordingSignalProbe.maxScannedSeconds,
            15 * 60,
            "silence verdicts should be definitive for normal meetings, not bail to inconclusive"
        )
    }
}
