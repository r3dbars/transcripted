import Foundation
import AVFoundation

// MARK: - Pipeline entry points (speaker knowledge, microphone-only, imported audio)

extension TranscriptionTaskManager {

    struct SavedTranscriptAudioResolution: Sendable {
        let includesMicrophone: Bool
        let includesSystemAudio: Bool
        let healthInfo: RecordingHealthInfo?
    }

    /// Resolve partial-success audio channels before formatting and retention.
    /// Unusable channels are excluded from source metadata and mark the artifact
    /// degraded. A failed mic keeps flowing through archival for future retry;
    /// a corrupt/short system file is excluded from retained playback.
    nonisolated static func savedTranscriptAudioResolution(
        microphoneURLWasProvided: Bool,
        microphoneOutcome: TranscriptionResult.MicrophoneAudioOutcome,
        systemOutcome: TranscriptionResult.SystemAudioOutcome = .usable,
        healthInfo: RecordingHealthInfo?
    ) -> SavedTranscriptAudioResolution {
        let includesMicrophone = microphoneURLWasProvided && microphoneOutcome != .unusable
        let includesSystemAudio = systemOutcome == .usable
        var resolvedHealth = healthInfo
        if microphoneURLWasProvided && microphoneOutcome == .unusable {
            resolvedHealth = (resolvedHealth ?? .perfect).markingMicrophoneAudioUnusable()
        }
        if systemOutcome == .unusable {
            resolvedHealth = (resolvedHealth ?? .perfect).markingSystemAudioMissing()
        }
        return SavedTranscriptAudioResolution(
            includesMicrophone: includesMicrophone,
            includesSystemAudio: includesSystemAudio,
            healthInfo: resolvedHealth
        )
    }

    struct SpeakerClassificationKnowledge: Sendable {
        let speakerId: String
        let profile: SpeakerProfile
        let similarity: Double
        /// Runner-up similarity for the auto-accept margin guard; nil when unknown (the
        /// utterance fallback path), which `shouldAutoAccept` treats as "confirm, don't auto".
        let secondSimilarity: Double?
        /// Winner's average-only cosine and the runner-up's average-only cosine, when carried by
        /// the match context. Feed `SpeakerNamingPolicy.shouldAutoAccept`'s `marginSimilarities`
        /// so the auto-accept margin is judged on the blended average, not the best exemplar.
        let averageSimilarity: Double?
        let secondAverageSimilarity: Double?

        /// Average-based margin pair for `shouldAutoAccept`, or nil to fall back to the legacy
        /// (exemplar) margin when the average sims weren't carried (e.g. utterance fallback).
        var marginSimilarities: (best: Double, secondBest: Double)? {
            guard let best = averageSimilarity, let second = secondAverageSimilarity else { return nil }
            return (best: best, secondBest: second)
        }
    }

    nonisolated static func speakerClassificationKnowledge(
        speakerIds: [String],
        utterances: [TranscriptionUtterance],
        contexts: [String: ChannelSpeakerContext],
        speakerDB: any SpeakerStore
    ) -> [SpeakerClassificationKnowledge] {
        var knowledge: [SpeakerClassificationKnowledge] = []
        var seenIds: Set<String> = []

        for sid in speakerIds where seenIds.insert(sid).inserted {
            if let context = contexts[sid],
               let snapshot = context.matchedProfileSnapshot,
               let similarity = context.matchSimilarity {
                knowledge.append(SpeakerClassificationKnowledge(
                    speakerId: sid,
                    profile: snapshot,
                    similarity: similarity,
                    secondSimilarity: context.matchSecondSimilarity,
                    averageSimilarity: context.matchAverageSimilarity,
                    secondAverageSimilarity: context.matchSecondBestAverageSimilarity
                ))
                continue
            }

            if let utterance = utterances.first(where: { String($0.speakerId) == sid }),
               let persistentId = utterance.persistentSpeakerId,
               let similarity = utterance.matchSimilarity,
               let profile = speakerDB.getSpeaker(id: persistentId) {
                knowledge.append(SpeakerClassificationKnowledge(
                    speakerId: sid,
                    profile: profile,
                    similarity: similarity,
                    secondSimilarity: nil,   // runner-up not carried on the utterance fallback
                    averageSimilarity: nil,
                    secondAverageSimilarity: nil
                ))
            }
        }

        return knowledge
    }

    nonisolated static func pendingReviewProfileIds(
        systemUtterances: [TranscriptionUtterance],
        micUtterances: [TranscriptionUtterance],
        systemNeedsActionIds: Set<String>,
        micQueuedReviewIds: Set<String>
    ) -> Set<UUID> {
        let systemIds = systemUtterances.compactMap { utterance -> UUID? in
            guard systemNeedsActionIds.contains(String(utterance.speakerId)) else { return nil }
            return utterance.persistentSpeakerId
        }
        let micIds = micUtterances.compactMap { utterance -> UUID? in
            guard micQueuedReviewIds.contains(String(utterance.speakerId)) else { return nil }
            return utterance.persistentSpeakerId
        }
        return Set(systemIds + micIds)
    }

