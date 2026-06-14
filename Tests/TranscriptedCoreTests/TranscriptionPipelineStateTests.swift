import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class TranscriptionPipelineStateTests: XCTestCase {

    // MARK: - embeddingWeight boundary classification

    func testEmbeddingWeightTreatsBoundaryFractionsAsLowerTier() {
        // Switch ranges are 0.5..., 0.3..., default — so exact boundary
        // values land in the lower-weight tier (heavier contamination).
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: 0.0), 1.0)
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: 0.3), 0.5)
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: 0.5), 0.2)
        // 0.8 is the cutoff: `if micFraction > 0.8 { return nil }` — exactly
        // 0.8 is still allowed (heaviest contamination tier).
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: 0.8), 0.2)
    }

    func testEmbeddingWeightRejectsExcessiveOverlap() {
        XCTAssertNil(Transcription.embeddingWeight(forMicFraction: 0.81))
        XCTAssertNil(Transcription.embeddingWeight(forMicFraction: 1.0))
        XCTAssertNil(Transcription.embeddingWeight(forMicFraction: 2.5))
    }

    func testEmbeddingWeightTreatsNegativeFractionAsClean() {
        // Defensive: caller never passes <0, but the switch must not crash.
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: -0.1), 1.0)
    }

    // MARK: - mergeConsecutiveUtterances edge cases

    func testMergeConsecutiveUtterancesReturnsInputForEmptyOrSingle() {
        XCTAssertTrue(Transcription.mergeConsecutiveUtterances([], maxGap: 1.5).isEmpty)

        let solo = [utterance(start: 0, end: 1, speakerId: 1, transcript: "Alone")]
        let merged = Transcription.mergeConsecutiveUtterances(solo, maxGap: 1.5)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].transcript, "Alone")
    }

    func testMergeConsecutiveUtterancesSplitsAtSpeakerBoundary() {
        let merged = Transcription.mergeConsecutiveUtterances(
            [
                utterance(start: 0.0, end: 1.0, speakerId: 1, transcript: "A"),
                utterance(start: 1.1, end: 2.0, speakerId: 2, transcript: "B"),
                utterance(start: 2.1, end: 3.0, speakerId: 1, transcript: "C"),
            ],
            maxGap: 1.5
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map(\.transcript), ["A", "B", "C"])
    }

    func testMergeConsecutiveUtterancesEnforcesMaxDurationCap() {
        // Three same-speaker utterances each ~14s long, small gaps. With
        // maxDuration=30 the third one cannot extend the merged span beyond
        // 30s, so the run should break into two output utterances.
        let merged = Transcription.mergeConsecutiveUtterances(
            [
                utterance(start: 0.0, end: 14.0, speakerId: 5, transcript: "one"),
                utterance(start: 14.5, end: 28.0, speakerId: 5, transcript: "two"),
                utterance(start: 28.5, end: 42.0, speakerId: 5, transcript: "three"),
            ],
            maxGap: 1.5,
            maxDuration: 30.0
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].transcript, "one two")
        XCTAssertEqual(merged[0].end, 28.0, accuracy: 0.000_1)
        XCTAssertEqual(merged[1].transcript, "three")
        XCTAssertEqual(merged[1].start, 28.5, accuracy: 0.000_1)
    }

    func testMergeConsecutiveUtterancesKeepsSeparateWhenGapExceedsThreshold() {
        let merged = Transcription.mergeConsecutiveUtterances(
            [
                utterance(start: 0.0, end: 1.0, speakerId: 1, transcript: "first"),
                utterance(start: 3.5, end: 4.5, speakerId: 1, transcript: "second"),
            ],
            maxGap: 1.5
        )

        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - AudioCaptureStartState policy

    func testMeetingCaptureOutcomeWaitsWhenNotYetRecordingButFilePresent() {
        // Edge: file URL exists but recording flag not set yet → still waiting.
        let url = URL(fileURLWithPath: "/tmp/system.wav")
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: false,
                systemAudioFileURL: url,
                errorMessage: nil
            ),
            .waiting
        )
    }

    func testMeetingCaptureOutcomeTreatsEmptyErrorMessageAsAbsent() {
        // Empty-string error message must NOT be treated as failure — the
        // policy only fails when the message is non-empty.
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: URL(fileURLWithPath: "/tmp/system.wav"),
                errorMessage: ""
            ),
            .ready
        )
    }

    func testMeetingCaptureOutcomePrioritizesErrorOverReadiness() {
        // Even with full readiness signals, a non-empty error message wins.
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: URL(fileURLWithPath: "/tmp/system.wav"),
                errorMessage: "permission denied"
            ),
            .failed("permission denied")
        )
    }

    func testTimeoutFailureMessageFallsBackToCanonicalCopy() {
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureMessage(existingErrorMessage: nil),
            "System audio capture did not become ready in time."
        )
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureMessage(existingErrorMessage: ""),
            "System audio capture did not become ready in time."
        )
    }

    func testTimeoutFailureMessagePreservesExistingError() {
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureMessage(
                existingErrorMessage: "screen recording denied"
            ),
            "screen recording denied"
        )
    }

    // MARK: - PipelineError retry classification

    func testPipelineErrorMarksAudioErrorsAsNonRetryable() {
        XCTAssertFalse(PipelineError.emptyAudioFile.isRetryable)
        XCTAssertFalse(PipelineError.noSpeechDetected.isRetryable)
        XCTAssertFalse(PipelineError.recordingTooShort(duration: 0.5).isRetryable)
        XCTAssertFalse(PipelineError.invalidAudioFormat(detail: "x").isRetryable)
        XCTAssertFalse(PipelineError.missingSystemAudio.isRetryable)
    }

    func testPipelineErrorMarksTransientErrorsAsRetryable() {
        XCTAssertTrue(PipelineError.modelNotLoaded(model: "Parakeet").isRetryable)
        XCTAssertTrue(PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "x").isRetryable)
        XCTAssertTrue(PipelineError.saveFailed(detail: "disk full").isRetryable)
        XCTAssertTrue(PipelineError.unknown(underlying: "anything").isRetryable)
    }

    func testPipelineErrorRecordingTooShortFormatsDurationInDescription() {
        let description = PipelineError.recordingTooShort(duration: 1.234).errorDescription ?? ""
        XCTAssertTrue(description.contains("1.2"), "Expected duration in description, got: \(description)")
        XCTAssertTrue(description.contains("At least 2 seconds"), description)
    }

    // MARK: - SpeakerNamingPolicy seam used by the runner

    func testNamingPolicyAutoAcceptsHighConfidenceMatureNamedProfile() {
        let profile = speakerProfile(displayName: "Nate", callCount: 6, disputeCount: 0)
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(profile: profile, similarity: 0.92))
    }

    func testNamingPolicyRejectsUnnamedProfileEvenWhenMature() {
        let profile = speakerProfile(displayName: nil, callCount: 20, disputeCount: 0)
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(profile: profile, similarity: 0.99))
    }

    func testNamingPolicyRejectsDisputedProfile() {
        let profile = speakerProfile(displayName: "Travis", callCount: 10, disputeCount: 1)
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(profile: profile, similarity: 0.92))
    }

    func testNamingPolicyRejectsLowSimilarityAtBoundary() {
        // Threshold is strictly > 0.88.
        let profile = speakerProfile(displayName: "Sara", callCount: 6, disputeCount: 0)
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(profile: profile, similarity: 0.88))
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(profile: profile, similarity: 0.881))
    }

    func testNamingPolicyRejectsImmatureProfileAtBoundary() {
        // callCount must be strictly > 4.
        let profile4 = speakerProfile(displayName: "Sara", callCount: 4, disputeCount: 0)
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(profile: profile4, similarity: 0.95))

        let profile5 = speakerProfile(displayName: "Sara", callCount: 5, disputeCount: 0)
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(profile: profile5, similarity: 0.95))
    }

    func testSpeakerClassificationUsesPreMeetingSnapshotForAutoAcceptMaturity() throws {
        let profileId = UUID()
        let preMeetingProfile = speakerProfile(
            id: profileId,
            displayName: "Maya",
            callCount: 4,
            disputeCount: 0
        )
        let updatedProfile = speakerProfile(
            id: profileId,
            displayName: "Maya",
            callCount: 5,
            disputeCount: 0
        )
        let (database, directory) = try temporarySpeakerDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = database.addOrUpdateSpeaker(embedding: updatedProfile.embedding, existingId: profileId)
        database.restoreProfile(updatedProfile)

        let knowledge = TranscriptionTaskManager.speakerClassificationKnowledge(
            speakerIds: ["2"],
            utterances: [
                utterance(
                    start: 0,
                    end: 1,
                    speakerId: 2,
                    persistentSpeakerId: profileId,
                    matchSimilarity: 0.95,
                    transcript: "hello"
                )
            ],
            contexts: [
                "2": ChannelSpeakerContext(
                    persistentSpeakerId: profileId,
                    sessionEmbedding: [1, 0],
                    matchedProfileSnapshot: preMeetingProfile,
                    matchSimilarity: 0.95
                )
            ],
            speakerDB: database
        )

        XCTAssertEqual(knowledge.count, 1)
        XCTAssertEqual(knowledge[0].profile.callCount, 4)
        XCTAssertFalse(
            SpeakerNamingPolicy.shouldAutoAccept(
                profile: knowledge[0].profile,
                similarity: knowledge[0].similarity
            ),
            "A profile that only became mature during this meeting should still require speaker review."
        )
    }

    func testSpeakerClassificationFallsBackToStoreWhenSnapshotIsMissing() throws {
        let profileId = UUID()
        let profile = speakerProfile(
            id: profileId,
            displayName: "Maya",
            callCount: 5,
            disputeCount: 0
        )
        let (database, directory) = try temporarySpeakerDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = database.addOrUpdateSpeaker(embedding: profile.embedding, existingId: profileId)
        database.restoreProfile(profile)

        let knowledge = TranscriptionTaskManager.speakerClassificationKnowledge(
            speakerIds: ["2"],
            utterances: [
                utterance(
                    start: 0,
                    end: 1,
                    speakerId: 2,
                    persistentSpeakerId: profileId,
                    matchSimilarity: 0.95,
                    transcript: "hello"
                )
            ],
            contexts: [:],
            speakerDB: database
        )

        XCTAssertEqual(knowledge.count, 1)
        XCTAssertEqual(knowledge[0].profile.id, profileId)
        XCTAssertEqual(knowledge[0].profile.callCount, 5)
    }

    func testPendingReviewProfileIdsCollectsSystemNeedsActionAndQueuedMicSpeakers() {
        let systemReviewId = UUID()
        let systemAcceptedId = UUID()
        let micReviewId = UUID()
        let micAutoAcceptedButQueuedId = UUID()

        let ids = TranscriptionTaskManager.pendingReviewProfileIds(
            systemUtterances: [
                utterance(start: 0, end: 1, speakerId: 1, persistentSpeakerId: systemReviewId, transcript: "review"),
                utterance(start: 1, end: 2, speakerId: 2, persistentSpeakerId: systemAcceptedId, transcript: "accepted"),
            ],
            micUtterances: [
                utterance(start: 0, end: 1, channel: 0, speakerId: 0, persistentSpeakerId: micReviewId, transcript: "local"),
                utterance(start: 1, end: 2, channel: 0, speakerId: 1, persistentSpeakerId: micAutoAcceptedButQueuedId, transcript: "known local")
            ],
            systemNeedsActionIds: ["1"],
            micQueuedReviewIds: ["0", "1"]
        )

        XCTAssertEqual(ids, Set([systemReviewId, micReviewId, micAutoAcceptedButQueuedId]))
        XCTAssertFalse(ids.contains(systemAcceptedId))
    }

    func testNamingPolicyConfidenceTiers() {
        XCTAssertEqual(SpeakerNamingPolicy.confidence(similarity: 0.90, callCount: 10), .high)
        // Falls back to medium when similarity exactly at 0.85 (strictly >).
        XCTAssertEqual(SpeakerNamingPolicy.confidence(similarity: 0.85, callCount: 10), .medium)
        // Falls back to medium when callCount at boundary (strictly >).
        XCTAssertEqual(SpeakerNamingPolicy.confidence(similarity: 0.95, callCount: 3), .medium)
        XCTAssertEqual(SpeakerNamingPolicy.confidence(similarity: 0.50, callCount: 1), .medium)
    }

    func testNamingPolicyInitialMappingFallsBackToPlaceholderWhenNotAutoAccepted() {
        let profile = speakerProfile(displayName: "Maya", callCount: 1, disputeCount: 0)
        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "7",
            profile: profile,
            similarity: 0.99
        )

        XCTAssertEqual(mapping.speakerId, "7")
        XCTAssertNil(mapping.identifiedName)
        XCTAssertFalse(mapping.isConfirmedIdentity)
        XCTAssertEqual(mapping.displayName, "Speaker 7")
    }

    func testNamingPolicyInitialMappingMarksConfirmedWhenAutoAccepted() {
        let profile = speakerProfile(displayName: "Maya", callCount: 10, disputeCount: 0)
        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "2",
            profile: profile,
            similarity: 0.95
        )

        XCTAssertEqual(mapping.identifiedName, "Maya")
        XCTAssertTrue(mapping.isConfirmedIdentity)
        XCTAssertEqual(mapping.displayName, "Maya")
        XCTAssertEqual(mapping.confidence, .high)
    }

    func testNamingPolicyInitialMappingRejectsEmptyDisplayName() {
        // shouldAutoAccept passes (name is non-nil), but the empty-name guard
        // in initialMapping must still demote it to a placeholder mapping.
        let profile = speakerProfile(displayName: "", callCount: 10, disputeCount: 0)
        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "3",
            profile: profile,
            similarity: 0.95
        )

        XCTAssertNil(mapping.identifiedName)
        XCTAssertFalse(mapping.isConfirmedIdentity)
    }

    // MARK: - TranscriptionResult derived getters used by the runner

    func testTranscriptionResultAggregatesChannelsForPersistentIds() {
        let micId = UUID()
        let systemId = UUID()
        let sharedId = UUID()

        let result = TranscriptionResult(
            micUtterances: [
                utterance(start: 0, end: 1, channel: 0, speakerId: 0, persistentSpeakerId: micId, transcript: "hi"),
                utterance(start: 1, end: 2, channel: 0, speakerId: 0, persistentSpeakerId: sharedId, transcript: "there"),
            ],
            systemUtterances: [
                utterance(start: 0.5, end: 1.5, channel: 1, speakerId: 3, persistentSpeakerId: systemId, transcript: "hello"),
                utterance(start: 2.0, end: 2.5, channel: 1, speakerId: 4, persistentSpeakerId: sharedId, transcript: "world"),
                utterance(start: 2.6, end: 3.0, channel: 1, speakerId: 4, persistentSpeakerId: nil, transcript: "extra"),
            ],
            duration: 3.0,
            processingTime: 0.0
        )

        XCTAssertEqual(result.micUtteranceCount, 2)
        XCTAssertEqual(result.systemUtteranceCount, 3)
        XCTAssertEqual(result.micSpeakerCount, 1)
        XCTAssertEqual(result.systemSpeakerCount, 2)
        XCTAssertEqual(result.systemSpeakerIds, ["3", "4"])
        XCTAssertEqual(result.micSpeakerIds, ["0"])

        // persistentSpeakerIds is the union across channels and skips nil.
        XCTAssertEqual(result.persistentSpeakerIds, [micId, systemId, sharedId])
        // micPersistentSpeakerIds is mic-channel only.
        XCTAssertEqual(result.micPersistentSpeakerIds, [micId, sharedId])
    }

    func testTranscriptionResultAllUtterancesSortsAcrossChannelsByStart() {
        let result = TranscriptionResult(
            micUtterances: [
                utterance(start: 0.5, end: 1.0, channel: 0, speakerId: 0, transcript: "mic-early"),
                utterance(start: 3.0, end: 3.5, channel: 0, speakerId: 0, transcript: "mic-late"),
            ],
            systemUtterances: [
                utterance(start: 0.0, end: 0.4, channel: 1, speakerId: 1, transcript: "sys-first"),
                utterance(start: 2.0, end: 2.5, channel: 1, speakerId: 1, transcript: "sys-mid"),
            ],
            duration: 4.0,
            processingTime: 0.0
        )

        let ordered = result.allUtterances.map(\.transcript)
        XCTAssertEqual(ordered, ["sys-first", "mic-early", "sys-mid", "mic-late"])
    }

    func testTranscriptionResultWordCountsIgnoreEmptyTranscripts() {
        let result = TranscriptionResult(
            micUtterances: [
                utterance(start: 0, end: 1, channel: 0, speakerId: 0, transcript: "hello world"),
                utterance(start: 1, end: 2, channel: 0, speakerId: 0, transcript: ""),
            ],
            systemUtterances: [
                utterance(start: 0, end: 1, channel: 1, speakerId: 1, transcript: "one two three four"),
            ],
            duration: 2.0,
            processingTime: 0.0
        )

        XCTAssertEqual(result.micWordCount, 2)
        XCTAssertEqual(result.systemWordCount, 4)
    }

    func testTranscriptionResultEmptyCollectionsYieldZeroDerivedValues() {
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [],
            duration: 0,
            processingTime: 0
        )

        XCTAssertEqual(result.micSpeakerCount, 0)
        XCTAssertEqual(result.systemSpeakerCount, 0)
        XCTAssertTrue(result.persistentSpeakerIds.isEmpty)
        XCTAssertTrue(result.micPersistentSpeakerIds.isEmpty)
        XCTAssertTrue(result.allUtterances.isEmpty)
    }

    // MARK: - Helpers

    private func utterance(
        start: Double,
        end: Double,
        channel: Int = 1,
        speakerId: Int,
        persistentSpeakerId: UUID? = nil,
        matchSimilarity: Double? = nil,
        transcript: String
    ) -> TranscriptionUtterance {
        TranscriptionUtterance(
            start: start,
            end: end,
            channel: channel,
            speakerId: speakerId,
            persistentSpeakerId: persistentSpeakerId,
            matchSimilarity: matchSimilarity,
            transcript: transcript
        )
    }

    private func speakerProfile(
        id: UUID = UUID(),
        displayName: String?,
        callCount: Int,
        disputeCount: Int
    ) -> SpeakerProfile {
        SpeakerProfile(
            id: id,
            displayName: displayName,
            nameSource: displayName == nil ? nil : NameSource.userManual,
            embedding: [1, 0],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: callCount,
            confidence: 0.8,
            disputeCount: disputeCount
        )
    }

    private func temporarySpeakerDatabase() throws -> (SpeakerDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionPipelineStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SpeakerDatabase(path: directory.appendingPathComponent("speakers.sqlite").path), directory)
    }
}
