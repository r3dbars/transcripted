import Foundation

// MARK: - Audio reference reconciliation and path safety
//
// Moved unchanged out of FailedTranscriptionManager.swift: healing an entry's
// audio references against disk state, and the allowed-root containment checks.

extension FailedTranscriptionManager {

    /// Repairs an entry whose audio references no longer match the disk state.
    /// Returns the healed entry, or nil when nothing needed healing.
    typealias AudioReconciliation = (
        entry: FailedTranscription?,
        didHeal: Bool,
        hasUnavailableAudio: Bool
    )

    func reconcileAudioReferences(of entry: FailedTranscription) -> AudioReconciliation {
        let fileManager = FileManager.default
        var micURL = entry.micAudioURL
        var systemURL = entry.systemAudioURL
        var didHeal = false
        var hasUnavailableAudio = false

        // A merge that completed after the entry was written deletes the
        // pre-merge segments and leaves `<stem>_merged.wav` in their place.
        if !fileManager.fileExists(atPath: micURL.path) {
            if let mergedCandidate = mergedSibling(for: micURL),
               fileManager.fileExists(atPath: mergedCandidate.path),
               isSafeAudioURL(mergedCandidate) {
                micURL = mergedCandidate
                didHeal = true
                AppLogger.pipeline.info("Healed failed transcription mic audio to merged file", [
                    "id": entry.id.uuidString,
                    "file": mergedCandidate.lastPathComponent
                ])
            } else if !isContainingAudioRootReachable(for: micURL) {
                hasUnavailableAudio = true
            }
        }

        // Keep the meeting retryable with mic audio only rather than dropping
        // it because the system-audio file went missing.
        if let existingSystemURL = systemURL,
           !fileManager.fileExists(atPath: existingSystemURL.path) {
            if !isContainingAudioRootReachable(for: existingSystemURL) {
                hasUnavailableAudio = true
            } else if fileManager.fileExists(atPath: micURL.path) {
                systemURL = nil
                didHeal = true
                AppLogger.pipeline.warning("Dropped missing system audio reference from failed transcription", [
                    "id": entry.id.uuidString,
                    "file": existingSystemURL.lastPathComponent
                ])
            }
        }

        if hasUnavailableAudio {
            // Return the already-healed micURL/systemURL (e.g. a merge-heal that
            // repointed micURL to `<stem>_merged.wav`) rather than the stale
            // original `entry`, so a later retry doesn't see a no-longer-existing
            // audio path and wrongly delete a recoverable entry. `hasUnavailableAudio`
            // still tells the caller not to persist this reconciliation to disk.
            guard didHeal else { return (entry, false, true) }
            var healed = entry
            healed.micAudioURL = micURL
            healed.systemAudioURL = systemURL
            return (healed, true, true)
        }

        // Audio preserved during a quit that interrupted finalization can have
        // an unpatched WAV header, which reads back as zero-length and makes
        // every retry fail. Nothing else re-runs finalization after relaunch.
        if fileManager.fileExists(atPath: micURL.path) {
            repairWAVHeaderIfNeeded(at: micURL, entryId: entry.id)
        }
        if let systemURL, fileManager.fileExists(atPath: systemURL.path) {
            repairWAVHeaderIfNeeded(at: systemURL, entryId: entry.id)
        }

        let micExists = fileManager.fileExists(atPath: micURL.path)
        let systemExists = systemURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        // Coordinator-preserved imports are placeholder mic + real system.
        // A missing counterpart must not hide the surviving file.
        if !micExists && !systemExists {
            AppLogger.pipeline.error("Dropping failed transcription entry with missing audio", [
                "id": entry.id.uuidString,
                "micFile": micURL.lastPathComponent,
                "systemFile": systemURL?.lastPathComponent ?? "none"
            ])
            return (nil, didHeal, false)
        }
        // A surviving placeholder with no system track is not audio: it can
        // only ever transcribe to silence, and `audioFilesExist()` already
        // hides Retry for it. Drop the row here so it does not sit in the
        // list as "audio missing" until the user clears it by hand.
        if !systemExists, FailedTranscription.isMicrophonePlaceholder(micURL) {
            AppLogger.pipeline.warning("Dropping failed transcription entry whose only audio is the mic placeholder", [
                "id": entry.id.uuidString,
                "micFile": micURL.lastPathComponent,
                "systemFile": systemURL?.lastPathComponent ?? "none"
            ])
            return (nil, didHeal, false)
        }
        if !micExists, systemExists {
            AppLogger.pipeline.warning("Kept failed transcription with missing microphone audio because system audio survived", [
                "id": entry.id.uuidString,
                "micFile": micURL.lastPathComponent,
                "systemFile": systemURL?.lastPathComponent ?? "none"
            ])
        }

        guard didHeal else { return (entry, false, false) }
        var healed = entry
        healed.micAudioURL = micURL
        healed.systemAudioURL = systemURL
        return (healed, true, false)
    }