    /// Transcribe a captured meeting using system audio plus optional mic audio.
    /// - Returns: URL of saved transcript with speaker attribution
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated func transcribeWithSpeakerIdentification(
        micURL: URL?,
        systemURL: URL?,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?,
        splitLocalSpeakers: Bool = false,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        sourceFailedTranscriptionId: UUID? = nil,
        removeSourceAudioAfterArchive: Bool = true,
        languageSelection: TranscriptionLanguageSelection = .automatic
    ) async throws -> URL {

        guard let systemURL else {
            guard let micURL else {
                throw PipelineError.invalidAudioFormat(detail: "No meeting audio files were available")
            }
            let micExists = FileManager.default.fileExists(atPath: micURL.path)
            return try await transcribeMicrophoneOnlyPipeline(
                micURL: micURL,
                outputFolder: outputFolder,
                taskId: taskId,
                healthInfo: healthInfo,
                meetingTitle: meetingTitle,
                recordingDate: recordingDate,
                sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                removeSourceAudioAfterArchive: removeSourceAudioAfterArchive,
                splitLocalSpeakers: splitLocalSpeakers && micExists,
                languageSelection: languageSelection
            )
        }

        return try await transcribeMultichannelPipeline(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            taskId: taskId,
            healthInfo: healthInfo,
            splitLocalSpeakers: splitLocalSpeakers,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            sourceFailedTranscriptionId: sourceFailedTranscriptionId,
            removeSourceAudioAfterArchive: removeSourceAudioAfterArchive,
            languageSelection: languageSelection
        )
    }

    nonisolated func transcribeMicrophoneOnlyPipeline(
        micURL: URL,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        sourceFailedTranscriptionId: UUID? = nil,
        removeSourceAudioAfterArchive: Bool = true,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic
    ) async throws -> URL {
        let transcription = await MainActor.run { self.transcription }
        try await transcription.ensureModelsReadyForPipeline()

        let speechEngine = await MainActor.run {
            transcription.parakeet.transcriptionEngineDescriptor
        }

        AppLogger.pipeline.info("Using local \(speechEngine.displayName) mic-only recovery pipeline", [
            "transcription_engine": speechEngine.identifier
        ])

        let result = try await transcription.transcribeMicrophoneOnly(
            micURL: micURL,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            onProgress: TranscribingProgressGate.onProgress { [weak self] progress in
                self?.displayStatus = .transcribing(progress: progress)
            }
        )

        let replacementTranscriptRollback = try ReplacementTranscriptRollback.capture(for: nil)
        let transcriptId = UUID()
        try Task.checkCancellation()

        let notifier: TranscriptNotifier? = await MainActor.run {
            self.displayStatus = .finishing
            return self.notifier
        }
        let formatOptions = await MainActor.run {
            self.resolvedTranscriptFormatOptions(hasMicAudio: true, hasSystemAudio: false)
        }

        let transcriptDate = recordingDate ?? Date()
        let micOnlyHealth = healthInfo?.markingSystemAudioMissing()
            ?? RecordingHealthInfo(
                captureQuality: .degraded,
                audioGaps: 0,
                deviceSwitches: 0,
                gapDescriptions: [],
                systemAudioMissing: true,
                qualityReason: .systemAudioMissing
            )
        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            transcriptId: transcriptId,
            speakerMappings: [:],
            speakerSources: [:],
            speakerDbIds: [:],
            directory: outputFolder,
            meetingTitle: meetingTitle,
            healthInfo: micOnlyHealth,
            notifier: nil,
            speakerStore: nil,
            statsStore: DeferredTranscriptStatsStore(),
            recordingDate: transcriptDate,
            transcriptionEngine: speechEngine,
            formatOptions: formatOptions
        ) else {
            throw PipelineError.saveFailed(detail: "Could not write mic-only transcript to \(outputFolder.lastPathComponent)")
        }
        let rollback = PipelineRollbackRegistry()
        Self.registerSavedTranscriptRollback(
            savedURL: savedURL,
            replacementTranscriptRollback: replacementTranscriptRollback,
            into: rollback
        )
        try await rollback.checkCancellation()

        let archiveOutcome = await archiveRecordingAudioIfConfigured(
            micURL: micURL,
            systemURL: nil,
            savedURL: savedURL
        )
        Self.registerRetainedAudioRollback(
            directory: archiveOutcome.retainedAudioDirectory,
            urls: archiveOutcome.retainedAudioURLs,
            into: rollback
        )
        try await rollback.checkCancellation()

        try await commitSavedTranscriptSideEffectsUnlessCancelled(
            taskId: taskId,
            savedURL: savedURL,
            result: result,
            transcriptId: transcriptId,
            meetingTitle: meetingTitle,
            transcriptDate: transcriptDate,
            notifier: notifier,
            rollback: rollback
        )

        if archiveOutcome.canRemoveMicScratch && removeSourceAudioAfterArchive && sourceFailedTranscriptionId == nil {
            removeManagedCleanupFile(micURL, label: "completed mic-only scratch")
        }

        return savedURL
    }

    nonisolated static func existingImportedAt(of transcriptURL: URL?) -> Date? {
        guard let transcriptURL,
              let raw = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let values = TranscriptFrontmatter.values(in: raw) else { return nil }
        return TranscriptFrontmatter.importedAt(values: values)
    }

    /// Transcribe an imported audio file through the system-audio speaker path.
    nonisolated func transcribeImportedAudio(
        audioURL: URL,
        outputFolder: URL,
        taskId: UUID,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        languageSelection: TranscriptionLanguageSelection = .automatic
    ) async throws -> URL {
        try await transcribeMultichannelPipeline(
            micURL: nil,
            systemURL: audioURL,
            outputFolder: outputFolder,
            taskId: taskId,
            healthInfo: nil,
            splitLocalSpeakers: false,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            stableTranscriptId: taskId,
            languageSelection: languageSelection,
            importedAt: Date()
        )
    }

}
