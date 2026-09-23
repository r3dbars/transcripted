import CoreAudio
import XCTest
@testable import TranscriptedCore

/// Covers the post-1.1.62 mic follow-ups: restart on an audio route change
/// without waiting for the watchdog, keep the meeting going after a failed
/// recovery, and fall back to the built-in mic.
final class MicRecoveryFallbackTests: XCTestCase {

    // MARK: - Engine configuration change

    func testRouteChangeThatStopsTheLiveMicRecoversRightAway() {
        XCTAssertEqual(configurationDecision(), .recover)
        XCTAssertEqual(
            configurationDecision(secondsSinceLastRecoveryEnded: 30),
            .recover,
            "an old recovery must not hold back a new route change"
        )
    }

    func testRouteChangeLeavesAFlowingMicAlone() {
        XCTAssertEqual(
            configurationDecision(changedEngineIsRunning: true, deliveredNewBuffer: true),
            .stillFlowing
        )
    }

    func testLastTapBlockAfterTheEngineStoppedIsNotFlowing() {
        // AVAudioEngine can hand over one queued tap block after the route
        // change stopped it. The mic is still down.
        XCTAssertEqual(
            configurationDecision(changedEngineIsRunning: false, deliveredNewBuffer: true),
            .recover
        )
    }

    func testRouteChangeIgnoresOtherEnginesAndFinishedRecordings() {
        XCTAssertEqual(
            configurationDecision(changedEngineIsPublishedGraph: false),
            .ignore,
            "dictation's engine and detached graphs are not the meeting mic"
        )
        XCTAssertEqual(configurationDecision(sessionIsCurrent: false), .ignore)
        XCTAssertEqual(configurationDecision(isRecording: false), .ignore)
        XCTAssertEqual(
            configurationDecision(isSystemSleeping: true),
            .ignore,
            "the wake handler owns recovery while the Mac sleeps"
        )
    }

    func testRouteChangeDuringAnotherRecoveryWaitsInsteadOfDoubling() {
        XCTAssertEqual(
            configurationDecision(isRecovering: true),
            .waitForRecovery
        )
    }

    func testRouteChangeRightAfterARecoveryIsLeftToTheWatchdog() {
        XCTAssertEqual(
            configurationDecision(secondsSinceLastRecoveryEnded: 0.2),
            .leaveToWatchdog,
            "a flapping route must not rebuild the graph back to back"
        )
    }

    func testRouteChangeNeverRecoversPastTheWatchdogsLimit() {
        XCTAssertEqual(
            configurationDecision(recoveryAttemptsUsed: 5),
            .leaveToWatchdog,
            "the watchdog decides when a failing mic gives up"
        )
        XCTAssertEqual(configurationDecision(recoveryAttemptsUsed: 4), .recover)
    }

    func testRouteChangeLeavesARunningEngineAlone() {
        // A graph that was still being built can post the change and then
        // start; a slow first frame there is not a stopped mic.
        XCTAssertEqual(
            configurationDecision(changedEngineIsRunning: true),
            .engineStillRunning
        )
    }

    // MARK: - Built-in fallback during recovery

