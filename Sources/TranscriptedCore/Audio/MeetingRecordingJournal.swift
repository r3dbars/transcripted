import Foundation

/// On-disk record of an in-progress meeting recording, kept next to the audio
/// in the recordings scratch directory.
///
/// The journal exists from recording start until the meeting reaches a durable
/// state elsewhere (transcript saved, or failed-queue entry persisted). The
/// failed-transcription queue only records meetings whose preservation code
/// actually ran — a crash, force-kill, or power loss before that point leaves
/// audio on disk with no record at all. The journal is that record: the launch
/// recovery scan reads any journal left behind and turns its audio into a
/// visible, retryable failed-queue entry.
struct MeetingRecordingJournal: Codable, Equatable {
    enum State: String, Codable {
        case recording
        case stopping
        case finalized
    }

    struct SegmentRecord: Codable, Equatable {
        var filename: String
        var gapBefore: TimeInterval
    }

    var version: Int
    var state: State
    var startedAt: Date
    var updatedAt: Date
    /// Filenames are relative to the journal's own directory so records stay
    /// valid if Application Support is relocated.
    var primaryMicFilename: String?
    var micSegments: [SegmentRecord]
    var systemAudioFilename: String?
    /// Set when finalization completed: the merged file, or the primary.
    var finalMicFilename: String?
}

/// Opaque ownership token for one recording session's journal writes. Issued
/// by `begin()`; every mutation must present the matching token or it is
/// dropped. Stop-path finalization can land seconds after `stop()` returns
/// (multi-segment merges), so without the token a previous session's late
/// writes would corrupt the journal of the recording that is now active.
struct MeetingRecordingJournalSession: Equatable, Sendable {
    private let id: UUID

    init() {
        self.id = UUID()
    }
}

final class MeetingRecordingJournalStore: @unchecked Sendable {
    static let filenameSuffix = ".recording.json"

    private let directory: URL
    private let queue = DispatchQueue(label: "com.transcripted.recording-journal", qos: .utility)
    private var journalURL: URL?
    private var journal: MeetingRecordingJournal?
    private var activeSession: MeetingRecordingJournalSession?

    init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    func begin(primaryMicURL: URL, startedAt: Date = Date()) -> MeetingRecordingJournalSession {
        let session = MeetingRecordingJournalSession()
        queue.async {
            let name = primaryMicURL.deletingPathExtension().lastPathComponent + Self.filenameSuffix
            self.activeSession = session
            self.journalURL = self.directory.appendingPathComponent(name)
            self.journal = MeetingRecordingJournal(
                version: 1,
                state: .recording,
                startedAt: startedAt,
                updatedAt: startedAt,
                primaryMicFilename: primaryMicURL.lastPathComponent,
                micSegments: [MeetingRecordingJournal.SegmentRecord(
                    filename: primaryMicURL.lastPathComponent,
                    gapBefore: 0
                )],
                systemAudioFilename: nil,
                finalMicFilename: nil
            )
            self.persistLocked()
        }
        return session
    }

    func recordSystemAudio(_ url: URL, session: MeetingRecordingJournalSession?) {
        mutate(session: session) { $0.systemAudioFilename = url.lastPathComponent }
    }

    func recordSegments(_ segments: [MicRecordingSegment], session: MeetingRecordingJournalSession?) {
        let records = segments.map {
            MeetingRecordingJournal.SegmentRecord(
                filename: $0.url.lastPathComponent,
                gapBefore: $0.gapBeforeDuration
            )
        }
        mutate(session: session) { $0.micSegments = records }
    }

    func markStopping(session: MeetingRecordingJournalSession?) {
        mutate(session: session) { $0.state = .stopping }
    }

    func markFinalized(finalMicURL: URL?, session: MeetingRecordingJournalSession?) {
        mutate(session: session) {
            $0.state = .finalized
            $0.finalMicFilename = finalMicURL?.lastPathComponent
        }
    }

    /// The meeting reached a durable state elsewhere; the journal's job is done.
    func clear() {
        queue.async {
            if let url = self.journalURL {
                try? FileManager.default.removeItem(at: url)
            }
            self.journal = nil
            self.journalURL = nil
            self.activeSession = nil
        }
    }

    /// Blocks until queued writes have hit disk. Test seam.
    func flush() {
        queue.sync {}
    }

    private func mutate(
        session: MeetingRecordingJournalSession?,
        _ change: @escaping (inout MeetingRecordingJournal) -> Void
    ) {
        queue.async {
            // Only the session that began this journal may write to it. A nil
            // session (a stop with no active recording) owns nothing.
            guard let session, session == self.activeSession else { return }
            guard var journal = self.journal, let journalURL = self.journalURL else { return }
            // The file vanishing means the meeting already reached a durable
            // state and `removeJournal(forMicAudioURL:)` deleted it without
            // access to this instance. Drop the in-memory copy instead of
            // re-persisting: a resurrected journal becomes a duplicate
            // failed-queue entry on the next launch's recovery scan.
            guard FileManager.default.fileExists(atPath: journalURL.path) else {
                self.journal = nil
                self.journalURL = nil
                self.activeSession = nil
                return
            }
            change(&journal)
            journal.updatedAt = Date()
            self.journal = journal
            self.persistLocked()
        }
    }

    private func persistLocked() {
        guard let journal, let journalURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(journal)
            try data.write(to: journalURL, options: .atomic)
            FileManager.default.restrictToOwnerOnly(atPath: journalURL.path)
        } catch {
            AppLogger.audio.warning("Failed to persist recording journal", [
                "file": journalURL.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - Recovery + handoff helpers

    static func journalURLs(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.lastPathComponent.hasSuffix(filenameSuffix) }
    }

    static func load(at url: URL) -> MeetingRecordingJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingRecordingJournal.self, from: data)
    }

    /// Removes the journal matching a meeting's mic audio file, tolerating the
    /// `_merged` rename the segment merger applies.
    static func removeJournal(forMicAudioURL micURL: URL) {
        let directory = micURL.deletingLastPathComponent()
        let stem = micURL.deletingPathExtension().lastPathComponent
        var candidates = [stem]
        if stem.hasSuffix("_merged") {
            candidates.append(String(stem.dropLast("_merged".count)))
        }
        for candidate in candidates {
            let journalURL = directory.appendingPathComponent(candidate + filenameSuffix)
            if FileManager.default.fileExists(atPath: journalURL.path) {
                try? FileManager.default.removeItem(at: journalURL)
                AppLogger.audio.debug("Removed recording journal after durable handoff", [
                    "file": journalURL.lastPathComponent
                ])
            }
        }
    }
}