    func healRelocatedAudioReferences(of entry: FailedTranscription) -> (entry: FailedTranscription, didHeal: Bool) {
        var micURL = entry.micAudioURL
        var systemURL = entry.systemAudioURL
        var didHeal = false

        if !isSafeAudioURL(micURL),
           let relocatedMicURL = relocatedAudioURL(for: micURL),
           FileManager.default.fileExists(atPath: relocatedMicURL.path),
           isSafeAudioURL(relocatedMicURL) {
            micURL = relocatedMicURL
            didHeal = true
        }

        if let existingSystemURL = systemURL,
           !isSafeAudioURL(existingSystemURL),
           let relocatedSystemURL = relocatedAudioURL(for: existingSystemURL),
           FileManager.default.fileExists(atPath: relocatedSystemURL.path),
           isSafeAudioURL(relocatedSystemURL) {
            systemURL = relocatedSystemURL
            didHeal = true
        } else if let existingSystemURL = systemURL,
                  !isSafeAudioURL(existingSystemURL),
                  let relocatedSystemURL = relocatedAudioURL(for: existingSystemURL),
                  isSafeAudioURL(relocatedSystemURL),
                  isSafeAudioURL(micURL),
                  FileManager.default.fileExists(atPath: micURL.path),
                  !FailedTranscription.isMicrophonePlaceholder(micURL) {
            // The mic was copied into the active library but the optional
            // system track was not. Keep the retryable mic row active instead
            // of hiding it indefinitely behind an inaccessible old reference.
            // Not when the copied "mic" is the silent placeholder: then the
            // uncopied system track is the only real audio, and dropping its
            // reference would strand it for good.
            systemURL = nil
            didHeal = true
            AppLogger.pipeline.warning("Dropped uncopied system audio reference after partial library relocation", [
                "id": entry.id.uuidString,
                "file": existingSystemURL.lastPathComponent
            ])
        }

        // A placeholder is not audio. If the real system track did not make
        // it into the active library, healing the placeholder alone would
        // split the row across two libraries: hidden here (system outside
        // the roots) and hidden again once the old library is active
        // (placeholder now outside). Keep both references together in the
        // old library, where the row is whole and retryable.
        if FailedTranscription.isMicrophonePlaceholder(entry.micAudioURL),
           let systemURL, !isSafeAudioURL(systemURL) {
            micURL = entry.micAudioURL
            didHeal = false
        }
        guard didHeal else { return (entry, false) }
        AppLogger.pipeline.info("Healed failed transcription audio paths after capture library relocation", [
            "id": entry.id.uuidString
        ])
        var healed = entry
        healed.micAudioURL = micURL
        healed.systemAudioURL = systemURL
        return (healed, true)
    }

    private func relocatedAudioURL(for url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasSuffix("_audio") else { return nil }
        return audioArchiveRoot
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
    }

    private func mergedSibling(for url: URL) -> URL? {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_merged.wav")
    }

    private func isContainingAudioRootReachable(for url: URL) -> Bool {
        guard let root = allowedAudioRoots.first(where: { Self.isFile(url, containedIn: $0) }) else {
            return true
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func areReferencedManagedAudioRootsReachable(for failed: FailedTranscription) -> Bool {
        [failed.micAudioURL, failed.systemAudioURL]
            .compactMap { $0 }
            .filter(isSafeAudioURL)
            .allSatisfy(isContainingAudioRootReachable)
    }

    private func repairWAVHeaderIfNeeded(at url: URL, entryId: UUID) {
        guard url.pathExtension.lowercased() == "wav",
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            if try WAVHeaderRepair.repairIfNeeded(at: url) {
                AppLogger.pipeline.info("Repaired unfinalized WAV header for failed transcription audio", [
                    "id": entryId.uuidString,
                    "file": url.lastPathComponent
                ])
            }
        } catch {
            AppLogger.pipeline.warning("Could not inspect failed transcription WAV header", [
                "id": entryId.uuidString,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    func isSafeAudioURL(_ url: URL) -> Bool {
        let canonicalURL = Self.canonicalFileURL(url)
        return allowedAudioRoots.contains { root in
            Self.isFile(canonicalURL, containedIn: root)
        }
    }

    static func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func canonicalDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let filePath = canonicalFileURL(fileURL).path
        let directoryPath = canonicalDirectoryURL(directoryURL).path
        let normalizedDirectoryPath = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath == directoryPath || filePath.hasPrefix(normalizedDirectoryPath)
    }
}