    func testFirstRecoveryOfAWorkingMicKeepsThePinnedMic() {
        XCTAssertFalse(
            MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
                reason: .deviceChange,
                recoveryAttemptNumber: 1,
                micHasDeliveredAudio: true
            )
        )
    }

    func testRetryAfterAFailedRecoveryTriesTheBuiltInMicFirst() {
        XCTAssertTrue(
            MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
                reason: .deviceChange,
                recoveryAttemptNumber: 2,
                micHasDeliveredAudio: true
            )
        )
    }

    func testMicThatNeverDeliveredAudioTriesTheBuiltInMicFirst() {
        XCTAssertTrue(
            MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
                reason: .deviceChange,
                recoveryAttemptNumber: 1,
                micHasDeliveredAudio: false
            )
        )
    }

    func testProcessingRestartNeverSwitchesMics() {
        XCTAssertFalse(
            MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
                reason: .processingChange,
                recoveryAttemptNumber: 3,
                micHasDeliveredAudio: false
            )
        )
    }

    func testFailedInPlaceRestartGivesThePinnedMicOneFreshGraphFirst() {
        XCTAssertFalse(
            MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
                reason: .deviceChange,
                recoveryAttemptNumber: 2,
                micHasDeliveredAudio: true,
                inPlaceRestartJustFailed: true
            )
        )
        XCTAssertTrue(
            MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
                reason: .deviceChange,
                recoveryAttemptNumber: 2,
                micHasDeliveredAudio: false,
                inPlaceRestartJustFailed: true
            ),
            "a mic that never delivered audio still moves to the built-in mic"
        )
    }

    // MARK: - In-place restart

    func testRouteChangeRestartsThePinnedMicInPlace() {
        XCTAssertTrue(inPlaceDecision())
    }

    func testInPlaceRestartNeverReopensTheDefaultInput() {
        XCTAssertFalse(
            inPlaceDecision(boundInputID: 99),
            "a node bound elsewhere needs a fresh graph and a new pin"
        )
        XCTAssertFalse(inPlaceDecision(pinnedInputID: nil))
        XCTAssertFalse(inPlaceDecision(boundInputID: nil))
    }

    func testInPlaceRestartSkipsCasesThatNeedAFreshGraph() {
        XCTAssertFalse(inPlaceDecision(reason: .processingChange))
        XCTAssertFalse(inPlaceDecision(freshGraphRequested: true))
        XCTAssertFalse(inPlaceDecision(pinnedInputIsAlive: false), "an unplugged mic cannot be reused")
        XCTAssertFalse(inPlaceDecision(pinnedInputIsBluetooth: true))
        XCTAssertFalse(inPlaceDecision(voiceProcessingEnabled: true))
    }

    func testInPlaceRestartRequiresTheDeviceFormatToStillMatch() {
        XCTAssertTrue(
            MicInPlaceRestartPolicy.formatStillMatchesDevice(
                capturedSampleRate: 48_000,
                deviceNominalSampleRate: 48_000
            )
        )
        XCTAssertFalse(
            MicInPlaceRestartPolicy.formatStillMatchesDevice(
                capturedSampleRate: 48_000,
                deviceNominalSampleRate: 44_100
            )
        )
        XCTAssertFalse(
            MicInPlaceRestartPolicy.formatStillMatchesDevice(
                capturedSampleRate: 48_000,
                deviceNominalSampleRate: nil
            )
        )
        XCTAssertFalse(
            MicInPlaceRestartPolicy.formatStillMatchesDevice(
                capturedSampleRate: 48_000,
                deviceNominalSampleRate: 0
            )
        )
    }

    // MARK: - Gap anchor across a failed-recovery streak

    func testFirstAttemptPadsFromTheLastFrameSeen() {
        XCTAssertEqual(
            MicRecoveryGapAnchorPolicy.anchor(closedSegmentThisAttempt: true, storedAnchor: 10, lastBufferTime: 50),
            50
        )
    }

    func testRetryPadsFromTheLastFrameTheRecordingKept() {
        // A failed in-place attempt took frames from a re-bound input at 54;
        // they were deleted with its segment.
        XCTAssertEqual(
            MicRecoveryGapAnchorPolicy.anchor(closedSegmentThisAttempt: false, storedAnchor: 50, lastBufferTime: 54),
            50
        )
        XCTAssertEqual(
            MicRecoveryGapAnchorPolicy.anchor(closedSegmentThisAttempt: false, storedAnchor: nil, lastBufferTime: 54),
            54
        )
    }

    // MARK: - Writer handoff after a failed recovery

    func testRecoveryCanReplaceASegmentAnEarlierFailedAttemptAlreadyClosed() {
        let ownership = MicWriterOwnership<TestWriter>()
        let original = TestWriter()
        ownership.installSessionWriter(original, generation: 7)

        guard case .retired(let retired) = ownership.retireWriterForRecovery(by: 7) else {
            return XCTFail("the first recovery should retire the open writer")
        }
        XCTAssertTrue(retired === original)

        // The failed attempt removed its own recovery writer, leaving none.
        guard case .alreadyRetired = ownership.retireWriterForRecovery(by: 7) else {
            return XCTFail("the retry must still own the recording")
        }
        let replacement = TestWriter()
        XCTAssertTrue(ownership.installRecoveryWriter(replacement, generation: 7))
        XCTAssertTrue(ownership.writerOwned(by: 7) === replacement)
    }

    func testRecoveryRetireRejectsAnotherRecording() {
        let ownership = MicWriterOwnership<TestWriter>()
        ownership.installSessionWriter(TestWriter(), generation: 7)

        guard case .notOwned = ownership.retireWriterForRecovery(by: 6) else {
            return XCTFail("a stale recovery must not take a newer recording's writer")
        }
        _ = ownership.takeWriterOwned(by: 7, invalidatingFor: 8)
        guard case .notOwned = ownership.retireWriterForRecovery(by: 7) else {
            return XCTFail("a recovery that outlived Stop must not continue")
        }
    }

    // MARK: - Built-in fallback selection

    func testFailedExternalMicFallsBackToTheBuiltInMic() {
        let usbMic = device(id: 30, name: "USB Audio Device", transport: .usb)
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn)
        let speakers = device(id: 21, name: "MacBook Pro Speakers", transport: .builtIn)

        let fallback = MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
            failedInputID: usbMic.id,
            defaultInput: usbMic,
            defaultOutput: speakers,
            availableInputs: [usbMic, builtInMic]
        )

        XCTAssertEqual(fallback?.selectedInput, builtInMic)
        XCTAssertEqual(fallback?.reason, .builtInFallbackAfterFailure)
        XCTAssertEqual(fallback?.didOverrideDefault, true)
    }

    func testClosedLidSkipsTheLaptopMicForADisplayMic() {
        // Clamshell: the MacBook mic is cut off in hardware and would record
        // silence without ever failing.
        let usbMic = device(id: 30, name: "USB Audio Device", transport: .usb)
        let laptopMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn)
        let displayMic = device(id: 50, name: "Studio Display Microphone", transport: .usb)

        let fallback = MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
            failedInputID: usbMic.id,
            defaultInput: usbMic,
            defaultOutput: nil,
            availableInputs: [usbMic, laptopMic, displayMic],
            lidIsClosed: true
        )
        XCTAssertEqual(fallback?.selectedInput, displayMic)
    }

    func testClosedLidWithOnlyTheLaptopMicHasNoFallback() {
        let usbMic = device(id: 30, name: "USB Audio Device", transport: .usb)
        let laptopMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn)

        XCTAssertNil(
            MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
                failedInputID: usbMic.id,
                defaultInput: usbMic,
                defaultOutput: nil,
                availableInputs: [usbMic, laptopMic],
                lidIsClosed: true
            )
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
                failedInputID: usbMic.id,
                defaultInput: usbMic,
                defaultOutput: nil,
                availableInputs: [usbMic, laptopMic],
                lidIsClosed: false
            )?.selectedInput,
            laptopMic,
            "with the lid open the laptop mic is the fallback"
        )
    }

    func testNoFallbackWhenTheBuiltInMicIsTheOneThatFailed() {
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn)
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth)

        XCTAssertNil(
            MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
                failedInputID: builtInMic.id,
                defaultInput: airPods,
                defaultOutput: airPods,
                availableInputs: [airPods, builtInMic]
            )
        )
    }

    func testNoFallbackWithoutABuiltInMic() {
        let usbMic = device(id: 30, name: "USB Audio Device", transport: .usb)
        let zoomAudio = device(id: 40, name: "ZoomAudioDevice", transport: .virtual)

        XCTAssertNil(
            MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
                failedInputID: usbMic.id,
                defaultInput: usbMic,
                defaultOutput: nil,
                availableInputs: [usbMic, zoomAudio]
            ),
            "virtual devices are not a microphone to fall back to"
        )
    }

    func testFailedBuiltInFallbackCountsAsAFailedSwitch() {
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.outcomeAfterApplicationFailure(
                selectionReason: .builtInFallbackAfterFailure,
                requestedOutcome: .notNeeded
            ),
            .switchFailed,
            "an unapplied fallback must not accept whatever the node was bound to"
        )
    }

    // MARK: - Helpers

    private final class TestWriter {}

    private func configurationDecision(
        sessionIsCurrent: Bool = true,
        isRecording: Bool = true,
        isSystemSleeping: Bool = false,
        isRecovering: Bool = false,
        changedEngineIsPublishedGraph: Bool = true,
        changedEngineIsRunning: Bool = false,
        deliveredNewBuffer: Bool = false,
        secondsSinceLastRecoveryEnded: TimeInterval? = nil,
        recoveryAttemptsUsed: Int = 0
    ) -> MicEngineConfigurationChangePolicy.Decision {
        MicEngineConfigurationChangePolicy.decision(
            sessionIsCurrent: sessionIsCurrent,
            isRecording: isRecording,
            isSystemSleeping: isSystemSleeping,
            isRecovering: isRecovering,
            changedEngineIsPublishedGraph: changedEngineIsPublishedGraph,
            changedEngineIsRunning: changedEngineIsRunning,
            deliveredNewBuffer: deliveredNewBuffer,
            secondsSinceLastRecoveryEnded: secondsSinceLastRecoveryEnded,
            recoveryAttemptsUsed: recoveryAttemptsUsed,
            maxRecoveryAttempts: 5
        )
    }

    private func inPlaceDecision(
        reason: MicCaptureRestartReason = .deviceChange,
        freshGraphRequested: Bool = false,
        pinnedInputID: AudioDeviceID? = 30,
        pinnedInputIsBluetooth: Bool = false,
        pinnedInputIsAlive: Bool = true,
        boundInputID: AudioDeviceID? = 30,
        voiceProcessingEnabled: Bool = false
    ) -> Bool {
        MicInPlaceRestartPolicy.canRestartInPlace(
            reason: reason,
            freshGraphRequested: freshGraphRequested,
            pinnedInputID: pinnedInputID,
            pinnedInputIsBluetooth: pinnedInputIsBluetooth,
            pinnedInputIsAlive: pinnedInputIsAlive,
            boundInputID: boundInputID,
            voiceProcessingEnabled: voiceProcessingEnabled
        )
    }

    private func device(
        id: AudioDeviceID,
        name: String,
        transport: MeetingAudioTransport
    ) -> MeetingAudioDevice {
        MeetingAudioDevice(
            id: id,
            name: name,
            transport: transport,
            inputChannelCount: 1
        )
    }
}
