import XCTest
@preconcurrency import AVFoundation
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioStateTransitionTests: XCTestCase {

    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStateTransitionTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        super.tearDown()
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

    // MARK: - updateSystemAudioStatus(fromError:)

    func testUpdateSystemAudioStatusForcesUnknownWhenNotRecording() {
        let audio = makeAudio()
        audio.systemAudioStatus = .healthy
        // isRecording defaults to false — the guard should override the prior status.
        audio.updateSystemAudioStatus(fromError: "device unavailable")
        XCTAssertEqual(audio.systemAudioStatus, .unknown)
    }

    func testUpdateSystemAudioStatusEntersReconnectingOnSwitchedMessage() {
        let audio = makeAudio()
        audio.isRecording = true
        audio.systemAudioStatus = .healthy

        audio.updateSystemAudioStatus(fromError: "Switched to default output device")

        XCTAssertEqual(audio.systemAudioStatus, .reconnecting)
    }

    func testUpdateSystemAudioStatusMarksFailedForUnavailableMessage() {
        let audio = makeAudio()
        audio.isRecording = true
        audio.systemAudioStatus = .healthy

        audio.updateSystemAudioStatus(fromError: "System audio unavailable")
        XCTAssertEqual(audio.systemAudioStatus, .failed)
    }

    func testUpdateSystemAudioStatusMarksFailedForFailedMessage() {
        let audio = makeAudio()
        audio.isRecording = true
        audio.systemAudioStatus = .reconnecting

        audio.updateSystemAudioStatus(fromError: "capture failed unexpectedly")
        XCTAssertEqual(audio.systemAudioStatus, .failed)
        XCTAssertTrue(audio.systemAudioFailed)
    }

    func testUpdateSystemAudioStatusKeepsSilentWhenClearedDuringRecording() {
        let audio = makeAudio()
        audio.isRecording = true
        audio.systemAudioStatus = .silent

        // Nil error means "no problem from the capture engine"; .silent must stick
        // because it was set by the prolonged-silence tracker, not by an error.
        audio.updateSystemAudioStatus(fromError: nil)

        XCTAssertEqual(audio.systemAudioStatus, .silent)
    }

    func testUpdateSystemAudioStatusReturnsToHealthyWhenClearedFromReconnecting() {
        let audio = makeAudio()
        audio.isRecording = true
        audio.systemAudioStatus = .reconnecting

        audio.updateSystemAudioStatus(fromError: nil)

        XCTAssertEqual(audio.systemAudioStatus, .healthy)
    }

    func testUpdateSystemAudioStatusIgnoresUnrelatedErrorText() {
        let audio = makeAudio()
        audio.isRecording = true
        audio.systemAudioStatus = .healthy

        // Message does not match either "Switched" or "unavailable"/"failed";
        // status should be left untouched (no else-branch reset).
        audio.updateSystemAudioStatus(fromError: "transient glitch")

        XCTAssertEqual(audio.systemAudioStatus, .healthy)
    }

    // MARK: - Signal peak accumulation edge cases

    func testRecordMicSignalPeaksTakesMaxAcrossCalls() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        audio.recordMicSignalPeaks(raw: 0.10, processed: 0.40, appliedGain: nil, agcMaxGain: nil)
        audio.recordMicSignalPeaks(raw: 0.05, processed: 0.55, appliedGain: nil, agcMaxGain: nil)
        audio.recordMicSignalPeaks(raw: 0.22, processed: 0.30, appliedGain: nil, agcMaxGain: nil)

        let snapshot = audio.signalDiagnosticsSnapshot
        XCTAssertEqual(snapshot.micRawPeak, 0.22, accuracy: 1e-5)
        XCTAssertEqual(snapshot.micProcessedPeak, 0.55, accuracy: 1e-5)
    }

    func testRecordSystemSignalPeakTakesMaxAcrossCalls() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        audio.recordSystemSignalPeak(0.1)
        audio.recordSystemSignalPeak(0.4)
        audio.recordSystemSignalPeak(0.2)

        XCTAssertEqual(audio.signalDiagnosticsSnapshot.systemAudioPeak, 0.4, accuracy: 1e-5)
    }

    func testNegativeSignalPeaksAreFloorClampedInDiagnosticsString() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        // Negative inputs can't push the recorded peak below 0 because the
        // accumulator starts at 0 and uses max(). The diagnostics string then
        // formats the floored value.
        audio.recordMicSignalPeaks(raw: -0.5, processed: -0.25, appliedGain: nil, agcMaxGain: nil)
        audio.recordSystemSignalPeak(-0.1)

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.micRawPeak, "0.00000")
        XCTAssertEqual(snapshot.micProcessedPeak, "0.00000")
        XCTAssertEqual(snapshot.systemAudioPeak, "0.00000")
    }

    func testNonFinitePeakValuesAreReportedAsZeroString() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        audio.recordMicSignalPeaks(raw: .nan, processed: .infinity, appliedGain: nil, agcMaxGain: nil)
        audio.recordSystemSignalPeak(.nan)

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.micRawPeak, "0.00000")
        XCTAssertEqual(snapshot.micProcessedPeak, "0.00000")
        XCTAssertEqual(snapshot.systemAudioPeak, "0.00000")
    }

    func testPeakValuesAboveOneAreClampedToUnityForReporting() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        audio.recordMicSignalPeaks(raw: 4.2, processed: 9.9, appliedGain: nil, agcMaxGain: nil)
        audio.recordSystemSignalPeak(3.0)

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.micRawPeak, "1.00000")
        XCTAssertEqual(snapshot.micProcessedPeak, "1.00000")
        XCTAssertEqual(snapshot.systemAudioPeak, "1.00000")
    }

    // MARK: - prepareForNewRecordingStart side effects

    func testPrepareForNewRecordingStartBumpsSessionGenerationAndClearsHealthCounters() {
        let audio = makeAudio()
        audio.appendRecordingGap(Audio.AudioGap(start: Date(), duration: 0.5, reason: "Sleep/wake"))
        audio.deviceSwitchCount = 3
        audio.recoveryAttemptCount = 2
        audio.consecutiveMicWriteErrors = 5
        audio.consecutiveSystemWriteErrors = 7
        audio.sleepTimestamp = Date()
        audio.lastRecoveryTime = Date()
        let before = audio.recordingSessionGeneration

        audio.prepareForNewRecordingStart()

        XCTAssertEqual(audio.recordingSessionGeneration, before &+ 1)
        XCTAssertTrue(audio.recordingGaps.isEmpty)
        XCTAssertEqual(audio.deviceSwitchCount, 0)
        XCTAssertEqual(audio.recoveryAttemptCount, 0)
        XCTAssertEqual(audio.consecutiveMicWriteErrors, 0)
        XCTAssertEqual(audio.consecutiveSystemWriteErrors, 0)
        XCTAssertNil(audio.sleepTimestamp)
        XCTAssertNil(audio.lastRecoveryTime)
        XCTAssertEqual(audio.systemAudioStatus, .healthy)
        XCTAssertNil(audio.systemAudioSilenceStart)
    }

    // MARK: - AudioGap description

    func testAudioGapDescriptionRendersReasonAndOneDecimalDuration() {
        let gap = Audio.AudioGap(start: Date(), duration: 2.34, reason: "Sleep/wake")
        XCTAssertEqual(gap.description, "Sleep/wake: 2.3s")
    }

    func testAudioGapDescriptionTruncatesSubMillisecondPrecision() {
        let gap = Audio.AudioGap(start: Date(), duration: 12.345_678, reason: "Device switch")
        // %.1f keeps a single fractional digit so the snapshot never bloats the log line.
        XCTAssertEqual(gap.description, "Device switch: 12.3s")
    }

    // MARK: - assignSystemAudioFileURLIfCurrent generation gating

    func testAssignSystemAudioFileURLIgnoresStaleGenerationAndKeepsUnknownStatus() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        let staleGeneration = audio.recordingSessionGeneration &- 1

        audio.updateSystemAudioStatus(fromError: nil)
        XCTAssertEqual(audio.systemAudioStatus, .unknown)

        let staleURL = rootURL.appendingPathComponent("stale-system.wav")
        audio.assignSystemAudioFileURLIfCurrent(staleURL, sessionGeneration: staleGeneration)

        XCTAssertNil(audio.systemAudioFileURL,
                     "system file URL from a stale session must not leak into the active session")
        XCTAssertEqual(audio.systemAudioStatus, .unknown,
                       "status repair must not fire for stale assignments")
    }

    func testSystemWriteFailureCapReturnsTerminalFailure() {
        let audio = makeAudio()

        for _ in 1..<audio.maxConsecutiveWriteErrors {
            XCTAssertFalse(audio.recordSystemWriteFailure(NSError(domain: "test", code: 1)))
        }

        XCTAssertTrue(audio.recordSystemWriteFailure(NSError(domain: "test", code: 1)))
        XCTAssertEqual(audio.consecutiveSystemWriteErrors, audio.maxConsecutiveWriteErrors)
    }

    // MARK: - createRouteVolumeDiagnosticsContext multi-phase

    func testRouteVolumeDiagnosticsContextSurfacesArbitraryPhaseSuffix() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        let duringContext = audio.createRouteVolumeDiagnosticsContext(currentPhase: "during")

        XCTAssertNotNil(duringContext["default_input_volume_before"])
        XCTAssertNotNil(duringContext["default_input_volume_during"])
        XCTAssertNotNil(duringContext["default_output_volume_during"])
        XCTAssertNotNil(duringContext["default_system_output_volume_during"])
        // Six total keys: three scopes x two phases (before + during).
        XCTAssertEqual(duringContext.count, 6)
    }

    func testRouteVolumeDiagnosticsBeforePhaseFallsBackToUnavailableWithoutPreparedSnapshot() {
        let audio = makeAudio()
        // No prepareForNewRecordingStart() — recordingStartRouteVolumeSnapshot is nil.

        let context = audio.createRouteVolumeDiagnosticsContext(currentPhase: "after")

        XCTAssertEqual(context["default_input_volume_before"], "unavailable")
        XCTAssertEqual(context["default_output_volume_before"], "unavailable")
        XCTAssertEqual(context["default_system_output_volume_before"], "unavailable")
    }

    // MARK: - Pipeline diagnostics snapshot override

    func testPipelineSnapshotHonorsOverrideSystemAudioStatus() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        // Live status is .healthy after prepareForNewRecordingStart, but if a
        // pre-stop snapshot captured .failed the snapshot must surface it.
        XCTAssertEqual(audio.systemAudioStatus, .healthy)

        let snapshot = audio.createPipelineDiagnosticsSnapshot(overrideSystemAudioStatus: .failed)
        XCTAssertEqual(snapshot.systemStatus, "failed")
        XCTAssertEqual(snapshot.privacySafeContext["system_status"], "failed")
    }

    func testPipelineSnapshotDefaultsToLiveSystemStatusWhenNoOverrideProvided() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        audio.systemAudioStatus = .silent

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.systemStatus, "silent")
    }

    func testPipelineSnapshotReportsVoiceProcessingMicProcessingKey() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        audio.enableVoiceProcessing = true

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.privacySafeContext["mic_processing"], "apple_voice_processing")
        XCTAssertEqual(snapshot.privacySafeContext["voice_processing"], "true")
    }

    func testPipelineSnapshotReportsSoftwareAGCWhenVoiceProcessingDisabled() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        audio.enableVoiceProcessing = false

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.privacySafeContext["mic_processing"], "software_agc")
        XCTAssertEqual(snapshot.privacySafeContext["voice_processing"], "false")
    }

    func testPipelineSnapshotReflectsRecoveryAndGapCounters() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        audio.appendRecordingGap(Audio.AudioGap(start: Date(), duration: 1.0, reason: "Sleep/wake"))
        audio.appendRecordingGap(Audio.AudioGap(start: Date(), duration: 0.5, reason: "Device switch"))
        audio.deviceSwitchCount = 2
        audio.recoveryAttemptCount = 1
        audio.systemAudioFailed = true

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.gapCount, 2)
        XCTAssertEqual(snapshot.routeChangeCount, 2)
        XCTAssertEqual(snapshot.recoveryAttemptCount, 1)
        XCTAssertTrue(snapshot.systemFailed)
        XCTAssertEqual(snapshot.privacySafeContext["gap_count"], "2")
        XCTAssertEqual(snapshot.privacySafeContext["route_change_count"], "2")
        XCTAssertEqual(snapshot.privacySafeContext["recovery_attempt_count"], "1")
        XCTAssertEqual(snapshot.privacySafeContext["system_failed"], "true")
    }
}
