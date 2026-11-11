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
    /// Optional for journals written before language selection existed.
    var languageSelection: TranscriptionLanguageSelection? = nil
    /// True for a "Record Just My Mic" recording, so crash recovery keeps the
    /// choice on its failed-queue row. Nil (not false) for two-sided ones.
    var micOnlyByChoice: Bool? = nil
}

enum MeetingRecordingJournalStartError: Error, Equatable {
    case alreadyExists
    case persistenceFailed
}

/// Opaque ownership token for one recording session's journal writes. Issued
/// by `begin()`; every mutation must present the matching token or it is
/// dropped. Stop-path finalization can land seconds after `stop()` returns
/// (multi-segment merges), so without the token a previous session's late
/// writes would corrupt the journal of the recording that is now active.
struct MeetingRecordingJournalSession: Equatable, Hashable, Sendable {
    private let id: UUID
    private let liveOwnership: MeetingRecordingJournalLiveOwnership

    init(journalURL: URL) {
        self.id = UUID()
        self.liveOwnership = MeetingRecordingJournalLiveOwnership(
            id: id,
            journalURL: journalURL
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func releaseLiveOwnership() {
        liveOwnership.release()
    }
}

private final class MeetingRecordingJournalLiveOwnership: @unchecked Sendable {
    private let id: UUID
    private let lock = NSLock()
    private var isReleased = false

    init(id: UUID, journalURL: URL) {
        self.id = id
        MeetingRecordingJournalStore.claimLiveOwnership(of: journalURL, id: id)
    }

    deinit {
        release()
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        MeetingRecordingJournalStore.releaseLiveOwnership(id: id)
    }
}

