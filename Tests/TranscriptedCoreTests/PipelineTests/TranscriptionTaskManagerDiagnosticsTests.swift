import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testPipelineModelReadinessReloadsModelsAfterCleanup() async throws {
        let speech = MetadataStubSpeechToTextEngine(isReady: false)
        let diarization = MetadataStubDiarizationEngine(isReady: false)
        let manager = makeManager(speechToText: speech, diarization: diarization)

        try await manager.transcription.ensureModelsReadyForPipeline()

        XCTAssertTrue(speech.isReady)
        XCTAssertTrue(diarization.isReady)
        XCTAssertEqual(speech.initializeCallCount, 1)
        XCTAssertEqual(diarization.initializeCallCount, 1)

        speech.cleanup()
        diarization.cleanup()

        try await manager.transcription.ensureModelsReadyForPipeline()

        XCTAssertTrue(speech.isReady)
        XCTAssertTrue(diarization.isReady)
        XCTAssertEqual(speech.initializeCallCount, 2)
        XCTAssertEqual(diarization.initializeCallCount, 2)
    }

    func testSafeFailureDiagnosticMessageKeepsTypedRootCause() {
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "/Users/redbars/private/path")
            ),
            "Parakeet inference failed"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.saveFailed(detail: "/Users/redbars/private/transcript.md")
            ),
            "Failed to save transcript"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.unknown(underlying: "PyAnnote failed while reading /Users/redbars/audio.wav")
            ),
            "Diarization failed"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.unknown(underlying: "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error 2003334207.)")
            ),
            "Invalid audio format"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.noSpeechDetected
            ),
            "No speech detected"
        )
    }

    func testFinalizedFailedAudioPromotionPreservesExistingSystemAudioWhenCallbackHasOnlyMic() throws {
        let manager = makeManager()
        let failedId = UUID()
        let originalMicURL = tempDirectory.appendingPathComponent("audio/timeout-mic.wav")
        let finalizedMicURL = tempDirectory.appendingPathComponent("audio/timeout-mic-final.wav")
        let existingSystemURL = tempDirectory.appendingPathComponent("audio/timeout-system.wav")
        FileManager.default.createFile(atPath: originalMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: finalizedMicURL.path, contents: Data("final-mic".utf8))
        FileManager.default.createFile(atPath: existingSystemURL.path, contents: Data("system".utf8))

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            id: failedId,
            micAudioURL: originalMicURL,
            systemAudioURL: existingSystemURL,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))

        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: finalizedMicURL,
            systemAudioURL: nil
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.micAudioURL, finalizedMicURL)
        XCTAssertEqual(failed.systemAudioURL, existingSystemURL)
    }

}
