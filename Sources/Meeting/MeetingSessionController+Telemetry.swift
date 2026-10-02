// MeetingSessionController+Telemetry.swift
// Capture analytics properties, the capture-health report, saved-transcript
// analytics, and the start-failure and status-copy wrappers.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    func meetingStartFailureKind(from message: String, stage: String? = nil) -> String {
        MeetingStartFailureClassifier.kind(from: message, stage: stage)
    }

    func meetingCaptureAnalyticsProperties(snapshot: AudioPipelineDiagnosticsSnapshot, telemetryIdentity: UUID? = nil) -> [String: String] {
        var properties = snapshot.privacySafeContext.merging(
            MeetingCaptureVolumeDiagnostics.measurementScope,
            uniquingKeysWith: { _, scope in scope }
        )
        if let id = (telemetryIdentity ?? activeRecordingIdentity)?.uuidString {
            properties["session_id"] = id
            properties["correlation_id"] = id
        }
        properties["gap_count_bucket"] = AnalyticsReporter.countBucket(snapshot.gapCount)
        properties["route_change_count_bucket"] = AnalyticsReporter.countBucket(snapshot.routeChangeCount)
        properties["recovery_attempt_bucket"] = AnalyticsReporter.countBucket(snapshot.recoveryAttemptCount)
        // Call-audio tap upkeep for this recording (#1762/#1771): how often it
        // reconnected and why, bucketed like the counts above.
        let tap = snapshot.systemTap
        properties["system_wake_reconnects_bucket"] = AnalyticsReporter.countBucket(tap.wakeReconnects)
        properties["system_format_reconnects_bucket"] = AnalyticsReporter.countBucket(tap.formatReconnects)
        properties["system_silent_reconnects_bucket"] = AnalyticsReporter.countBucket(tap.silentReconnects)
        properties["system_stall_reconnects_bucket"] = AnalyticsReporter.countBucket(tap.stallReconnects)
        properties["system_rebuild_retries_bucket"] = AnalyticsReporter.countBucket(tap.rebuildRetries)
        properties["system_sleep_count_bucket"] = AnalyticsReporter.countBucket(tap.sleeps)
        // #1767: mic graph rebuilt because AirPods changed format at start.
        properties["mic_format_rebuilds_bucket"] = AnalyticsReporter.countBucket(snapshot.micFormatRebuildCount)
        return properties
    }

    func reportCaptureHealthIfNeeded(
        snapshot: AudioPipelineDiagnosticsSnapshot,
        captureDiagnostics: [String: String],
        healthInfo: RecordingHealthInfo,
        trigger: StartTrigger,
        reason: StopReason,
        durationSeconds: Double,
        files: (micURL: URL?, systemURL: URL?),
        stopTimedOut: Bool
    ) {
        guard let context = MeetingCaptureHealthTelemetry.degradedDiagnosticsContext(
            .init(
                captureDiagnostics: captureDiagnostics,
                health: captureHealthFacts(from: healthInfo),
                trigger: trigger.rawValue,
                reason: reason.rawValue,
                durationSeconds: durationSeconds,
                micFileAvailable: files.micURL != nil,
                systemStreamPresent: files.systemURL != nil,
                stopTimedOut: stopTimedOut,
                systemFailed: snapshot.systemFailed,
                systemStatus: snapshot.systemStatus
            )
        ) else { return }

        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "recording_capture_degraded",
            message: "Meeting capture health degraded",
            context: baseDiagnosticsContext(extra: context)
        )
    }

    func captureHealthFacts(from healthInfo: RecordingHealthInfo) -> MeetingCaptureHealthTelemetry.HealthFacts {
        .init(
            captureQuality: healthInfo.captureQuality.rawValue,
            audioGaps: healthInfo.audioGaps,
            deviceSwitches: healthInfo.deviceSwitches,
            qualityReason: healthInfo.qualityReason.rawValue
        )
    }

    /// The bucketed properties come from transcript frontmatter on disk, so the
    /// read happens off the main actor and waits for any in-flight restyle to
    /// finish renaming the saved artifact before reading it.
    func trackSavedTranscriptAnalyticsInBackground(
        baseProperties: [String: String],
        promptTelemetryProperties: [String: String]?,
        promptRecordingStartedAt: Date?
    ) {
        let restyle = savedTranscriptRestyleTask
        let fallbackTranscriptURL = taskManager.lastSavedTranscriptURL ?? lastSavedTranscriptURL
        let speakerDatabase = self.speakerDatabase
        Task.detached(priority: .utility) {
            let transcriptURL: URL?
            if let restyle {
                transcriptURL = await restyle.value.url
            } else {
                transcriptURL = fallbackTranscriptURL
            }
            let frontmatterValues = transcriptURL.flatMap {
                (try? TranscriptFrontmatter.readValues(from: $0)) ?? nil
            }
            let transcriptProperties = Self.savedTranscriptAnalyticsProperties(values: frontmatterValues)
            let autoRecognitionEvents = Self.autoRecognitionAnalyticsProperties(
                frontmatterValues: frontmatterValues,
                speakerDatabase: speakerDatabase
            )
            await MainActor.run {
                let properties = transcriptProperties.merging(
                    baseProperties,
                    uniquingKeysWith: { _, new in new }
                )
                ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                    artifactKind: .meeting,
                    surface: .meetingSave,
                    trigger: properties["trigger"] ?? StartTrigger.unknown.rawValue,
                    wordCountBucket: properties["word_count_bucket"],
                    durationBucket: properties["duration_bucket"]
                )
                AnalyticsReporter.track(
                    "meeting_transcript_saved",
                    properties: properties
                )
                if let promptOutcomeProperties = MeetingPromptTelemetry.sessionOutcomeProperties(
                    promptProperties: promptTelemetryProperties,
                    outcomeKind: .transcriptSaved,
                    elapsedSeconds: promptRecordingStartedAt.map { Date().timeIntervalSince($0) }
                ) {
                    AnalyticsReporter.track("meeting_prompt_outcome_recorded", properties: promptOutcomeProperties)
                }
                for eventProperties in autoRecognitionEvents {
                    AnalyticsReporter.track(
                        "meeting_speaker_auto_recognized",
                        properties: eventProperties
                    )
                }
            }
        }
    }

    nonisolated static func processingTelemetryTimings(
        _ snapshot: MeetingPipelineTimings.Snapshot
    ) -> MeetingProcessingTelemetry.Timings {
        MeetingProcessingTelemetry.Timings(
            processingSeconds: snapshot.processingSeconds,
            sleepSeconds: snapshot.sleepSeconds,
            modelsReadySeconds: snapshot.modelsReadySeconds,
            resampleSeconds: snapshot.resampleSeconds,
            diarizeSeconds: snapshot.diarizeSeconds,
            speechToTextSeconds: snapshot.speechToTextSeconds,
            speechToTextCalls: snapshot.speechToTextCalls,
            speechToTextInputSeconds: snapshot.speechToTextInputSeconds,
            recordingSeconds: snapshot.recordingSeconds,
            speechModel: snapshot.speechModel
        )
    }

    /// One bucketed event per auto-recognized *person* in the saved meeting,
    /// read back from the local lifeline store keyed by the transcript id in
    /// frontmatter. Outcomes are deduplicated by profile (the pipeline can
    /// record one row per channel, and a retranscription of the same meeting
    /// appends rows for its transcript id again), so one save emits at most
    /// one event per speaker. `graduated` marks a profile whose only
    /// auto-recognitions belong to this meeting — the "how many meetings
    /// until the app just knows them" milestone. Only enum buckets leave the
    /// device; no names, ids, or raw scores.
    nonisolated private static func autoRecognitionAnalyticsProperties(
        frontmatterValues: [String: String]?,
        speakerDatabase: SpeakerDatabase
    ) -> [[String: String]] {
        guard let frontmatterValues,
              let transcriptId = TranscriptFrontmatter.captureID(in: frontmatterValues) else {
            return []
        }

        let autoOutcomes = speakerDatabase.matchOutcomes(transcriptId: transcriptId)
            .filter { $0.kind == .autoAccepted }
        // Rows arrive most-recent-first; keep the newest row per profile so a
        // retranscription reports the latest run, not every historical run.
        var newestByProfile: [UUID: SpeakerMatchOutcome] = [:]
        var rowsPerProfile: [UUID: Int] = [:]
        for outcome in autoOutcomes {
            rowsPerProfile[outcome.profileId, default: 0] += 1
            if newestByProfile[outcome.profileId] == nil {
                newestByProfile[outcome.profileId] = outcome
            }
        }

        return newestByProfile.values.map { outcome in
            // Graduated when every auto-recognition this profile has ever had
            // belongs to this meeting — robust to multi-channel rows within
            // one save, unlike a bare count == 1 check.
            let totalCount = speakerDatabase.autoAcceptedOutcomeCount(profileId: outcome.profileId)
            let graduated = totalCount <= (rowsPerProfile[outcome.profileId] ?? 0)
            return [
                "similarity_bucket": SpeakerRecognitionTelemetry.similarityBucket(outcome.similarity),
                "margin_bucket": SpeakerRecognitionTelemetry.marginBucket(
                    similarity: outcome.similarity,
                    secondSimilarity: outcome.secondSimilarity
                ),
                "call_count_bucket": AnalyticsReporter.countBucket(outcome.callCountAtMatch ?? 0),
                "channel": outcome.channel ?? "unknown",
                "graduated": graduated ? "true" : "false",
                "surface": "meeting_save",
            ]
        }
    }

    nonisolated private static func savedTranscriptAnalyticsProperties(values: [String: String]?) -> [String: String] {
        guard let values else {
            return [:]
        }

        var properties: [String: String] = [:]

        if let duration = values["duration"],
           let durationSeconds = TranscriptFrontmatter.durationSeconds(from: duration) {
            properties["duration_bucket"] = AnalyticsReporter.durationBucket(seconds: Double(durationSeconds))
        }

        if let wordCount = Int(values["total_word_count"] ?? "") {
            properties["word_count_bucket"] = AnalyticsReporter.wordCountBucket(wordCount)
        }

        let participantCount = (Int(values["mic_speakers"] ?? "") ?? 0)
            + (Int(values["system_speakers"] ?? "") ?? 0)
        if participantCount > 0 {
            properties["participant_count_bucket"] = AnalyticsReporter.countBucket(participantCount)
        }

        return properties
    }

    func systemAudioStatusMessage(for status: SystemAudioStatus) -> String {
        MeetingSystemAudioStatusCopy.message(for: status)
    }
}
