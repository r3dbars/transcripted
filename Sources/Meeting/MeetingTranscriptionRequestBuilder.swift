// MeetingTranscriptionRequestBuilder.swift
// One place where meeting transcription entry points pick up the
// People-in-the-room choice (`LocalSpeakerPreferences`). Saved-audio
// retranscribe, the live recorded queue, and the failed-queue rows those jobs
// fall back to all build their request here, so none of them can hard-code
// local speaker splitting. The preference is injected so tests can flip it
// without touching UserDefaults; production reads the real setting.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct MeetingTranscriptionOptions: Equatable, Sendable {
    let splitLocalSpeakers: Bool

    static func resolve(
        localSpeakerPreference: () -> Bool = LocalSpeakerPreferences.isEnabled
    ) -> MeetingTranscriptionOptions {
        MeetingTranscriptionOptions(splitLocalSpeakers: localSpeakerPreference())
    }
}

/// Saved meeting audio sent back through the pipeline to replace its transcript.
struct SavedAudioRetranscriptionRequest: Equatable {
    let micURL: URL?
    let systemURL: URL
    let meetingTitle: String?
    let replacementTranscriptURL: URL?
    let recordingDate: Date?
    let options: MeetingTranscriptionOptions
}

/// A live recording handed to the transcription queue at Stop.
struct RecordedMeetingTranscriptionRequest: Equatable {
    let micURL: URL?
    let systemURL: URL?
    let meetingTitle: String?
    let recordingDate: Date
    let options: MeetingTranscriptionOptions
}

/// What a failed-queue row will store, so a later retry runs the same way.
struct FailedMeetingRetryRow: Equatable {
    let micURL: URL?
    let systemURL: URL?
    let errorMessage: String
    let meetingTitle: String?
    let recordingDate: Date?
    let splitLocalSpeakers: Bool
    let languageSelection: TranscriptionLanguageSelection
    let micOnlyByChoice: Bool
    var confirmationMeetingId: UUID? = nil
}

struct MeetingTranscriptionRequestBuilder {
    private let localSpeakerPreference: () -> Bool

    init(localSpeakerPreference: @escaping () -> Bool = LocalSpeakerPreferences.isEnabled) {
        self.localSpeakerPreference = localSpeakerPreference
    }

    func currentOptions() -> MeetingTranscriptionOptions {
        .resolve(localSpeakerPreference: localSpeakerPreference)
    }

    func savedAudioRetranscription(
        micURL: URL?,
        systemURL: URL,
        meetingTitle: String?,
        replacementTranscriptURL: URL?,
        recordingDate: Date?
    ) -> SavedAudioRetranscriptionRequest {
        SavedAudioRetranscriptionRequest(
            micURL: micURL,
            systemURL: systemURL,
            meetingTitle: meetingTitle,
            replacementTranscriptURL: replacementTranscriptURL,
            recordingDate: recordingDate,
            options: currentOptions()
        )
    }

    /// Snapshots People-in-the-room at enqueue, so changing the setting while
    /// the job waits doesn't change how it runs.
    func recordedMeeting(
        micURL: URL?,
        systemURL: URL?,
        meetingTitle: String?,
        recordingDate: Date
    ) -> RecordedMeetingTranscriptionRequest {
        RecordedMeetingTranscriptionRequest(
            micURL: micURL,
            systemURL: systemURL,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            options: currentOptions()
        )
    }

    /// A queued recorded job that never ran keeps its enqueue snapshot.
    func failedQueueRow(
        forQueued request: RecordedMeetingTranscriptionRequest,
        errorMessage: String,
        languageSelection: TranscriptionLanguageSelection,
        micOnlyByChoice: Bool
    ) -> FailedMeetingRetryRow {
        FailedMeetingRetryRow(
            micURL: request.micURL,
            systemURL: request.systemURL,
            errorMessage: errorMessage,
            meetingTitle: request.meetingTitle,
            recordingDate: request.recordingDate,
            splitLocalSpeakers: request.options.splitLocalSpeakers,
            languageSelection: languageSelection,
            micOnlyByChoice: micOnlyByChoice
        )
    }

    /// Imported audio is one system-channel file; it never splits the mic.
    func failedQueueRow(
        forImportedAudio audioURL: URL,
        suggestedTitle: String,
        recordingDate: Date,
        errorMessage: String,
        languageSelection: TranscriptionLanguageSelection
    ) -> FailedMeetingRetryRow {
        FailedMeetingRetryRow(
            micURL: nil,
            systemURL: audioURL,
            errorMessage: errorMessage,
            meetingTitle: suggestedTitle,
            recordingDate: recordingDate,
            splitLocalSpeakers: false,
            languageSelection: languageSelection,
            micOnlyByChoice: false
        )
    }
}
