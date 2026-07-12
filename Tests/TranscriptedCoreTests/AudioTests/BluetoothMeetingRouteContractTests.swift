import CoreAudio
import XCTest
@preconcurrency import AVFoundation
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class BluetoothMeetingRouteContractTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BluetoothMeetingRouteContractTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        super.tearDown()
    }

    func testMeetingBluetoothOutputUsesBuiltInMicFallback() {
        let airPodsInput = device(id: 10, name: "Justin's AirPods Pro", transport: .bluetooth, channels: 1)
        let airPodsOutput = device(id: 11, name: "Justin's AirPods Pro", transport: .bluetooth, channels: 0)
        let macBookMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
        XCTAssertEqual(selection.defaultOutput, airPodsOutput)
        XCTAssertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset)
        XCTAssertTrue(selection.didOverrideDefault)
    }

    func testMeetingHFPNamesAreSuspiciousEvenWhenTransportIsUnknown() {
        let hfpInput = device(id: 10, name: "Private Hands-Free HFP", transport: .other, channels: 1)
        let hfpOutput = device(id: 11, name: "Private Hands-Free HFP", transport: .other, channels: 0)
        let macBookMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: hfpInput,
            defaultOutput: hfpOutput,
            availableInputs: [hfpInput, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
        XCTAssertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset)
        XCTAssertTrue(selection.didOverrideDefault)
    }

    func testMeetingRouteChangeWhileRecordingDowngradesHealthWithoutFailingProof() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        audio.deviceSwitchCount = 1
        audio.appendRecordingGap(Audio.AudioGap(start: Date(), duration: 0.42, reason: "Device switch"))

        let health = RecordingHealthInfo.from(audio: audio, systemCapture: nil)
        let snapshot = audio.createPipelineDiagnosticsSnapshot()

        XCTAssertEqual(health.captureQuality, .good)
        XCTAssertEqual(health.deviceSwitches, 1)
        XCTAssertEqual(health.audioGaps, 1)
        XCTAssertEqual(snapshot.routeChangeCount, 1)
        XCTAssertEqual(snapshot.privacySafeContext["route_change_count"], "1")
        XCTAssertEqual(snapshot.privacySafeContext["gap_count"], "1")
    }

    func testRepeatedMeetingRouteChangesBecomeDegraded() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        audio.deviceSwitchCount = 3

        let health = RecordingHealthInfo.from(audio: audio, systemCapture: nil)

        XCTAssertEqual(health.captureQuality, .degraded)
        XCTAssertEqual(health.deviceSwitches, 3)
    }

    func testMeetingTapTeardownStopsRunningEngineBeforeRemovingTap() {
        XCTAssertEqual(
            AudioInputTapTeardownPolicy.steps(engineIsRunning: true),
            [.stopEngine, .waitForStoppedInputCallbacks, .removeInputTap]
        )
        XCTAssertEqual(
            AudioInputTapTeardownPolicy.steps(engineIsRunning: false),
            [.removeInputTap]
        )
    }

    func testMeetingRecordingFormatSnapshotKeepsMockedTapSampleRateStable() throws {
        let hfpHardwareRate = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let tapBufferRate = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        XCTAssertEqual(AudioRecordingFormatPolicy.snapshot(hfpHardwareRate)?.sampleRate, 24_000)
        XCTAssertEqual(AudioRecordingFormatPolicy.snapshot(tapBufferRate)?.sampleRate, 48_000)
        XCTAssertEqual(AudioRecordingFormatPolicy.displaySampleRate(tapBufferRate.sampleRate), "48000")
    }

    private func makeAudio() -> Audio {
        let paths = CoreStoragePaths(
            transcripts: rootURL.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: rootURL.appendingPathComponent("state/speakers.sqlite"),
            statsDB: rootURL.appendingPathComponent("state/stats.sqlite"),
            failedQueue: rootURL.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: rootURL.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: rootURL.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: rootURL.appendingPathComponent("logs", isDirectory: true)
        )
        return Audio(paths: paths)
    }

    private func device(
        id: AudioDeviceID,
        name: String,
        transport: MeetingAudioTransport,
        channels: UInt32
    ) -> MeetingAudioDevice {
        MeetingAudioDevice(
            id: id,
            name: name,
            transport: transport,
            inputChannelCount: channels
        )
    }
}
