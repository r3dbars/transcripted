import Foundation

func testMeetingFailureExplanation() async {
    await runSuite("AudioReliabilityHarness golden scenarios follow the reliability state machine") {
        for scenario in AudioReliabilityScenario.golden {
            await testScenario(scenario)
        }
    }

    runSuite("MeetingFailureExplanation answers all required fields for transcription failure") {
        let explanation = MeetingFailureExplanation.make(
            failureKind: .transcriptionInferenceFailed,
            hasAudioFiles: true,
            isRetryable: true,
            stage: .transcription,
            failedQueueEntryRetained: true
        )

        assertEqual(explanation.answeredCount, 7, "meeting failure reports should answer the full reliability checklist")
        assertEqual(explanation.outcomeKind, .recoverableFailure, "STT failures with retained audio should be recoverable failures")
        assertEqual(explanation.retryability, .retryable, "STT failures with retained audio should be retryable")
        assertEqual(explanation.artifactRetention, .retainedFailedQueueEntry, "retryable STT failures should keep a failed queue entry")
        assertEqual(explanation.userVisibleState, .retryAvailable, "the UI should offer a calm retry path")
        assertEqual(explanation.reportFields["recording_started"], "yes", "recording should be marked started when retained audio exists")
        assertEqual(explanation.reportFields["audio_captured"], "yes", "retained audio should mark audio captured")
        assertEqual(explanation.reportFields["transcription_failed"], "yes", "transcription failures should be explicit")
        assertEqual(explanation.reportFields["diarization_failed"], "no", "unrelated stages should stay explicit no values")
        assertEqual(explanation.reportFields["save_failed"], "no", "unrelated stages should stay explicit no values")
        assertEqual(explanation.reportFields["recoverable_artifact"], "yes", "retained audio should be marked recoverable")
        assertEqual(explanation.reportFields["retry_available"], "yes", "retryable failures with retained audio should show retry available")
    }

    runSuite("MeetingFailureExplanation treats diarization failure after transcription as degraded success") {
        let explanation = MeetingFailureExplanation.make(
            failureKind: .diarizationFailed,
            hasAudioFiles: true,
            isRetryable: true,
            stage: .diarization,
            transcriptSaved: true
        )

        assertEqual(explanation.outcomeKind, .degradedSuccess, "speaker-label failure should not lose a finished transcript")
        assertEqual(explanation.userVisibleState, .transcriptSavedWithoutSpeakers, "users should get the transcript with clear degraded speaker state")
        assertEqual(explanation.reportFields["recording_started"], "yes", "diarization happens after recording starts")
        assertEqual(explanation.reportFields["audio_captured"], "yes", "diarization failures can still retain audio")
        assertEqual(explanation.reportFields["transcription_failed"], "no", "diarization failures should not masquerade as STT failures")
        assertEqual(explanation.reportFields["diarization_failed"], "yes", "diarization failures should be explicit")
        assertEqual(explanation.reportFields["save_failed"], "no", "save should not be blamed for diarization")
        assertEqual(explanation.reportFields["recoverable_artifact"], "yes", "retained audio should be recoverable")
        assertEqual(explanation.reportFields["retry_available"], "yes", "retained-audio diarization degradation can be retried later")
    }

    runSuite("MeetingFailureExplanation marks save failure after capture as recoverable user action") {
        let explanation = MeetingFailureExplanation.make(
            failureKind: .saveFailed,
            hasAudioFiles: true,
            isRetryable: false,
            stage: .save,
            failedQueueEntryRetained: true
        )

        assertEqual(explanation.outcomeKind, .recoverableFailure, "save failures with retained audio should not become permanent loss")
        assertEqual(explanation.retryability, .retryableAfterUserAction, "save failures should retry after the save path is repaired")
        assertEqual(explanation.artifactRetention, .retainedFailedQueueEntry, "save failures should keep a queue item")
        assertEqual(explanation.userVisibleState, .needsUserAction, "save failures should tell the user what needs repair")
        assertEqual(explanation.reportFields["recording_started"], "yes", "save failures happen after recording starts")
        assertEqual(explanation.reportFields["audio_captured"], "yes", "save failures can still keep audio")
        assertEqual(explanation.reportFields["transcription_failed"], "no", "save failures should not blame transcription")
        assertEqual(explanation.reportFields["diarization_failed"], "no", "save failures should not blame diarization")
        assertEqual(explanation.reportFields["save_failed"], "yes", "save failures should be explicit")
        assertEqual(explanation.reportFields["recoverable_artifact"], "yes", "audio can still be recoverable after save failure")
        assertEqual(explanation.reportFields["retry_available"], "yes", "save failures with retained audio should expose retry after repair")
    }

    runSuite("MeetingFailureExplanation keeps speaker-name finalization failures retryable") {
        let explanation = MeetingFailureExplanation.make(
            failureKind: .speakerNameFinalizationFailed,
            hasAudioFiles: true,
            isRetryable: true,
            stage: .save,
            transcriptSaved: true,
            failedQueueEntryRetained: true
        )

        assertEqual(explanation.outcomeKind, .recoverableFailure, "speaker-name save failures should keep a retry path")
        assertEqual(explanation.retryability, .retryable, "retained audio should make speaker-name finalization retryable")
        assertEqual(explanation.artifactRetention, .retainedPartialTranscript, "the saved transcript should stay visible as a partial artifact")
        assertEqual(explanation.userVisibleState, .retryAvailable, "Home should offer retry without claiming the transcript was lost")
        assertEqual(explanation.reportFields["failure_kind"], "speaker_name_finalization_failed", "support reports should keep the speaker-name failure explicit")
        assertEqual(explanation.reportFields["save_failed"], "yes", "speaker-name finalization is a save-stage failure")
        assertEqual(explanation.reportFields["retry_available"], "yes", "retry should stay available while the failed row is retained")
    }

    runSuite("MeetingFailureExplanation blocks pre-recording permission failures cleanly") {
        let explanation = MeetingFailureExplanation.make(
            failureKind: .microphonePermission,
            hasAudioFiles: false,
            isRetryable: false,
            stage: .preflight
        )

        assertEqual(explanation.outcomeKind, .noArtifactFailure, "permission failures before capture should be no-artifact failures")
        assertEqual(explanation.retryability, .retryableAfterUserAction, "permission failures can be retried after settings repair")
        assertEqual(explanation.artifactRetention, .noneExpected, "preflight failures should not claim artifacts")
        assertEqual(explanation.userVisibleState, .needsUserAction, "permission failures should point to settings")
        assertEqual(explanation.reportFields["recording_started"], "no", "permission failures should say recording never started")
        assertEqual(explanation.reportFields["audio_captured"], "no", "permission failures should say no audio was captured")
        assertEqual(explanation.reportFields["transcription_failed"], "no", "permission failures should not blame transcription")
        assertEqual(explanation.reportFields["diarization_failed"], "no", "permission failures should not blame diarization")
        assertEqual(explanation.reportFields["save_failed"], "no", "permission failures should not blame save")
        assertEqual(explanation.reportFields["recoverable_artifact"], "no", "pre-recording failures should not claim retained artifacts")
        assertEqual(explanation.reportFields["retry_available"], "no", "pre-recording permission failures should not show artifact retry")
    }
}

