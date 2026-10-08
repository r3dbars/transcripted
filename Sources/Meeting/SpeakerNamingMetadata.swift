import Foundation
import TranscriptedCore

enum SpeakerNamingMetadata {
    /// Reads the meeting's name off the main thread. The background restyle
    /// renames the file, so a missing file is found again by its
    /// transcript id.
    static func meetingTitle(for request: SpeakerNamingRequest) async -> String? {
        let url = request.transcriptURL
        let transcriptID = request.transcriptId
        return await Task.detached(priority: .utility) { () -> String? in
            var transcriptURL: URL? = url
            if !FileManager.default.fileExists(atPath: url.path) {
                transcriptURL = TranscriptSaver.existingTranscriptURL(
                    in: url.deletingLastPathComponent(),
                    transcriptId: transcriptID
                )
            }
            return transcriptURL.flatMap { MeetingTranscriptStyler.displayTranscriptPreview(at: $0)?.title }
        }.value
    }

    /// Who was invited to the calendar event this meeting started with.
    /// Imported recordings are skipped: their saved time is when the file
    /// was made, not a calendar slot.
    static func invitees(for request: SpeakerNamingRequest) async -> (names: [String], remoteVoices: Int?)? {
        let url = request.transcriptURL
        let transcriptID = request.transcriptId
        let recording = await Task.detached(priority: .utility) { () -> (start: Date, remoteVoices: Int?)? in
            var transcriptURL: URL? = url
            if !FileManager.default.fileExists(atPath: url.path) {
                transcriptURL = TranscriptSaver.existingTranscriptURL(
                    in: url.deletingLastPathComponent(),
                    transcriptId: transcriptID
                )
            }
            guard let transcriptURL,
                let values = try? TranscriptFrontmatter.readValues(from: transcriptURL),
                values["imported_at"] == nil,
                let start = TranscriptFrontmatter.recordedAt(values: values)
            else { return nil }
            return (start, values["system_speakers"].flatMap { Int($0) })
        }.value
        guard let recording else { return nil }
        let names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: recording.start)
        guard !names.isEmpty else { return nil }
        return (names, recording.remoteVoices)
    }

}
