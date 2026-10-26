import XCTest
import AVFoundation
@testable import TranscriptedCore

/// Off-by-default capture telemetry: the switch, the per-second window math,
/// the route-state diff and the system tap wiring.
final class CaptureTelemetryTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!

    private func buffer(frames: AVAudioFrameCount = 480, fill: (Int) -> Float) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        result.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                result.floatChannelData![channel][frame] = fill(channel * Int(frames) + frame)
            }
        }
        return result
    }

    // MARK: Switch

    func testPreferenceIsOffByDefaultAndEnvWins() throws {
        let suite = "CaptureTelemetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CaptureTelemetryPreferences.isEnabled(userDefaults: defaults, environment: [:]))
        defaults.set(true, forKey: CaptureTelemetryPreferences.userDefaultsKey)
        XCTAssertTrue(CaptureTelemetryPreferences.isEnabled(userDefaults: defaults, environment: [:]))
        XCTAssertFalse(CaptureTelemetryPreferences.isEnabled(
            userDefaults: defaults, environment: [CaptureTelemetryPreferences.environmentKey: "0"]
        ))
        defaults.removeObject(forKey: CaptureTelemetryPreferences.userDefaultsKey)
        XCTAssertTrue(CaptureTelemetryPreferences.isEnabled(
            userDefaults: defaults, environment: [CaptureTelemetryPreferences.environmentKey: "1"]
        ))
    }

    func testLockedMicTelemetryRecordsNothingUntilEnabled() {
        let mic = LockedCaptureSignalTelemetry()
        XCTAssertFalse(mic.isEnabled)
        for second in 0..<3 { XCTAssertNil(mic.record(buffer { _ in 0.5 }, arrival: TimeInterval(second))) }
        mic.reset(enabled: true)
        XCTAssertNil(mic.record(buffer { _ in 0.5 }, arrival: 10))
        XCTAssertNotNil(mic.record(buffer { _ in 0.5 }, arrival: 11))
        mic.reset(enabled: false)
        XCTAssertNil(mic.record(buffer { _ in 0.5 }, arrival: 20))
    }

    // MARK: Window math

    func testWindowLevelsAndSampleCounts() throws {
        var telemetry = CaptureSignalTelemetry()
        // 960 samples: half 0.5, a quarter zero, then one NaN, one Inf and
        // subnormals. NaN and Inf are counted but never reach peak or RMS.
        let mixed = buffer { index in
            switch index {
            case 0..<480: 0.5
            case 480..<720: 0
            case 720: .nan
            case 721: .infinity
            default: Float.leastNormalMagnitude / 4
            }
        }
        XCTAssertNil(telemetry.record(mixed, arrival: 0, hostSeconds: nil))
        let fields = try XCTUnwrap(telemetry.flushIfDue(at: 1))
        XCTAssertEqual(fields["buffers"], "1")
        XCTAssertEqual(fields["frames"], "480")
        XCTAssertEqual(fields["peak_dbfs"], "-6.0")
        // RMS over all 960 samples: sqrt(480 * 0.25 / 960) = 0.3536 -> -9.0 dBFS.
        XCTAssertEqual(fields["rms_dbfs"], "-9.0")
        XCTAssertEqual(fields["zeros"], "240")
        XCTAssertEqual(fields["zero_ratio"], "0.250")
        XCTAssertEqual(fields["nonfinite"], "2")
        XCTAssertEqual(fields["subnormals"], "238")
        XCTAssertEqual(fields["window_ms"], "1000")
    }

    func testExactZerosReadAsMinusInfinity() throws {
        var telemetry = CaptureSignalTelemetry()
        _ = telemetry.record(buffer { _ in 0 }, arrival: 0, hostSeconds: nil)
        _ = telemetry.record(buffer { _ in -0.0 }, arrival: 0.5, hostSeconds: nil)
        let fields = try XCTUnwrap(telemetry.flushIfDue(at: 1))
        XCTAssertEqual(fields["peak_dbfs"], "-inf")
        XCTAssertEqual(fields["rms_dbfs"], "-inf")
        XCTAssertEqual(fields["zero_ratio"], "1.000")
    }

    func testFaintHissIsReportedInDBFS() throws {
        var telemetry = CaptureSignalTelemetry()
        _ = telemetry.record(buffer { $0.isMultiple(of: 2) ? 1e-4 : -1e-4 }, arrival: 0, hostSeconds: nil)
        let fields = try XCTUnwrap(telemetry.flushIfDue(at: 1))
        XCTAssertEqual(fields["peak_dbfs"], "-80.0")
        XCTAssertEqual(fields["rms_dbfs"], "-80.0")
        XCTAssertEqual(fields["zeros"], "0")
    }

    func testContinuityGapsAndHostJumps() throws {
        var telemetry = CaptureSignalTelemetry()
        let step = 480.0 / 48000 // 10 ms per buffer
        _ = telemetry.record(buffer { _ in 0.1 }, arrival: 0, hostSeconds: 50)
        _ = telemetry.record(buffer { _ in 0.1 }, arrival: 0.01, hostSeconds: 50 + step)
        // A 300 ms hole in both arrival and host time.
        _ = telemetry.record(buffer { _ in 0.1 }, arrival: 0.31, hostSeconds: 50 + 2 * step + 0.3)
        let fields = try XCTUnwrap(telemetry.flushIfDue(at: 1.0))
        XCTAssertEqual(fields["buffers"], "3")
        XCTAssertEqual(fields["host_min_ms"], "10.00")
        XCTAssertEqual(fields["host_max_ms"], "310.00")
        XCTAssertEqual(fields["host_jumps"], "1")
        // The longest wait is the 690 ms from the last buffer to the flush.
        XCTAssertEqual(fields["max_gap_ms"], "690")
    }

    func testEmptySecondStillFlushesAndWindowsChain() throws {
        var telemetry = CaptureSignalTelemetry()
        XCTAssertNil(telemetry.record(buffer { _ in 0.1 }, arrival: 0, hostSeconds: nil))
        XCTAssertNotNil(telemetry.flushIfDue(at: 1))
        XCTAssertNil(telemetry.flushIfDue(at: 1.5), "Not a second yet")
        let empty = try XCTUnwrap(telemetry.flushIfDue(at: 2))
        XCTAssertEqual(empty["buffers"], "0")
        XCTAssertEqual(empty["zero_ratio"], "n/a")
        XCTAssertEqual(empty["max_gap_ms"], "2000", "A stalled tap shows the time since its last buffer")
        XCTAssertEqual(telemetry.emittedWindows, 2)
    }

    // MARK: Route state

    func testRouteStateLogsOnlyChangedFields() {
        let usb = CaptureEndpointTelemetry(
            id: 70, transport: "usb", rate: 48000, alive: true, running: true,
            streams: 1, channels: 2, format: "48000/2ch/i24"
        )
        var before = CaptureDeviceTelemetryState(output: usb, input: usb, aggregate: nil)
        before.processesRunningOutput = 2
        XCTAssertEqual(CaptureDeviceTelemetryState.changes(from: nil, to: before)["out_class"], "usb", "First read logs everything")
        XCTAssertTrue(CaptureDeviceTelemetryState.changes(from: before, to: before).isEmpty)
        var after = before
        after.output?.rate = 16000
        after.zoomRunningInput = true
        XCTAssertEqual(CaptureDeviceTelemetryState.changes(from: before, to: after), [
            "out_rate": "48000->16000",
            "zoom_in": "false->true"
        ])
    }

    func testFieldsNeverCarryDeviceIdentityKeysTheLogSanitizerRedacts() {
        let endpoint = CaptureEndpointTelemetry(
            id: 1, transport: "usb", rate: 48000, alive: true, running: false,
            streams: 1, channels: 1, format: "48000/1ch/f32"
        )
        let state = CaptureDeviceTelemetryState(output: endpoint, input: endpoint, aggregate: endpoint)
        var telemetry = CaptureSignalTelemetry()
        _ = telemetry.record(buffer { _ in 0.1 }, arrival: 0, hostSeconds: 1)
        let window = telemetry.flushIfDue(at: 1) ?? [:]
        let fields = state.fields.merging(window) { $1 }
        XCTAssertEqual(LogPrivacySanitizer.sanitizeMetadata(fields), fields, "Every key survives the local log sanitizer unredacted")
    }

    // MARK: System tap wiring

    private final class HAL: @unchecked Sendable {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var now: TimeInterval = 100
        func makeCapture(telemetry: Bool? = nil) -> CoreAudioSystemAudioCapture {
            let hooks = CoreAudioSystemAudioCapture.HardwareHooks(
                prepare: { self.format }, start: {}, stop: {}, currentFormat: { self.format }
            )
            guard let telemetry else { return CoreAudioSystemAudioCapture(hardwareHooks: hooks, clock: { self.now }) }
            return CoreAudioSystemAudioCapture(hardwareHooks: hooks, clock: { self.now }, telemetryEnabled: telemetry)
        }
    }

    private func runThreeSeconds(_ hal: HAL, _ capture: CoreAudioSystemAudioCapture) {
        for _ in 0..<30 {
            hal.now += 0.1
            capture.receiveForTesting(buffer { _ in 0.1 })
            capture.drainForTesting()
        }
    }

    func testSystemTapTelemetryIsOffByDefault() throws {
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        runThreeSeconds(hal, capture)
        XCTAssertFalse(capture.telemetryEnabled)
        XCTAssertNil(capture.signalTelemetry)
        XCTAssertEqual(capture.captureTelemetryWindowCount, 0)
    }

    func testSystemTapTelemetryEmitsOneWindowPerSecondWhenOn() throws {
        let hal = HAL(), capture = hal.makeCapture(telemetry: true)
        try capture.start { _ in }
        runThreeSeconds(hal, capture)
        XCTAssertEqual(capture.captureTelemetryWindowCount, 2, "Three seconds close two whole windows")
        XCTAssertNil(capture.deviceTelemetry, "Fake HAL never installs real listeners")
        capture.stopSync()
        XCTAssertNil(capture.signalTelemetry, "Stop drops the window")
    }
}
