import Foundation
import AVFoundation

// MARK: - Pipeline side effects (audio archive, transcript commit, rollback)

extension TranscriptionTaskManager {

    struct RecordingAudioArchiveOutcome {
        let canRemoveMicScratch: Bool
        let canRemoveSystemScratch: Bool
        let retainedAudioDirectory: URL?
        let retainedAudioURLs: [URL]
    }

    /// Not `private`: exercised directly (via `@testable import`) by pipeline-rollback tests
    /// that drive `registerSavedTranscriptRollback` through both its delete and restore branches
    /// without re-running the whole async pipeline. Still internal-only — outside the module
    /// boundary this stays invisible, same as before.
    struct ReplacementTranscriptRollback: Sendable {
        let url: URL
        let originalData: Data
        private let originalFileDates: OriginalFileDates?
        let transcriptId: UUID?

        static func capture(for targetURL: URL?) throws -> ReplacementTranscriptRollback? {
            guard let targetURL else { return nil }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }

            let originalData = try Data(contentsOf: targetURL)
            let originalFileDates = OriginalFileDates.capture(for: targetURL)
            let values = try? TranscriptFrontmatter.readValues(from: targetURL)
            let transcriptId = replacementTranscriptId(from: values)
            return ReplacementTranscriptRollback(
                url: targetURL,
                originalData: originalData,
                originalFileDates: originalFileDates,
                transcriptId: transcriptId
            )
        }

        func restore() {
            do {
                try originalData.write(to: url, options: .atomic)
                FileManager.default.restrictToOwnerOnly(atPath: url.path)
                originalFileDates?.restore(to: url)
            } catch {
                AppLogger.pipeline.error("Failed to restore cancelled replacement transcript", [
                    "error": error.localizedDescription
                ])
            }
        }

        private struct OriginalFileDates: Sendable {
            let creationDate: Date?
            let modificationDate: Date?

            static func capture(for url: URL) -> OriginalFileDates? {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    return nil
                }

                return OriginalFileDates(
                    creationDate: attributes[.creationDate] as? Date,
                    modificationDate: attributes[.modificationDate] as? Date
                )
            }

