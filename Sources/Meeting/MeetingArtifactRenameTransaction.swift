import Foundation

/// Executes the failure-sensitive part of a saved-meeting rename. Keeping the
/// transaction here leaves `MeetingArtifactRenamer` responsible for naming and
/// sidecar policy while this type owns journal, rollback, and forward recovery.
struct MeetingArtifactRenameTransaction {
    let sourceTranscriptURL: URL
    let targetTranscriptURL: URL
    let displayTitle: String?
    let fileManager: FileManager
    let moveItem: (URL, URL) throws -> Void
    let copyItem: (URL, URL) throws -> Void
    let removeItem: (URL) throws -> Void
    let recoveryStoreDirectory: URL?
    let logFailure: (_ event: String, _ context: [String: String]) -> Void

    func execute() throws -> URL {
        let sourceAudioURL = MeetingArtifactRenamer.audioDirectoryURL(for: sourceTranscriptURL)
        let targetAudioURL = MeetingArtifactRenamer.audioDirectoryURL(for: targetTranscriptURL)
        let hadSourceAudio = fileManager.fileExists(atPath: sourceAudioURL.path)
        let recoveryTransaction: MeetingArtifactRecoveryTransaction
        do {
            recoveryTransaction = try MeetingArtifactRecoveryStore.prepare(
                sourceTranscriptURL: sourceTranscriptURL,
                targetTranscriptURL: targetTranscriptURL,
                hadSourceAudio: hadSourceAudio,
                directory: recoveryStoreDirectory,
                fileManager: fileManager
            )
        } catch MeetingArtifactRecoveryStoreError.pending(let notice) {
            throw MeetingArtifactRenameError.recoveryPending(notice)
        } catch {
            logFailure(
                "meeting_artifact_recovery_journal_write_failed",
                ["errorType": "\(type(of: error))"]
            )
            MeetingArtifactRecoveryStore.notifyUnavailable(directory: recoveryStoreDirectory)
            throw error
        }

        if hadSourceAudio {
            do {
                try moveItem(sourceAudioURL, targetAudioURL)
            } catch {
                let audioLocation = restoreAudioToSource(
                    hadSourceAudio: hadSourceAudio,
                    sourceURL: sourceAudioURL,
                    targetURL: targetAudioURL
                )
                logFailure(
                    "meeting_audio_directory_rename_failed",
                    [
                        "sourceExists": "\(fileManager.fileExists(atPath: sourceAudioURL.path))",
                        "targetExists": "\(fileManager.fileExists(atPath: targetAudioURL.path))",
                        "audioLocation": audioLocation.rawValue,
                        "errorType": "\(type(of: error))"
                    ]
                )
                if audioLocation.isRetrySafe {
                    finish(recoveryTransaction)
                }
                throw MeetingArtifactRenameError.audioMoveFailed(
                    audioLocation: audioLocation,
                    targetTranscriptURL: targetTranscriptURL
                )
            }
        }

        do {
            try moveItem(sourceTranscriptURL, targetTranscriptURL)
        } catch {
            if fileManager.fileExists(atPath: targetTranscriptURL.path),
               MeetingArtifactRecoveryStore.transcriptBelongsToTransaction(
                   at: targetTranscriptURL,
                   transaction: recoveryTransaction,
                   fileManager: fileManager
               ),
               !hadSourceAudio || fileManager.fileExists(atPath: targetAudioURL.path) {
                if fileManager.fileExists(atPath: sourceTranscriptURL.path) {
                    do {
                        try removeItem(sourceTranscriptURL)
                    } catch let cleanupError {
                        logFailure(
                            "meeting_transcript_rename_source_cleanup_failed",
                            [
                                "sourceExists": "\(fileManager.fileExists(atPath: sourceTranscriptURL.path))",
                                "targetExists": "true",
                                "errorType": "\(type(of: cleanupError))"
                            ]
                        )
                        throw MeetingArtifactRenameError.recoveryPending(
                            recoveryTransaction.notice
                        )
                    }
                }
                logFailure(
                    "meeting_transcript_rename_reconciled",
                    [
                        "sourceExists": "\(fileManager.fileExists(atPath: sourceTranscriptURL.path))",
                        "targetExists": "true",
                        "errorType": "\(type(of: error))"
                    ]
                )
                finishSuccessfulRename(recoveryTransaction)
                return targetTranscriptURL
            }

            var audioLocation = restoreAudioToSource(
                hadSourceAudio: hadSourceAudio,
                sourceURL: sourceAudioURL,
                targetURL: targetAudioURL
            )

            if audioLocation == .atTarget,
               recoverTranscriptForward(
                   from: sourceTranscriptURL,
                   to: targetTranscriptURL
               ) {
                finishSuccessfulRename(recoveryTransaction)
                return targetTranscriptURL
            }

            audioLocation = resolveAudioLocation(
                hadSourceAudio: hadSourceAudio,
                sourceURL: sourceAudioURL,
                targetURL: targetAudioURL
            )
            logFailure(
                "meeting_transcript_rename_failed",
                [
                    "sourceExists": "\(fileManager.fileExists(atPath: sourceTranscriptURL.path))",
                    "targetExists": "\(fileManager.fileExists(atPath: targetTranscriptURL.path))",
                    "audioLocation": audioLocation.rawValue,
                    "errorType": "\(type(of: error))"
                ]
            )
            if audioLocation.isRetrySafe {
                finish(recoveryTransaction)
            }
            throw MeetingArtifactRenameError.transcriptMoveFailed(
                audioLocation: audioLocation,
                targetTranscriptURL: targetTranscriptURL
            )
        }

        finishSuccessfulRename(recoveryTransaction)
        return targetTranscriptURL
    }

