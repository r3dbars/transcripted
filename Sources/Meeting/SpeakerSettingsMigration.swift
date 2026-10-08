import Combine
import TranscriptedCore

/// A value-only projection of the migration gate. Publication stays synchronous
/// so Settings cannot admit an edit between a gate change and its mirror.
enum SpeakerSettingsMigrationPhase: Sendable, Equatable {
    struct Summary: Sendable, Equatable {
        let movedThisRun: Int
        let alreadyMoved: Int
        let peopleNeedingConfirmation: Int
        let wasCancelled: Bool
    }
    case idle
    case moving(completedPeople: Int, totalPeople: Int?)
    case finished(Summary)
    case failed(reason: String)

    init(_ phase: SpeakerVoiceprintMigrationGate.Phase) {
        switch phase {
        case .idle: self = .idle
        case .moving(let completed, let total): self = .moving(completedPeople: completed, totalPeople: total)
        case .finished(let summary):
            self = .finished(
                .init(
                    movedThisRun: summary.movedThisRun, alreadyMoved: summary.alreadyMoved,
                    peopleNeedingConfirmation: summary.peopleNeedingConfirmation, wasCancelled: summary.wasCancelled))
        case .failed(let reason): self = .failed(reason: reason)
        }
    }
}

@MainActor
struct SpeakerSettingsMigration {
    private let gate: SpeakerVoiceprintMigrationGate
    init(_ gate: SpeakerVoiceprintMigrationGate) { self.gate = gate }
    var phase: SpeakerSettingsMigrationPhase { .init(gate.phase) }
    var phases: AnyPublisher<SpeakerSettingsMigrationPhase, Never> {
        gate.$phase.map(SpeakerSettingsMigrationPhase.init).eraseToAnyPublisher()
    }
}

extension MeetingSessionController {
    func speakerStoreForSettings() -> SpeakerSettingsStore {
        SpeakerSettingsStore(
            speakerDatabase: speakerDatabaseForSettings(),
            transcriptDirectory: MeetingStoragePaths.transcriptsFolder,
            preferredClipsDirectory: MeetingStoragePaths.speakerClipsFolder)
    }
    var speakerMigrationForSettings: SpeakerSettingsMigration { .init(voiceprintMigrationGate) }
    var speakerNamingRequests: AnyPublisher<SpeakerNamingRequest?, Never> {
        taskManager.$speakerNamingRequest.eraseToAnyPublisher()
    }
}
