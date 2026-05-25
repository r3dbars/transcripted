import XCTest
@preconcurrency import AVFoundation
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioFormatPolicyTests: XCTestCase {

    // MARK: - AudioRecordingFormatPolicy.displaySampleRate

    func testDisplaySampleRateRendersUsableRatesAsIntegerString() {
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(48_000), "48000")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(16_000), "16000")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(8_000), "8000")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(384_000), "384000")
    }

    func testDisplaySampleRateReportsInvalidForOutOfRangeOrNonFinite() {
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(0), "invalid")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(-1), "invalid")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(7_999), "invalid")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(384_001), "invalid")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(.nan), "invalid")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(.infinity), "invalid")
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(-Double.infinity), "invalid")
    }

    // MARK: - AudioRecordingFormatPolicy.snapshot rejection

    func testSnapshotRejectsFormatsWithOutOfRangeSampleRate() throws {
        // 4 kHz is below the 8 kHz minimum supported by the policy.
        let lowRateFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 4_000,
            channels: 1,
            interleaved: false
        ))
        XCTAssertNil(AudioRecordingFormatPolicy.snapshot(lowRateFormat))
    }

    func testMonoOutputFormatProducesInterleavedFloat32() throws {
        let format = try AudioRecordingFormatPolicy.makeMonoOutputFormat(sampleRate: 44_100)
        XCTAssertEqual(format.sampleRate, 44_100, accuracy: 0.1)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertTrue(format.isInterleaved)
    }

    // MARK: - SystemAudioStatus computed properties

    func testSystemAudioStatusWarningCases() {
        XCTAssertFalse(SystemAudioStatus.unknown.isWarning)
        XCTAssertFalse(SystemAudioStatus.healthy.isWarning)
        XCTAssertFalse(SystemAudioStatus.reconnecting.isWarning)
        XCTAssertTrue(SystemAudioStatus.silent.isWarning)
        XCTAssertTrue(SystemAudioStatus.failed.isWarning)
    }

    func testSystemAudioStatusIsRecoveringOnlyForReconnecting() {
        XCTAssertFalse(SystemAudioStatus.unknown.isRecovering)
        XCTAssertFalse(SystemAudioStatus.healthy.isRecovering)
        XCTAssertTrue(SystemAudioStatus.reconnecting.isRecovering)
        XCTAssertFalse(SystemAudioStatus.silent.isRecovering)
        XCTAssertFalse(SystemAudioStatus.failed.isRecovering)
    }

    func testSystemAudioStatusDisplayTextSurfacesUserGuidanceForFailedCase() {
        XCTAssertEqual(SystemAudioStatus.unknown.displayText, "")
        XCTAssertEqual(SystemAudioStatus.healthy.displayText, "")
        XCTAssertEqual(SystemAudioStatus.reconnecting.displayText, "Reconnecting...")
        XCTAssertEqual(SystemAudioStatus.silent.displayText, "System audio silent")
        XCTAssertTrue(
            SystemAudioStatus.failed.displayText.contains("System Settings"),
            "failed status should point users at the System Settings remediation path"
        )
    }

    // MARK: - AudioInputTapTeardownPolicy drain delay

    func testInputCallbackDrainDelayMatchesProductionConstant() {
        XCTAssertEqual(
            AudioInputTapTeardownPolicy.inputCallbackDrainDelay,
            0.05,
            accuracy: 0.0001,
            "drain delay must stay at 50ms — shortening it risks stopping the engine before in-flight tap callbacks have unwound"
        )
    }

    // MARK: - MicRecordingSegment input sanitization

    func testMicRecordingSegmentClampsNegativeGapDurationsToZero() {
        let segment = MicRecordingSegment(url: URL(fileURLWithPath: "/tmp/seg.wav"), gapBeforeDuration: -3.5)
        XCTAssertEqual(segment.gapBeforeDuration, 0)
    }

    func testMicRecordingSegmentRejectsNonFiniteGapDurations() {
        let nanSegment = MicRecordingSegment(url: URL(fileURLWithPath: "/tmp/a.wav"), gapBeforeDuration: .nan)
        let infSegment = MicRecordingSegment(url: URL(fileURLWithPath: "/tmp/b.wav"), gapBeforeDuration: .infinity)
        XCTAssertEqual(nanSegment.gapBeforeDuration, 0)
        XCTAssertEqual(infSegment.gapBeforeDuration, 0)
    }

    func testMicRecordingSegmentPreservesFinitePositiveDuration() {
        let segment = MicRecordingSegment(url: URL(fileURLWithPath: "/tmp/seg.wav"), gapBeforeDuration: 0.42)
        XCTAssertEqual(segment.gapBeforeDuration, 0.42, accuracy: 0.0001)
    }

    // MARK: - AudioRouteVolumeSnapshot

    func testRouteVolumeSnapshotUnavailableMarksEveryScope() {
        let snapshot = AudioRouteVolumeSnapshot.unavailable
        XCTAssertEqual(snapshot.defaultInputVolume, "unavailable")
        XCTAssertEqual(snapshot.defaultOutputVolume, "unavailable")
        XCTAssertEqual(snapshot.defaultSystemOutputVolume, "unavailable")
    }

    func testRouteVolumeSnapshotContextSuffixKeysAreNamespaced() {
        let snapshot = AudioRouteVolumeSnapshot(
            defaultInputVolume: "0.500",
            defaultOutputVolume: "0.750",
            defaultSystemOutputVolume: "unavailable"
        )

        let before = snapshot.context(suffix: "before")
        XCTAssertEqual(before["default_input_volume_before"], "0.500")
        XCTAssertEqual(before["default_output_volume_before"], "0.750")
        XCTAssertEqual(before["default_system_output_volume_before"], "unavailable")
        XCTAssertEqual(before.count, 3)

        let after = snapshot.context(suffix: "after")
        XCTAssertEqual(after["default_input_volume_after"], "0.500")
        XCTAssertNil(after["default_input_volume_before"], "suffix change must not leak prior phase keys")
    }
}
