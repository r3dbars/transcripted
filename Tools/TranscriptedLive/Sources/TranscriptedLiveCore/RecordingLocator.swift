import Foundation

/// The subset of the app's `MeetingRecordingJournal` the helper needs. The app
/// writes `<stem>.recording.json` next to the WAVs while a meeting records and
/// removes it once the recording is finalized.
struct RecordingJournal: Decodable {
    struct Segment: Decodable {
        let filename: String
    }

    let state: String
    let startedAt: Date
    let primaryMicFilename: String?
    let micSegments: [Segment]?
    let systemAudioFilename: String?
}

public struct ActiveRecording: Equatable {
    public let meetingId: String
    public let journalURL: URL
    public let state: String
    public let startedAt: Date
    /// The primary mic file, then any device-recovery segments, in order.
    public let micFiles: [URL]
    public let systemFile: URL?
    /// Newest modification time across the journal and its audio files.
    public let lastActivity: Date
}

public enum RecordingLocator {
    public static let journalSuffix = ".recording.json"

    public static var defaultRecordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripted/tmp/recordings", isDirectory: true)
    }

    /// Recordings whose journal says `recording` and whose files changed within
    /// `freshWithin` seconds. A crash can leave a stale journal behind; the
    /// freshness check keeps the helper from treating it as live.
    public static func liveRecordings(in directory: URL, freshWithin: TimeInterval = 30, now: Date = Date()) -> [ActiveRecording] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(journalSuffix) }
            .compactMap { read(journalAt: directory.appendingPathComponent($0)) }
            .filter { $0.state == "recording" && now.timeIntervalSince($0.lastActivity) <= freshWithin }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public static func read(journalAt url: URL) -> ActiveRecording? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let journal = try? decoder.decode(RecordingJournal.self, from: data) else {
            return nil
        }

        let directory = url.deletingLastPathComponent()
        var micNames: [String] = []
        for name in [journal.primaryMicFilename].compactMap({ $0 }) + (journal.micSegments ?? []).map(\.filename)
        where !micNames.contains(name) {
            micNames.append(name)
        }
        let micFiles = micNames.map { directory.appendingPathComponent($0) }
        let systemFile = journal.systemAudioFilename.map { directory.appendingPathComponent($0) }

        let activity = ([url] + micFiles + [systemFile].compactMap { $0 })
            .compactMap { modificationDate(of: $0) }
            .max() ?? journal.startedAt

        let meetingId = String(url.lastPathComponent.dropLast(journalSuffix.count))
        return ActiveRecording(
            meetingId: meetingId, journalURL: url, state: journal.state, startedAt: journal.startedAt,
            micFiles: micFiles, systemFile: systemFile, lastActivity: activity
        )
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