            func restore(to url: URL) {
                var attributes: [FileAttributeKey: Any] = [:]
                if let creationDate {
                    attributes[.creationDate] = creationDate
                }
                if let modificationDate {
                    attributes[.modificationDate] = modificationDate
                }
                guard !attributes.isEmpty else { return }

                do {
                    try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
                } catch {
                    AppLogger.pipeline.warning("Failed to restore replacement rollback file dates", [
                        "error_type": String(describing: type(of: error))
                    ])
                }
            }
        }

        private static func replacementTranscriptId(from values: [String: String]?) -> UUID? {
            values.flatMap(TranscriptFrontmatter.captureID(in:))
        }
    }

    nonisolated func archiveRecordingAudioIfConfigured(
        micURL: URL?,
        systemURL: URL?,
        savedURL: URL
    ) async -> RecordingAudioArchiveOutcome {
        let retainedAudioDirectory = await MainActor.run { self.resolvedRetainedAudioDirectory() }
        guard let retainedAudioDirectory else {
            return RecordingAudioArchiveOutcome(
                // Retention is disabled, so the committed transcript is the
                // terminal owner and both scratch sources can follow the
                // existing cleanup path.
                canRemoveMicScratch: true,
                canRemoveSystemScratch: true,
                retainedAudioDirectory: nil,
                retainedAudioURLs: []
            )
        }

        do {
            let retainedAudio = try RecordingAudioArchiver.archive(
                micURL: micURL,
                systemURL: systemURL,
                transcriptURL: savedURL,
                archiveRoot: retainedAudioDirectory
            )
            let archivedEveryProvidedSource = (micURL == nil || retainedAudio.micURL != nil)
                && (systemURL == nil || retainedAudio.systemURL != nil)
            if !archivedEveryProvidedSource {
                AppLogger.pipeline.warning("Retained only part of the meeting audio; leaving scratch files in place", [
                    "micArchived": "\(retainedAudio.micURL != nil)",
                    "systemArchived": "\(retainedAudio.systemURL != nil)"
                ])
            }
            AppLogger.pipeline.info("Retained meeting audio files", [
                "hasMic": "\(retainedAudio.micURL != nil)",
                "hasSystem": "\(retainedAudio.systemURL != nil)"
            ])
            return RecordingAudioArchiveOutcome(
                // Clean only a source with a durable retained copy. If the
                // other copy failed, its original remains available for the
                // bounded temp/recovery path instead of making both successful
                // and failed sources permanent scratch orphans.
                canRemoveMicScratch: micURL == nil || retainedAudio.micURL != nil,
                canRemoveSystemScratch: systemURL == nil || retainedAudio.systemURL != nil,
                retainedAudioDirectory: retainedAudio.directory,
                retainedAudioURLs: [retainedAudio.micURL, retainedAudio.systemURL].compactMap { $0 }
            )
        } catch {
            AppLogger.pipeline.warning("Failed to retain meeting audio; leaving scratch files in place", [
                "hasMic": "\(micURL != nil)",
                "hasSystem": "\(systemURL != nil)",
                "errorType": "\(type(of: error))"
            ])
            return RecordingAudioArchiveOutcome(
                canRemoveMicScratch: false,
                canRemoveSystemScratch: false,
                retainedAudioDirectory: nil,
                retainedAudioURLs: []
            )
        }
    }

    private func commitSavedTranscriptSideEffects(
        savedURL: URL,
        result: TranscriptionResult,
        transcriptId: UUID,
        meetingTitle: String?,
        transcriptDate: Date,
        notifier: TranscriptNotifier?
    ) {
        if let notifier {
            Task { @MainActor in
                notifier.notifyTranscriptSaved(fileURL: savedURL)
            }
        }

        let metadata = RecordingMetadata.from(
            result: result,
            captureId: transcriptId,
            transcriptPath: savedURL.path,
            title: meetingTitle,
            date: transcriptDate
        )
        (statsStore ?? StatsDatabase.shared).recordSession(metadata)
    }

    /// Not `private`: the "superseded task" branch below (`canCommitTaskSideEffects` returning
    /// false without any `Task.checkCancellation()` throw) is exercised directly by
    /// `PipelineRollbackRegistryManagerTests` so that scenario is tested against the real
    /// method instead of only inferred from `PipelineRollbackRegistry`'s generic behavior.
    func commitSavedTranscriptSideEffectsUnlessCancelled(
        taskId: UUID,
        savedURL: URL,
        result: TranscriptionResult,
        transcriptId: UUID,
        meetingTitle: String?,
        transcriptDate: Date,
        notifier: TranscriptNotifier?,
        rollback: PipelineRollbackRegistry
    ) async throws {
        try await rollback.checkCancellation()

        let didCommit: Bool
        do {
            didCommit = try await MainActor.run {
                guard canCommitTaskSideEffects(taskId: taskId) else { return false }
                // Persist identity before releasing import recovery ownership.
                try markTaskTranscriptCommitted(taskId: taskId, transcriptId: transcriptId)
                commitSavedTranscriptSideEffects(
                    savedURL: savedURL,
                    result: result,
                    transcriptId: transcriptId,
                    meetingTitle: meetingTitle,
                    transcriptDate: transcriptDate,
                    notifier: notifier
                )
                return true
            }
        } catch {
            await rollback.rollbackAll()
            throw error
        }

        guard didCommit else {
            await rollback.rollbackAll()
            throw CancellationError()
        }
    }

    /// Restore replaced Markdown or remove newly saved Markdown on rollback.
    nonisolated static func registerSavedTranscriptRollback(
        savedURL: URL,
        replacementTranscriptRollback: ReplacementTranscriptRollback?,
        into rollback: PipelineRollbackRegistry
    ) {
        if let replacementTranscriptRollback {
            rollback.register {
                replacementTranscriptRollback.restore()
            }
        } else {
            rollback.register {
                try? FileManager.default.removeItem(at: savedURL)
                AppLogger.pipeline.info("Rollback: deleted saved transcript", ["file": savedURL.lastPathComponent])
            }
        }
    }

    /// Registers the retained-audio rollback: remove the archived audio files, then remove
    /// the archive directory if that leaves it empty. No-op when nothing was archived.
    nonisolated static func registerRetainedAudioRollback(
        directory: URL?,
        urls: [URL],
        into rollback: PipelineRollbackRegistry
    ) {
        guard directory != nil || !urls.isEmpty else { return }
        rollback.register {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            if let directory {
                let remaining = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )) ?? []
                if remaining.isEmpty {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            AppLogger.pipeline.info("Rollback: removed retained meeting audio", [
                "files": "\(urls.count)",
                "directoryRemoved": "\(directory != nil)"
            ])
        }
    }

    /// Registers the rollback for one channel's freshly extracted speaker clips. No-op when
    /// extraction produced nothing (matches today's behavior of only ever removing clips that
    /// actually exist).
    nonisolated static func registerSpeakerClipsRollback(
        _ urls: [URL],
        channel: String,
        into rollback: PipelineRollbackRegistry
    ) {
        guard !urls.isEmpty else { return }
        rollback.register {
            for url in urls {
                SpeakerClipExtractor.removeClipAndSidecar(at: url, label: "extracted speaker clip")
            }
            AppLogger.pipeline.info("Rollback: removed extracted speaker clips", [
                "channel": channel,
                "count": "\(urls.count)"
            ])
        }
    }

}

/// Accumulates undo closures for side effects performed while one transcription pipeline run
/// (`transcribeMultichannelPipeline` / `transcribeMicrophoneOnlyPipeline`) progresses, so a late
/// cancellation rolls back exactly what has happened without every checkpoint re-stating a
/// growing "what to clean up if cancelled" parameter list. Each side effect registers its own
/// undo as it happens; `checkCancellation()` runs them (most-recently-registered first) only if
/// the run is actually cancelled at that point.
///
/// Created fresh per pipeline run and only ever driven by that run's single sequential `async`
/// call chain — never handed to a concurrent Task or shared across runs. `@unchecked Sendable`
/// here just satisfies the compiler for the awaited hops between the pipeline's `nonisolated`
/// code and its `@MainActor` helpers; it is not asserting safety under real concurrent access.
final class PipelineRollbackRegistry: @unchecked Sendable {
    private var undos: [() async -> Void] = []

    /// Register an undo for a side effect that just happened. Undos run in LIFO order — most
    /// recently registered first — mirroring "last thing done, first thing undone".
    func register(_ undo: @escaping () async -> Void) {
        undos.append(undo)
    }

    /// Checks for cancellation. If cancelled, rolls back every registered undo and rethrows.
    func checkCancellation() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            await rollbackAll()
            throw error
        }
    }

    /// Runs every registered undo (most-recently-registered first), then clears the registry.
    /// Idempotent: undos are consumed as they run, so a second call is a no-op.
    func rollbackAll() async {
        guard !undos.isEmpty else { return }
        let pending = Array(undos.reversed())
        undos.removeAll()
        AppLogger.pipeline.info("Rolling back pipeline side effects", ["steps": "\(pending.count)"])
        for undo in pending {
            await undo()
        }
    }
}

@available(macOS 14.0, *)
struct DeferredTranscriptStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}
    func getTotalRecordingsCount() -> Int { 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }
    func recordingExists(transcriptPath: String) -> Bool { false }
}