    private func finishSuccessfulRename(_ transaction: MeetingArtifactRecoveryTransaction) {
        MeetingArtifactRenamer.renameSummarySidecarIfNeeded(
            from: sourceTranscriptURL,
            to: targetTranscriptURL,
            displayTitle: displayTitle,
            fileManager: fileManager,
            logFailure: logFailure
        )
        finish(transaction)
    }

    private func finish(_ transaction: MeetingArtifactRecoveryTransaction) {
        MeetingArtifactRecoveryStore.finish(
            transaction,
            directory: recoveryStoreDirectory,
            fileManager: fileManager
        )
    }

    private func restoreAudioToSource(
        hadSourceAudio: Bool,
        sourceURL: URL,
        targetURL: URL
    ) -> MeetingArtifactAudioLocation {
        guard hadSourceAudio else { return .notPresent }
        var restoredByCopy = false

        if !fileManager.fileExists(atPath: sourceURL.path),
           fileManager.fileExists(atPath: targetURL.path) {
            do {
                try moveItem(targetURL, sourceURL)
            } catch let rollbackError {
                logFailure(
                    "meeting_audio_directory_rename_rollback_failed",
                    [
                        "sourceExists": "\(fileManager.fileExists(atPath: sourceURL.path))",
                        "targetExists": "\(fileManager.fileExists(atPath: targetURL.path))",
                        "errorType": "\(type(of: rollbackError))"
                    ]
                )

                if !fileManager.fileExists(atPath: sourceURL.path),
                   fileManager.fileExists(atPath: targetURL.path) {
                    let temporaryRecoveryURL = sourceURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(
                            ".\(sourceURL.lastPathComponent).recovery-\(UUID().uuidString)",
                            isDirectory: true
                        )
                    do {
                        try copyItem(targetURL, temporaryRecoveryURL)
                        guard !fileManager.fileExists(atPath: sourceURL.path) else {
                            try? fileManager.removeItem(at: temporaryRecoveryURL)
                            return resolveAudioLocation(
                                hadSourceAudio: hadSourceAudio,
                                sourceURL: sourceURL,
                                targetURL: targetURL
                            )
                        }
                        try moveItem(temporaryRecoveryURL, sourceURL)
                        restoredByCopy = true
                    } catch let recoveryError {
                        try? fileManager.removeItem(at: temporaryRecoveryURL)
                        logFailure(
                            "meeting_audio_directory_rename_recovery_failed",
                            [
                                "sourceExists": "\(fileManager.fileExists(atPath: sourceURL.path))",
                                "targetExists": "\(fileManager.fileExists(atPath: targetURL.path))",
                                "errorType": "\(type(of: recoveryError))"
                            ]
                        )
                    }
                }
            }
        }

        if restoredByCopy,
           fileManager.fileExists(atPath: sourceURL.path),
           fileManager.fileExists(atPath: targetURL.path) {
            do {
                try removeItem(targetURL)
            } catch let cleanupError {
                logFailure(
                    "meeting_audio_directory_rename_cleanup_failed",
                    [
                        "sourceExists": "true",
                        "targetExists": "\(fileManager.fileExists(atPath: targetURL.path))",
                        "errorType": "\(type(of: cleanupError))"
                    ]
                )
            }
        }

        return resolveAudioLocation(
            hadSourceAudio: hadSourceAudio,
            sourceURL: sourceURL,
            targetURL: targetURL
        )
    }

    private func recoverTranscriptForward(from sourceURL: URL, to targetURL: URL) -> Bool {
        do {
            try copyItem(sourceURL, targetURL)
            fileManager.restrictFileToOwnerOnly(at: targetURL)
        } catch let recoveryError {
            logFailure(
                "meeting_transcript_rename_recovery_failed",
                [
                    "sourceExists": "\(fileManager.fileExists(atPath: sourceURL.path))",
                    "targetExists": "\(fileManager.fileExists(atPath: targetURL.path))",
                    "errorType": "\(type(of: recoveryError))"
                ]
            )
            return false
        }

        if fileManager.fileExists(atPath: sourceURL.path) {
            do {
                try removeItem(sourceURL)
            } catch let cleanupError {
                logFailure(
                    "meeting_transcript_rename_source_cleanup_failed",
                    [
                        "sourceExists": "\(fileManager.fileExists(atPath: sourceURL.path))",
                        "targetExists": "\(fileManager.fileExists(atPath: targetURL.path))",
                        "errorType": "\(type(of: cleanupError))"
                    ]
                )
                return false
            }
        }
        return fileManager.fileExists(atPath: targetURL.path)
    }

    private func resolveAudioLocation(
        hadSourceAudio: Bool,
        sourceURL: URL,
        targetURL: URL
    ) -> MeetingArtifactAudioLocation {
        guard hadSourceAudio else { return .notPresent }
        let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
        let targetExists = fileManager.fileExists(atPath: targetURL.path)
        switch (sourceExists, targetExists) {
        case (true, false): return .atSource
        case (true, true): return .duplicated
        case (false, true): return .atTarget
        case (false, false): return .missing
        }
    }
}
