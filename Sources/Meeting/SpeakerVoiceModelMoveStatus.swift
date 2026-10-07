import Combine
import Foundation
import TranscriptedCore

/// Where the move of saved people to a new voice model stands, as plain values.
enum SpeakerVoiceModelMove: Equatable {
    /// No move started, or none running.
    case idle
    /// Carrying people over; saved-people edits wait. `total` is nil until the
    /// run knows how many are left.
    case moving(completed: Int, total: Int?)
    /// The move ended. `peopleNeedingConfirmation` still need one answer from
    /// the user before the new model names them on its own.
    case finished(peopleNeedingConfirmation: Int)
    /// The move could not start or stopped with an error; the next launch retries.
    case failed
}

/// Mirrors the meeting controller's voiceprint migration gate for Settings, so
/// the Speakers page can show the move and hold edits until it ends without
/// naming the gate or its Core types.
@MainActor
final class SpeakerVoiceModelMoveStatus {
    private(set) var move: SpeakerVoiceModelMove
    /// Later changes, delivered synchronously with the gate's own change so an
    /// edit can never slip between the two.
    let changes: AnyPublisher<SpeakerVoiceModelMove, Never>

    init(gate: SpeakerVoiceprintMigrationGate) {
        move = Self.move(for: gate.phase)
        changes = gate.$phase
            .dropFirst()
            .map { Self.move(for: $0) }
            .eraseToAnyPublisher()
    }

    nonisolated private static func move(for phase: SpeakerVoiceprintMigrationGate.Phase) -> SpeakerVoiceModelMove {
        switch phase {
        case .idle:
            return .idle
        case .moving(let completed, let total):
            return .moving(completed: completed, total: total)
        case .finished(let summary):
            return .finished(peopleNeedingConfirmation: summary.peopleNeedingConfirmation)
        case .failed:
            return .failed
        }
    }
}