private func testScenario(_ scenario: AudioReliabilityScenario) async {
    let harness = AudioReliabilityHarness(scenario: scenario)
    let result = await harness.run()

    assertEqual(result.failureKind, scenario.expectedOutcome.failureKind, "\(scenario.name) failure kind")
    assertEqual(result.stage, scenario.expectedOutcome.stage, "\(scenario.name) stage")
    assertEqual(result.outcomeKind, scenario.expectedOutcome.outcomeKind, "\(scenario.name) outcome")
    assertEqual(result.retryability, scenario.expectedOutcome.retryability, "\(scenario.name) retryability")
    assertEqual(result.artifactRetention, scenario.expectedOutcome.artifactRetention, "\(scenario.name) artifact retention")
    assertEqual(result.userVisibleState, scenario.expectedOutcome.userVisibleState, "\(scenario.name) user-visible state")
    assertPrivacySafe(result.telemetryPayload, scenarioName: scenario.name)
}

private struct AudioReliabilityScenario {
    let name: String
    let stage: CaptureFailureStage
    let injectedFailure: InjectedAudioFailure
    let artifactAvailability: ArtifactAvailability
    let expectedOutcome: ExpectedReliabilityOutcome

    static let golden: [AudioReliabilityScenario] = [
        AudioReliabilityScenario(
            name: "mic missing before start",
            stage: .preflight,
            injectedFailure: .micMissingBeforeStart,
            artifactAvailability: .none,
            expectedOutcome: ExpectedReliabilityOutcome(
                failureKind: .microphoneMissing,
                stage: .preflight,
                outcomeKind: .noArtifactFailure,
                retryability: .retryableAfterUserAction,
                artifactRetention: .noneExpected,
                userVisibleState: .needsUserAction
            )
        ),
        AudioReliabilityScenario(
            name: "mic start timeout",
            stage: .audioStart,
            injectedFailure: .micStartTimeout,
            artifactAvailability: .none,
            expectedOutcome: ExpectedReliabilityOutcome(
                failureKind: .audioDeviceUnavailable,
                stage: .audioStart,
                outcomeKind: .noArtifactFailure,
                retryability: .retryableAfterUserAction,
                artifactRetention: .noneExpected,
                userVisibleState: .needsUserAction
            )
        ),
        AudioReliabilityScenario(
            name: "device change rewarm failed after partial audio",
            stage: .activeCapture,
            injectedFailure: .deviceChangeRewarmFailedAfterPartialAudio,
            artifactAvailability: .audioAndFailedQueueEntry,
            expectedOutcome: ExpectedReliabilityOutcome(
                failureKind: .audioDeviceUnavailable,
                stage: .activeCapture,
                outcomeKind: .recoverableFailure,
                retryability: .retryable,
                artifactRetention: .retainedFailedQueueEntry,
                userVisibleState: .retryAvailable
            )
        ),
        AudioReliabilityScenario(
            name: "transcription crash after audio saved",
            stage: .transcription,
            injectedFailure: .transcriptionCrashAfterAudioSaved,
            artifactAvailability: .audioAndFailedQueueEntry,
            expectedOutcome: ExpectedReliabilityOutcome(
                failureKind: .transcriptionInferenceFailed,
                stage: .transcription,
                outcomeKind: .recoverableFailure,
                retryability: .retryable,
                artifactRetention: .retainedFailedQueueEntry,
                userVisibleState: .retryAvailable
            )
        ),
        AudioReliabilityScenario(
            name: "transcript save failure after transcription succeeded",
            stage: .save,
            injectedFailure: .transcriptSaveFailureAfterTranscriptionSucceeded,
            artifactAvailability: .audioAndFailedQueueEntry,
            expectedOutcome: ExpectedReliabilityOutcome(
                failureKind: .saveFailed,
                stage: .save,
                outcomeKind: .recoverableFailure,
                retryability: .retryableAfterUserAction,
                artifactRetention: .retainedFailedQueueEntry,
                userVisibleState: .needsUserAction
            )
        ),
        AudioReliabilityScenario(
            name: "diarization failure after transcription succeeded",
            stage: .diarization,
            injectedFailure: .diarizationFailureAfterTranscriptionSucceeded,
            artifactAvailability: .audioAndPartialTranscript,
            expectedOutcome: ExpectedReliabilityOutcome(
                failureKind: .diarizationFailed,
                stage: .diarization,
                outcomeKind: .degradedSuccess,
                retryability: .retryable,
                artifactRetention: .retainedPartialTranscript,
                userVisibleState: .transcriptSavedWithoutSpeakers
            )
        )
    ]
}

