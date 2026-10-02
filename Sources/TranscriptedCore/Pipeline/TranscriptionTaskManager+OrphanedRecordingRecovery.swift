import Foundation

// MARK: - Orphaned recording recovery: launch-time scan of leftover recording journals

extension TranscriptionTaskManager {
    // MARK: - Orphaned Recording Recovery

    /// Outcome of inspecting one leftover recording journal at launch.
    private struct OrphanedRecordingCandidate: Sendable {
        enum Disposition: Sendable {
            case stale(reason: String)
            case skip(reason: String, retryAfter: TimeInterval?)
            case recover(
                micURL: URL?,
                systemURL: URL?,
                originalMicURL: URL?,
                startedAt: Date
            )
        }
        let journalURL: URL
        let disposition: Disposition
    }

    /// Audio files written within this window are treated as live: another
    /// Transcripted process (a dev build next to production) could be
    /// recording into the same scratch directory right now.
    nonisolated private static let orphanedRecordingLivenessWindow: TimeInterval = 120

    /// Scans the recordings scratch directory for journals left behind by a
    /// previous process and turns their audio into visible, retryable
    /// failed-queue entries. This is the only path that recovers a meeting
    /// whose preservation code never ran (crash, force-kill, power loss).
    @discardableResult
    public func recoverOrphanedRecordings(in scratchDirectory: URL) async -> Int {
        await recoverOrphanedRecordings(
            in: scratchDirectory,
            livenessWindow: Self.orphanedRecordingLivenessWindow,
            waitForRecentJournals: true
        )
    }

    @discardableResult
    func recoverOrphanedRecordings(
        in scratchDirectory: URL,
        livenessWindow: TimeInterval,
        waitForRecentJournals: Bool
    ) async -> Int {
        orphanedRecordingRecoveryRequestGeneration &+= 1
        if let activeRecovery = orphanedRecordingRecoveryTask {
            return await activeRecovery.value
        }

        // One monotonic deadline belongs to the single-flight owner. Joined
        // requests can ask it to rescan, but cannot extend its lifetime.
        let maximumWaitInterval = max(0.02, (livenessWindow * 2) + 0.02)
        let clock = orphanedRecordingRecoveryClock
        let recoveryTask = Task { [weak self] in
            guard let self else { return 0 }
            // Start the budget when the stored owner actually begins running.
            // A busy MainActor must not consume the entire recovery window
            // before the first directory scan has even started.
            let waitDeadline = clock.now().advanced(
                by: .seconds(maximumWaitInterval)
            )
            var totalRecovered = 0
            while clock.now() < waitDeadline {
                let ownerRequestGeneration = self.orphanedRecordingRecoveryRequestGeneration
                totalRecovered += await self.performOrphanedRecordingRecovery(
                    in: scratchDirectory,
                    livenessWindow: livenessWindow,
                    waitForRecentJournals: waitForRecentJournals,
                    waitDeadline: waitDeadline,
                    clock: clock
                )
                if self.orphanedRecordingRecoveryRequestGeneration == ownerRequestGeneration {
                    break
                }
            }
            self.orphanedRecordingRecoveryTask = nil
            return totalRecovered
        }
        orphanedRecordingRecoveryTask = recoveryTask
        orphanedRecordingRecoveryTaskCreatedObserver?()
        return await recoveryTask.value
    }

