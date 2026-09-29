// SpeakerVoiceprintMigrationGate.swift
// Holds everything that writes the speaker database while a voiceprint
// migration carries saved people into it, so nothing races the carry-over.
//
// The host starts one migration per launch (`start`). Until it ends the gate is
// closed, and each speaker-database writer (the transcription queue, failed
// meeting retries, saved-audio re-transcription, Speakers edits) calls
// `await waitUntilOpen()` first. The gate opens when the run ends for any
// reason: finished, cancelled or failed. Waiting only ever delays work; it
// never fails it.
//
// A failure is logged with a reason code only (no names, no paths) and doesn't
// block anyone. The next launch runs again, and the migration's ledger in the
// target database makes that pick up where this one stopped. The source
// database is only read (see SpeakerVoiceprintSourceSnapshot.swift).

import Combine
import Foundation

@available(macOS 14.0, *)
@MainActor
public final class SpeakerVoiceprintMigrationGate: ObservableObject {

    public struct Summary: Sendable, Equatable {
        /// People brought over in this run.
        public let movedThisRun: Int
        /// People an earlier run already handled.
        public let alreadyMoved: Int
        /// Saved people the new model won't name on its own yet: their audio
        /// disagreed with itself (held) or there was none (needs confirmation),
        /// and the user hasn't confirmed or re-named them since.
        public let peopleNeedingConfirmation: Int
        /// The run stopped early; the next one finishes it.
        public let wasCancelled: Bool
    }

    public enum Phase: Sendable, Equatable {
        /// No migration was started. Open.
        case idle
        /// Carrying people over. Closed. `totalPeople` is nil until the run
        /// knows how many are left.
        case moving(completedPeople: Int, totalPeople: Int?)
        /// The run ended. Open.
        case finished(Summary)
        /// The run could not start or stopped with an error. Open.
        /// `reason` is a code such as `source_database_unreadable`.
        case failed(reason: String)
    }

    @Published public private(set) var phase: Phase = .idle

    public var isOpen: Bool {
        if case .moving = phase { return false }
        return true
    }

    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var runTask: Task<Void, Never>?

    public init() {}

    /// Carry the user-named people in `sourceDatabaseURL` into `targetDatabase`
    /// (already open with `embedder.thresholds`), off the main actor. The gate
    /// closes now and opens when the run ends. Does nothing, and stays open,
    /// when the source file isn't there or this gate already started a run.
    public func start(
        sourceDatabaseURL: URL,
        targetDatabase: SpeakerDatabase,
        embedder: any SpeakerSegmentEmbedder,
        sources: SpeakerVoiceprintMigrationSources,
        options: SpeakerVoiceprintMigrationOptions = .init()
    ) {
        guard case .idle = phase, runTask == nil else { return }
        guard FileManager.default.fileExists(atPath: sourceDatabaseURL.path) else { return }

        let migration: SpeakerVoiceprintMigration
        do {
            migration = try SpeakerVoiceprintMigration(
                sourceDatabaseURL: sourceDatabaseURL,
                targetDatabase: targetDatabase,
                embedder: embedder,
                sources: sources,
                options: options
            )
        } catch {
            fail(error)
            return
        }

        phase = .moving(completedPeople: 0, totalPeople: nil)
        runTask = Task.detached(priority: .utility) { [self] in
            let outcome: Result<Summary, Error>
            do {
                let report = try await migration.run { progress in
                    Task { @MainActor in self.record(progress) }
                }
                outcome = .success(Self.summary(of: report, in: targetDatabase))
            } catch {
                outcome = .failure(error)
            }
            await self.finish(outcome)
        }
    }

    /// Returns once the gate is open; true when it had to wait. A cancelled
    /// caller is let go early, so check `Task.isCancelled` afterwards.
    @discardableResult
    public func waitUntilOpen() async -> Bool {
        guard !isOpen else { return false }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.release(waiter: id) }
        }
        return true
    }

    /// Callers currently held.
    var waitingCount: Int { waiters.count }

    // MARK: - Run bookkeeping

    private func record(_ progress: SpeakerVoiceprintMigrationProgress) {
        guard case .moving(let completed, _) = phase, progress.completedPeople >= completed else { return }
        phase = .moving(completedPeople: progress.completedPeople, totalPeople: progress.totalPeople)
    }

    private func finish(_ outcome: Result<Summary, Error>) {
        runTask = nil
        switch outcome {
        case .success(let summary):
            phase = .finished(summary)
        case .failure(let error):
            fail(error)
        }
        let released = waiters
        waiters.removeAll()
        released.forEach { $0.continuation.resume() }
    }

    private func fail(_ error: Error) {
        let reason = Self.reasonCode(for: error)
        AppLogger.speakers.error("Voiceprint migration stopped; it runs again next launch", ["reason": reason])
        phase = .failed(reason: reason)
    }

    private func release(waiter id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    // MARK: - Pure helpers

    /// A code for logs: never a name, a path or SQLite's message text.
    nonisolated static func reasonCode(for error: Error) -> String {
        switch error {
        case let error as SpeakerVoiceprintMigrationError:
            switch error {
            case .sourceDatabaseMissing: return "source_database_missing"
            case .sourceDatabaseUnreadable: return "source_database_unreadable"
            case .targetIsSource: return "target_is_source"
            case .targetDatabaseUnavailable: return "target_database_unavailable"
            case .thresholdsMismatch: return "thresholds_mismatch"
            case .alreadyRunning: return "already_running"
            case .embedderUnavailable: return "embedder_unavailable"
            }
        case let error as SpeakerDatabase.SQLiteOperationError:
            return "sqlite_\(error.code)"
        default:
            return "unexpected"
        }
    }

    nonisolated static func summary(
        of report: SpeakerVoiceprintMigrationReport,
        in database: SpeakerDatabase
    ) -> Summary {
        Summary(
            movedThisRun: report.people.count,
            alreadyMoved: report.alreadyMigrated,
            peopleNeedingConfirmation: peopleNeedingConfirmation(
                ledger: database.voiceprintMigrationLedger(),
                profiles: database.allSpeakers()
            ),
            wasCancelled: report.wasCancelled
        )
    }

    /// Ledger people the new model still can't name on its own. A held person
    /// stops counting once they have a confirmation under the new model (the
    /// next run gives back the rest) or their profile is gone; someone with no
    /// usable audio stops counting once a person by that name is saved again.
    nonisolated static func peopleNeedingConfirmation(
        ledger: [SpeakerVoiceprintMigrationLedgerEntry],
        profiles: [SpeakerProfile]
    ) -> Int {
        let profilesById = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let savedNames = Set(profiles.compactMap { normalizedName($0.displayName) })
        return ledger.filter { entry in
            switch entry.status {
            case .carried, .alreadyPresent:
                return false
            case .held:
                guard let profile = profilesById[entry.profileId] else { return false }
                return profile.confirmedMeetingCount == 0
            case .needsConfirmation:
                guard let name = normalizedName(entry.displayName) else { return false }
                return !savedNames.contains(name)
            }
        }.count
    }

    private nonisolated static func normalizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
