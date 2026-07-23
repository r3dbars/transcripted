import Foundation

enum ImportedTranscriptionQueueJournalPhase: String, Codable, Equatable, Sendable {
    case queued
    case active
    case transcriptCommitted
    case scratchCleanupPending
}

enum ImportedTranscriptionQueueJournalRecoveryAction: Equatable {
    case replayTranscription
    case cleanScratch
    case handOffScratch
}

struct ImportedTranscriptionQueueJournalOwner: Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let claimedAt: Date
}

struct ImportedTranscriptionQueueJournalRecord: Codable, Equatable, Sendable {
    let id: UUID
    let audioFilename: String
    let recordingDate: Date
    let enqueuedAt: Date
    let sttModelRawValue: String
    var phase: ImportedTranscriptionQueueJournalPhase
    var owner: ImportedTranscriptionQueueJournalOwner?

    init(
        id: UUID,
        audioFilename: String,
        recordingDate: Date,
        enqueuedAt: Date,
        sttModelRawValue: String,
        phase: ImportedTranscriptionQueueJournalPhase = .queued,
        owner: ImportedTranscriptionQueueJournalOwner? = nil
    ) {
        self.id = id
        self.audioFilename = audioFilename
        self.recordingDate = recordingDate
        self.enqueuedAt = enqueuedAt
        self.sttModelRawValue = sttModelRawValue
        self.phase = phase
        self.owner = owner
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case audioFilename
        case recordingDate
        case enqueuedAt
        case sttModelRawValue
        case phase
        case owner
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        audioFilename = try values.decode(String.self, forKey: .audioFilename)
        recordingDate = try values.decode(Date.self, forKey: .recordingDate)
        enqueuedAt = try values.decode(Date.self, forKey: .enqueuedAt)
        sttModelRawValue = try values.decode(String.self, forKey: .sttModelRawValue)
        phase = try values.decodeIfPresent(
            ImportedTranscriptionQueueJournalPhase.self,
            forKey: .phase
        ) ?? .queued
        owner = try values.decodeIfPresent(
            ImportedTranscriptionQueueJournalOwner.self,
            forKey: .owner
        )
    }
}

enum ImportedTranscriptionQueueJournalError: Error {
    case audioOutsideScratchDirectory
    case claimFailed
    case journalMissing
}