    private func performOrphanedRecordingRecovery(
        in scratchDirectory: URL,
        livenessWindow: TimeInterval,
        waitForRecentJournals: Bool,
        waitDeadline: ContinuousClock.Instant,
        clock: OrphanedRecordingRecoveryClock
    ) async -> Int {
        let canonicalScratchDirectory = Self.canonicalDirectoryURL(scratchDirectory)
        guard cleanupDirectories.contains(where: { root in
            canonicalScratchDirectory == root
                || Self.isFile(canonicalScratchDirectory, containedIn: root)
        }) else {
            AppLogger.pipeline.warning("Refused recording journal recovery outside managed storage")
            return 0
        }
        var totalRecovered = 0
        while !Task.isCancelled {
            let passRequestGeneration = orphanedRecordingRecoveryRequestGeneration
            let candidates = await Task.detached(priority: .utility) {
                Self.collectOrphanedRecordingCandidates(
                    in: canonicalScratchDirectory,
                    now: clock.date(),
                    livenessWindow: livenessWindow
                )
            }.value
            orphanedRecordingRecoveryPassObserver?()
            await Task.yield()

            var passRecovered = 0
            var retryAfter: TimeInterval?
            // Audio that already has an owner. `isOwnedByLiveFinalizer` is
            // released at the end of *stop* and the mtime window only covers
            // freshly written files, so neither guard covers the transcription
            // phase — nor a job still sitting in the app's queue, which has no
            // entry in `tasks` at all. Recomputed each pass because both sets
            // move while the scan loops.
            let ownedAudioPaths = Set(
                lifecycleOwnedAudioPaths()
                + (reservedAudioURLsProvider?().map { $0.standardizedFileURL.path } ?? [])
            )
            for candidate in candidates {
                switch candidate.disposition {
                case .skip(let reason, let candidateRetryAfter):
                    if let candidateRetryAfter {
                        retryAfter = min(retryAfter ?? candidateRetryAfter, candidateRetryAfter)
                    }
                    AppLogger.pipeline.info("Left recording journal in place", [
                        "file": candidate.journalURL.lastPathComponent,
                        "reason": reason
                    ])
                case .stale(let reason):
                    let didRemoveJournal = MeetingRecordingJournalStore.removeJournalArtifact(
                        at: candidate.journalURL,
                        allowedRoots: [canonicalScratchDirectory]
                    )
                    AppLogger.pipeline.info(didRemoveJournal
                        ? "Removed stale recording journal"
                        : "Left stale recording journal in place", [
                        "file": candidate.journalURL.lastPathComponent,
                        "reason": reason
                    ])
                case .recover(let micURL, let systemURL, let originalMicURL, let startedAt):
                    // Never archive-and-unlink audio that a running or queued
                    // transcription owns. For an in-flight pipeline the open
                    // file handles survive the unlink, so the meeting saves
                    // successfully *and* leaves a bogus "Recording was
                    // interrupted" row behind; for a job still in the queue the
                    // audio is gone before it ever opens it, and that one hard
                    // fails. Defer instead — the rescan picks it up once the
                    // owner is done.
                    let candidateAudioPaths = [micURL, systemURL, originalMicURL]
                        .compactMap { $0?.standardizedFileURL.path }
                    if candidateAudioPaths.contains(where: ownedAudioPaths.contains) {
                        let ownerRetryAfter = Self.orphanedRecordingLivenessWindow
                        retryAfter = min(retryAfter ?? ownerRetryAfter, ownerRetryAfter)
                        AppLogger.pipeline.info("Left recording journal in place", [
                            "file": candidate.journalURL.lastPathComponent,
                            "reason": "owned by active or queued transcription"
                        ])
                        continue
                    }
                    let existingFailure = failedTranscriptionManager.failedTranscriptions.first { failure in
                        failure.micAudioURL.standardizedFileURL == originalMicURL?.standardizedFileURL
                            || failure.micAudioURL.standardizedFileURL == micURL?.standardizedFileURL
                            || (systemURL.map {
                                failure.systemAudioURL?.standardizedFileURL == $0.standardizedFileURL
                            } == true)
                    }
                    let didPersist: Bool
                    if let existingFailure {
                        let recoveredMicURL = micURL ?? existingFailure.micAudioURL
                        didPersist = promoteFinalizedFailedTranscriptionAudio(
                            id: existingFailure.id,
                            micAudioURL: recoveredMicURL,
                            systemAudioURL: systemURL ?? existingFailure.systemAudioURL
                        )
                    } else {
                        let availableAudioURLs = [micURL, systemURL].compactMap { $0 }
                        guard let journal = MeetingRecordingJournalStore.load(at: candidate.journalURL),
                              availableAudioURLs.contains(where: {
                                  FileManager.default.fileExists(atPath: $0.path)
                              }) else {
                            AppLogger.pipeline.info("Skipped stale recording recovery candidate after ownership changed", [
                                "journal": candidate.journalURL.lastPathComponent
                            ])
                            continue
                        }
                        // Persist the new owner before starting any detached
                        // archive work. A user deletion can run while archive
                        // copying is suspended; updateFailedTranscriptionAudio
                        // then rolls that copy back instead of resurrecting the row.
                        didPersist = addFailedTranscriptionRetainingAvailableAudio(
                            micAudioURL: micURL,
                            systemAudioURL: systemURL,
                            errorMessage: "Recording was interrupted before it could be saved. The recovered audio is ready to transcribe.",
                            recordingDate: startedAt,
                            archiveAudio: true,
                            clearRecordingJournalAfterPersistence: false,
                            languageSelection: journal.languageSelection ?? .automatic,
                            micOnlyByChoice: journal.micOnlyByChoice == true
                        )
                    }
                    if didPersist {
                        _ = MeetingRecordingJournalStore.removeJournalArtifact(
                            at: candidate.journalURL,
                            allowedRoots: [canonicalScratchDirectory]
                        )
                        passRecovered += 1
                        AppLogger.pipeline.info("Recovered orphaned recording into failed queue", [
                            "journal": candidate.journalURL.lastPathComponent,
                            "hasMic": "\(micURL != nil)",
                            "hasSystem": "\(systemURL != nil)"
                        ])
                    }
                }
            }
            totalRecovered += passRecovered
            if !candidates.isEmpty {
                AppLogger.pipeline.info("Recording journal scan finished", [
                    "journals": "\(candidates.count)",
                    "recovered": "\(passRecovered)"
                ])
            }

            if orphanedRecordingRecoveryRequestGeneration != passRequestGeneration {
                guard clock.now() < waitDeadline else { return totalRecovered }
                continue
            }

            guard waitForRecentJournals, let retryAfter else {
                return totalRecovered
            }
            do {
                // A restored or tampered file can carry an mtime far in the
                // future. Keep that candidate deferred, but never let it pin
                // the single recovery owner (and every joined request) for an
                // unbounded interval before the next scan.
                let maximumRetryInterval = max(0.01, livenessWindow + 0.01)
                let boundedRetryInterval = min(
                    max(0.01, retryAfter + 0.01),
                    maximumRetryInterval
                )
                let now = clock.now()
                guard now < waitDeadline else { return totalRecovered }
                try await clock.sleep(min(
                    .seconds(boundedRetryInterval),
                    now.duration(to: waitDeadline)
                ))
            } catch {
                return totalRecovered
            }
        }
        return totalRecovered
    }