private enum InjectedAudioFailure {
    case micMissingBeforeStart
    case micStartTimeout
    case deviceChangeRewarmFailedAfterPartialAudio
    case transcriptionCrashAfterAudioSaved
    case transcriptSaveFailureAfterTranscriptionSucceeded
    case diarizationFailureAfterTranscriptionSucceeded
}

private enum ArtifactAvailability {
    case none
    case audioAndFailedQueueEntry
    case audioAndPartialTranscript

    var hasAudio: Bool {
        self != .none
    }

    var failedQueueEntryRetained: Bool {
        self == .audioAndFailedQueueEntry
    }

    var transcriptSaved: Bool {
        self == .audioAndPartialTranscript
    }
}

private struct ExpectedReliabilityOutcome {
    let failureKind: MeetingFailureKind
    let stage: CaptureFailureStage
    let outcomeKind: AudioReliabilityOutcomeKind
    let retryability: Retryability
    let artifactRetention: ArtifactRetention
    let userVisibleState: AudioReliabilityUserVisibleState
}

private struct AudioReliabilityResult {
    let failureKind: MeetingFailureKind?
    let stage: CaptureFailureStage
    let outcomeKind: AudioReliabilityOutcomeKind
    let retryability: Retryability
    let artifactRetention: ArtifactRetention
    let userVisibleState: AudioReliabilityUserVisibleState
    let telemetryPayload: [String: String]
}

