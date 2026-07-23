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

    /// Applies an explicit terminal decision to the current recording. The
    /// in-memory journal is the only complete inventory when stop never calls
    /// back, so snapshot it before deleting every owned segment and the journal.
    func discardCurrentRecordingArtifacts(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        allowedRoot: URL
    ) {
        let snapshot = queue.sync {
            let snapshot = (journalURL: self.journalURL, journal: self.journal)
            self.journal = nil
            self.journalURL = nil
            self.activeSession = nil
            return snapshot
        }
        Self.discardRecordingArtifacts(
            journalURL: snapshot.journalURL,
            journal: snapshot.journal,
            additionalAudioURLs: [micAudioURL, systemAudioURL].compactMap { $0 },
            allowedRoots: [allowedRoot]
        )
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

    static func hasJournal(forMicAudioURL micURL: URL) -> Bool {
        journalURLs(forMicAudioURL: micURL).contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Deletes a terminal recording's complete journal-owned inventory. The
    /// supplied URLs are useful after a merge, while the journal contributes
    /// every pre-merge recovery segment when completion never arrives.
    static func discardRecordingArtifacts(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        allowedRoots: [URL]
    ) {
        let canonicalRoots = allowedRoots.map { canonicalURL($0) }
        let safeMicURL = micAudioURL.flatMap { url in
            isContained(url, in: canonicalRoots) ? url : nil
        }
        let journalCandidates = safeMicURL.map { journalURLs(forMicAudioURL: $0) } ?? []
        let journalURL = journalCandidates.first { candidate in
            isContained(candidate, in: canonicalRoots)
                && FileManager.default.fileExists(atPath: candidate.path)
        }
        discardRecordingArtifacts(
            journalURL: journalURL,
            journal: journalURL.flatMap(load(at:)),
            additionalAudioURLs: [micAudioURL, systemAudioURL].compactMap { $0 },
            allowedRoots: canonicalRoots
        )
    }

    private static func discardRecordingArtifacts(
        journalURL: URL?,
        journal: MeetingRecordingJournal?,
        additionalAudioURLs: [URL],
        allowedRoots: [URL]
    ) {
        let canonicalRoots = allowedRoots.map { canonicalURL($0) }
        var audioURLs = Set(additionalAudioURLs.filter { isContained($0, in: canonicalRoots) })

        if let journalURL,
           isContained(journalURL, in: canonicalRoots),
           let journal {
            let directory = journalURL.deletingLastPathComponent()
            let filenames = [
                journal.primaryMicFilename,
                journal.systemAudioFilename,
                journal.finalMicFilename,
            ].compactMap { $0 } + journal.micSegments.map(\.filename)
            for filename in filenames where isSafeFilename(filename) {
                let url = directory.appendingPathComponent(filename)
                if isContained(url, in: canonicalRoots) {
                    audioURLs.insert(url)
                }
            }
            if let primaryFilename = journal.primaryMicFilename,
               isSafeFilename(primaryFilename) {
                let primaryStem = (primaryFilename as NSString).deletingPathExtension
                let mergedURL = directory.appendingPathComponent(primaryStem + "_merged.wav")
                if isContained(mergedURL, in: canonicalRoots) {
                    audioURLs.insert(mergedURL)
                }
            }
        }

        for url in audioURLs {
            try? FileManager.default.removeItem(at: url)
        }
        if let journalURL, isContained(journalURL, in: canonicalRoots) {
            try? FileManager.default.removeItem(at: journalURL)
        }
    }

    private static func journalURLs(forMicAudioURL micURL: URL) -> [URL] {
        let directory = micURL.deletingLastPathComponent()
        let stem = micURL.deletingPathExtension().lastPathComponent
        var stems = [stem]
        if stem.hasSuffix("_merged") {
            stems.append(String(stem.dropLast("_merged".count)))
        }
        return stems.map { directory.appendingPathComponent($0 + filenameSuffix) }
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty && !filename.contains("/") && !filename.contains("..")
    }

    private static func isContained(_ url: URL, in canonicalRoots: [URL]) -> Bool {
        let path = canonicalURL(url).path
        return canonicalRoots.contains { root in
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            return path.hasPrefix(rootPath)
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Removes the journal matching a meeting's mic audio file, tolerating the
    /// `_merged` rename the segment merger applies.
    static func removeJournal(forMicAudioURL micURL: URL, allowedRoots: [URL]) {
        let canonicalRoots = allowedRoots.map { canonicalURL($0) }
        guard isContained(micURL, in: canonicalRoots) else { return }
        for journalURL in journalURLs(forMicAudioURL: micURL) {
            if isContained(journalURL, in: canonicalRoots),
               FileManager.default.fileExists(atPath: journalURL.path) {
                try? FileManager.default.removeItem(at: journalURL)
                AppLogger.audio.debug("Removed recording journal after durable handoff", [
                    "file": journalURL.lastPathComponent
                ])
            }
        }
    }
}