    nonisolated private static func collectOrphanedRecordingCandidates(
        in directory: URL,
        now: Date,
        livenessWindow: TimeInterval
    ) -> [OrphanedRecordingCandidate] {
        let canonicalDirectory = canonicalDirectoryURL(directory)
        return MeetingRecordingJournalStore.journalURLs(in: canonicalDirectory).compactMap {
            guard !isSymbolicLink($0),
                  isFile($0, containedIn: canonicalDirectory) else { return nil }
            return inspectOrphanedRecordingJournal(
                at: $0,
                directory: canonicalDirectory,
                now: now,
                livenessWindow: livenessWindow
            )
        }
    }

    nonisolated private static func inspectOrphanedRecordingJournal(
        at journalURL: URL,
        directory: URL,
        now: Date,
        livenessWindow: TimeInterval
    ) -> OrphanedRecordingCandidate? {
        guard !MeetingRecordingJournalStore.isOwnedByLiveFinalizer(at: journalURL) else {
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .skip(
                    reason: "owned by live finalizer",
                    retryAfter: max(0.01, min(1, livenessWindow))
                )
            )
        }
        guard let journal = MeetingRecordingJournalStore.load(at: journalURL) else {
            // An unreadable journal may still be the only inventory of mic
            // segments absent from a system-only failed row. Preserve it as
            // durable ownership evidence; deleting it could let a later
            // pending-deletion replay report success while private audio stays.
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .skip(reason: "unreadable journal", retryAfter: nil)
            )
        }

        // Journals store bare filenames; resolve them inside the scratch
        // directory only so a tampered journal cannot point recovery at
        // arbitrary files.
        func resolve(_ filename: String?) -> URL? {
            guard let filename, !filename.isEmpty,
                  !filename.contains("/"), !filename.contains("..") else { return nil }
            let candidate = directory.appendingPathComponent(filename)
            guard !isSymbolicLink(candidate) else { return nil }
            let url = canonicalURL(candidate)
            guard isFile(url, containedIn: directory) else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        func identityURL(_ filename: String?) -> URL? {
            guard let filename, !filename.isEmpty,
                  !filename.contains("/"), !filename.contains("..") else { return nil }
            let candidate = directory.appendingPathComponent(filename)
            guard !isSymbolicLink(candidate) else { return nil }
            let url = canonicalURL(candidate)
            return isFile(url, containedIn: directory) ? url : nil
        }

        let originalMicURL = identityURL(journal.primaryMicFilename)
        let primaryURL = resolve(journal.primaryMicFilename)
        let segmentRecords = journal.micSegments.compactMap { record -> MicRecordingSegment? in
            guard let url = resolve(record.filename) else { return nil }
            return MicRecordingSegment(url: url, gapBeforeDuration: record.gapBefore)
        }
        let systemURL = resolve(journal.systemAudioFilename)
        let finalURL = resolve(journal.finalMicFilename)
        let mergedSibling: URL? = journal.primaryMicFilename.flatMap { primaryName in
            resolve((primaryName as NSString).deletingPathExtension + "_merged.wav")
        }

        let allAudio = ([primaryURL, systemURL, finalURL, mergedSibling] + segmentRecords.map(\.url))
            .compactMap { $0 }
        guard !allAudio.isEmpty else {
            return OrphanedRecordingCandidate(journalURL: journalURL, disposition: .stale(reason: "no audio files remain"))
        }
        if systemURL == nil,
           allAudio.allSatisfy({ $0.lastPathComponent.contains("microphone_placeholder") }) {
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .stale(reason: "only a silent placeholder remains")
            )
        }

        let liveCutoff = now.addingTimeInterval(-livenessWindow)
        let recentModification = allAudio.compactMap { url -> Date? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attributes?[.modificationDate] as? Date
        }.filter { $0 > liveCutoff }.max()
        if let recentModification {
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .skip(
                    reason: "audio recently written",
                    retryAfter: max(
                        0,
                        recentModification.addingTimeInterval(livenessWindow).timeIntervalSince(now)
                    )
                )
            )
        }

        // Crash-orphaned WAVs read as zero-length until their headers are repaired.
        for url in allAudio where url.pathExtension.lowercased() == "wav" {
            if (try? WAVHeaderRepair.repairIfNeeded(at: url)) == true {
                AppLogger.pipeline.info("Repaired orphaned recording WAV header", [
                    "file": url.lastPathComponent
                ])
            }
        }

        var micURL = finalURL ?? mergedSibling
        if micURL == nil, segmentRecords.count > 1 {
            micURL = (try? MicRecordingFileMerger.merge(
                primaryURL: primaryURL ?? segmentRecords[0].url,
                segments: segmentRecords
            ))?.url
        }
        if micURL == nil {
            micURL = primaryURL ?? segmentRecords.first?.url
        }

        guard micURL != nil || systemURL != nil else {
            return OrphanedRecordingCandidate(journalURL: journalURL, disposition: .stale(reason: "no usable audio"))
        }
        return OrphanedRecordingCandidate(
            journalURL: journalURL,
            disposition: .recover(
                micURL: micURL,
                systemURL: systemURL,
                originalMicURL: originalMicURL,
                startedAt: journal.startedAt
            )
        )
    }
}