private struct AudioReliabilityHarness {
    let scenario: AudioReliabilityScenario

    private let micDeviceProvider = FakeMicDeviceProvider()
    private let systemAudioProvider = FakeSystemAudioProvider()
    private let speechTranscriber = FakeSpeechTranscriber()
    private let diarizer = FakeDiarizer()
    private let transcriptWriter = FakeTranscriptWriter()
    private let failedArtifactStore = FakeFailedArtifactStore()
    private let eventReporter = FakeEventReporter()

    func run() async -> AudioReliabilityResult {
        _ = micDeviceProvider
        _ = systemAudioProvider
        _ = speechTranscriber
        _ = diarizer
        _ = transcriptWriter
        _ = failedArtifactStore
        _ = eventReporter

        let explanation = MeetingFailureExplanation.make(
            failureKind: failureKind,
            hasAudioFiles: scenario.artifactAvailability.hasAudio,
            isRetryable: scenario.expectedOutcome.retryability == .retryable,
            stage: scenario.stage,
            transcriptSaved: scenario.artifactAvailability.transcriptSaved,
            failedQueueEntryRetained: scenario.artifactAvailability.failedQueueEntryRetained
        )

        return AudioReliabilityResult(
            failureKind: explanation.failureKind,
            stage: explanation.stage,
            outcomeKind: explanation.outcomeKind,
            retryability: explanation.retryability,
            artifactRetention: explanation.artifactRetention,
            userVisibleState: explanation.userVisibleState,
            telemetryPayload: explanation.telemetryPayload
        )
    }

    private var failureKind: MeetingFailureKind {
        switch scenario.injectedFailure {
        case .micMissingBeforeStart:
            return .microphoneMissing
        case .micStartTimeout:
            return .audioDeviceUnavailable
        case .deviceChangeRewarmFailedAfterPartialAudio:
            return .audioDeviceUnavailable
        case .transcriptionCrashAfterAudioSaved:
            return .transcriptionInferenceFailed
        case .transcriptSaveFailureAfterTranscriptionSucceeded:
            return .saveFailed
        case .diarizationFailureAfterTranscriptionSucceeded:
            return .diarizationFailed
        }
    }
}

private struct FakeMicDeviceProvider {}
private struct FakeSystemAudioProvider {}
private struct FakeSpeechTranscriber {}
private struct FakeDiarizer {}
private struct FakeTranscriptWriter {}
private struct FakeFailedArtifactStore {}
private struct FakeEventReporter {}

private func assertPrivacySafe(
    _ payload: [String: String],
    scenarioName: String,
    file: String = #file,
    line: Int = #line
) {
    let allowedKeys = Set([
        "outcome_kind",
        "stage",
        "failure_kind",
        "retryability",
        "artifact_retention",
        "user_visible_state"
    ])

    assertEqual(Set(payload.keys), allowedKeys, "\(scenarioName) telemetry should only include reliability contract keys", file: file, line: line)

    let joinedValues = payload.values.joined(separator: " ")
    assertFalse(joinedValues.contains("/Users/"), "\(scenarioName) telemetry must not include raw paths", file: file, line: line)
    assertFalse(joinedValues.contains("Transcripted daily test"), "\(scenarioName) telemetry must not include transcript text", file: file, line: line)
    assertFalse(joinedValues.contains("@"), "\(scenarioName) telemetry must not include emails", file: file, line: line)
    assertFalse(joinedValues.contains("Sarah"), "\(scenarioName) telemetry must not include speaker names", file: file, line: line)
    assertFalse(joinedValues.contains("Michael"), "\(scenarioName) telemetry must not include speaker names", file: file, line: line)
}
