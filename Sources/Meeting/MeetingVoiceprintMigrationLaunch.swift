// MeetingVoiceprintMigrationLaunch.swift
// At launch, carries the people saved under the previous voiceprint model
// (WeSpeaker, `state/speakers.sqlite`) into the active model's own database, so
// switching models doesn't forget anyone. Core's `SpeakerVoiceprintMigration`
// does the carry-over (it only reads `speakers.sqlite`, and resumes from its
// ledger after a relaunch); `SpeakerVoiceprintMigrationGate` holds every
// speaker-database writer until it ends: the transcription queue, failed-meeting
// retries and re-transcription (MeetingSessionController,
// TranscriptionQueueCoordinator) and Settings › Speakers edits.

import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
enum MeetingVoiceprintMigrationLaunch {
    /// Voiceprint models that bring the people named under WeSpeaker along on
    /// first use. ERes2Net is left out on purpose: it was an opt-in whose users
    /// already re-learned people in its own database, and carrying WeSpeaker's
    /// people in would give them a second copy of everyone.
    static let modelsCarryingSavedPeople: Set<String> = [ReDimNet2Embedder.identifier]

    /// Starts the carry-over when the loaded embedder is one of
    /// `modelsCarryingSavedPeople` and `speakers.sqlite` exists; otherwise the
    /// gate stays open. `targetDatabase` must be the database that embedder's
    /// meetings write, already open with its thresholds.
    static func start(
        _ gate: SpeakerVoiceprintMigrationGate,
        embedder: (any SpeakerSegmentEmbedder)?,
        targetDatabase: SpeakerDatabase,
        speakerClipsDirectory: URL,
        legacyDatabaseURL: URL = MeetingStoragePaths.speakersDatabase,
        meetingsDirectory: URL = MeetingStoragePaths.transcriptsFolder
    ) {
        guard let embedder, modelsCarryingSavedPeople.contains(embedder.identifier) else { return }
        gate.start(
            sourceDatabaseURL: legacyDatabaseURL,
            targetDatabase: targetDatabase,
            embedder: embedder,
            sources: .appLayout(
                sourceDatabaseURL: legacyDatabaseURL,
                speakerClipsDirectory: speakerClipsDirectory,
                meetingsDirectory: meetingsDirectory
            )
        )
    }
}
