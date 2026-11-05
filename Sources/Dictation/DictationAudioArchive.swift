// DictationAudioArchive.swift
// Kept dictation audio: one file per take under <capture-library>/dictations/audio/.

import AVFoundation
import Foundation

/// Where a finished take's audio goes when the user keeps dictation audio
/// (Settings → Storage → Keep dictation audio, 30 days by default).
///
/// Each take is `audio/<session-uuid>.m4a` under the dictations folder, or the
/// `.wav` sibling until compression finishes (or if it failed). The day file
/// stores that path relative to the dictations folder, because the capture
/// library can move. Everything that reads or deletes here checks the file is
/// a regular file directly inside the audio folder and named the way we name it.
enum DictationAudioArchive {
    static let folderName = "audio"
    // One mutation owner for pending/archive publication, deletion and pruning.
    // Recursive because these operations call each other's synchronous helpers.
    private static let mutationLock = NSRecursiveLock()
    static func lockStorageMutation() { mutationLock.lock() }
    static func unlockStorageMutation() { mutationLock.unlock() }

    /// `<dictations>/audio/`
    static func audioFolder(in dictationsFolder: URL) -> URL {
        dictationsFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    /// `audio/<uuid>.m4a`: the path a saved take records in its day file.
    static func relativePath(for sessionID: UUID) -> String {
        "\(folderName)/\(sessionID.uuidString.lowercased()).m4a"
    }

    /// The path to record for this take, or nil when no audio will be kept:
    /// the setting is off, there's no checkpoint, or its WAV is gone.
    static func plannedRelativePath(
        for recovery: DictationStoppedAudioRecovery?,
        window: DictationAudioKeepWindow,
        fileManager: FileManager = .default
    ) -> String? {
        guard window.keepsAudio,
              let recovery,
              fileManager.fileExists(atPath: recovery.url.path) else { return nil }
        return relativePath(for: recovery.sessionID)
    }

    // MARK: - Keep

    /// Moves a saved take's recovery WAV into the audio folder as
    /// `<uuid>.wav` and removes its recovery metadata, so recovery lookups
    /// (the importer, the launch purge) no longer find it. Returns the kept WAV, or nil when nothing moved
    /// (the recovery copy is left alone in that case).
    @discardableResult
    static func keep(
        recovery: DictationStoppedAudioRecovery,
        relativePath: String,
        dictationsFolder: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        lockStorageMutation()
        defer { unlockStorageMutation() }
        let folder = dictationsFolder ?? DictationStoragePaths.transcriptsFolder
        guard let stem = takeStem(fromRelativePath: relativePath) else { return nil }
        let audioFolder = audioFolder(in: folder)
        let destination = audioFolder.appendingPathComponent("\(stem).wav", isDirectory: false)
        let staged = audioFolder.appendingPathComponent(".\(stem).keep-\(UUID().uuidString.lowercased()).wav")
        defer { try? fileManager.removeItem(at: staged) }
        do {
            if fileManager.fileExists(atPath: audioFolder.path), !isPlainDirectory(audioFolder, fileManager: fileManager) { return nil }
            try fileManager.createPrivateDirectory(at: audioFolder)
            guard isPlainDirectory(audioFolder, fileManager: fileManager) else { return nil }
            if fileManager.fileExists(atPath: destination.path) {
                // A restarted retry may see a completed copy, but its name is
                // not proof. Never replace a different file or a symlink.
                guard isRegularFile(destination, fileManager: fileManager),
                      fileManager.contentsEqual(atPath: recovery.url.path, andPath: destination.path) else { return nil }
                try DictationStoppedAudioRecoveryStore.synchronizeFileAndDirectory(destination)
                try fileManager.removeItem(at: recovery.url)
                DictationStoppedAudioRecoveryStore.removeMetadata(forAudioURL: recovery.url, fileManager: fileManager)
                return destination
            }
            // Stage a copy even on the same volume. A rename alone would
            // retire the checkpoint before the destination's durability fence.
            try fileManager.copyItem(at: recovery.url, to: staged)
            fileManager.restrictFileToOwnerOnly(at: staged)
            try DictationStoppedAudioRecoveryStore.synchronizeFileAndDirectory(staged)
            guard fileManager.contentsEqual(atPath: recovery.url.path, andPath: staged.path) else { return nil }
            try fileManager.moveItem(at: staged, to: destination)
            // A nested injected operation may deliberately discard the take
            // while publishing. Never leave our staged copy resurrected.
            guard isRegularFile(recovery.url, fileManager: fileManager) else {
                try? fileManager.removeItem(at: destination)
                return nil
            }
            fileManager.restrictFileToOwnerOnly(at: destination)
            try DictationStoppedAudioRecoveryStore.synchronizeFileAndDirectory(destination)
            try fileManager.removeItem(at: recovery.url)
        } catch {
            return nil
        }
        DictationStoppedAudioRecoveryStore.removeMetadata(forAudioURL: recovery.url, fileManager: fileManager)
        return destination
    }

    // MARK: - Compress

    /// Starts compressing a kept WAV off the main actor. The save result never
    /// waits on this; the WAV stays playable until the M4A is in place.
    static func compressInBackground(_ wavURL: URL) {
        Task.detached(priority: .background) {
            _ = await compress(wavURL)
        }
    }

    /// Compresses `<uuid>.wav` into `<uuid>.m4a` next to it: export to a hidden
    /// temp name, check the result, move it into place, then delete the WAV.
    /// Any failure keeps the WAV and removes the temp file. Returns true when
    /// the M4A replaced the WAV.
    static func compress(
        _ wavURL: URL,
        fileManager: FileManager = .default,
        convert: @Sendable (URL, URL) async throws -> Void = exportM4A,
        isUsable: @Sendable (URL, URL) -> Bool = isCompleteReplacement
    ) async -> Bool {
        let audioFolder = wavURL.deletingLastPathComponent()
        let stem = wavURL.deletingPathExtension().lastPathComponent
        guard wavURL.pathExtension == "wav",
              UUID(uuidString: stem) != nil,
              isRegularFile(wavURL, fileManager: fileManager) else { return false }
        let destination = audioFolder.appendingPathComponent("\(stem).m4a", isDirectory: false)
        let temp = audioFolder.appendingPathComponent(
            ".\(stem).\(tempMarker)\(UUID().uuidString.lowercased()).m4a",
            isDirectory: false
        )
        do {
            try await convert(wavURL, temp)
            return try publishCompression(temp: temp, source: wavURL, destination: destination,
                                          fileManager: fileManager, isUsable: isUsable)
        } catch {
            try? fileManager.removeItem(at: temp)
            return false
        }
    }

    private static func publishCompression(
        temp: URL, source: URL, destination: URL, fileManager: FileManager,
        isUsable: (URL, URL) -> Bool
    ) throws -> Bool {
        lockStorageMutation()
        defer { unlockStorageMutation(); try? fileManager.removeItem(at: temp) }
        // Conversion can await while Off or Delete runs. Missing source means
        // its owner deliberately retired it; never publish the converted copy.
        guard isRegularFile(source, fileManager: fileManager),
              isRegularFile(temp, fileManager: fileManager), fileSize(temp) > 0,
              isUsable(temp, source) else { return false }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temp, to: destination)
        fileManager.restrictFileToOwnerOnly(at: destination)
        try DictationStoppedAudioRecoveryStore.synchronizeFileAndDirectory(destination)
        try? fileManager.removeItem(at: source)
        return true
    }

    @Sendable
    static func exportM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.shouldOptimizeForNetworkUse = false
        try await session.export(to: destination, as: .m4a)
    }

    /// The M4A decodes and runs as long as the WAV (give or take AAC padding).
    @Sendable
    static func isCompleteReplacement(_ candidate: URL, for source: URL) -> Bool {
        guard let original = try? AVAudioFile(forReading: source),
              let replacement = try? AVAudioFile(forReading: candidate),
              original.length > 0, replacement.length > 0,
              original.processingFormat.sampleRate > 0,
              replacement.processingFormat.sampleRate > 0 else { return false }
        let originalSeconds = Double(original.length) / original.processingFormat.sampleRate
        let replacementSeconds = Double(replacement.length) / replacement.processingFormat.sampleRate
        let tolerance = max(0.05, 2_048 / replacement.processingFormat.sampleRate)
        return abs(originalSeconds - replacementSeconds) <= tolerance
    }

    // MARK: - Resolve

    /// The kept file for a day-file `Audio:` path: the M4A if it's there, else
    /// the WAV sibling, else nil (aged out, never kept, or not ours). Paths
    /// that leave the audio folder, symlinks, and odd names resolve to nil.
    static func resolveURL(
        relativePath: String,
        dictationsFolder: URL? = nil,
        recoveryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let folder = dictationsFolder ?? DictationStoragePaths.transcriptsFolder
        guard let stem = takeStem(fromRelativePath: relativePath) else { return nil }
        let audioFolder = audioFolder(in: folder)
        for ext in ["m4a", "wav"] where isPlainDirectory(audioFolder, fileManager: fileManager) {
            let candidate = audioFolder.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
            if isRegularFile(candidate, fileManager: fileManager) {
                return candidate
            }
        }
        guard let recoveryDirectory else { return nil }
        return DictationStoppedAudioRecoveryStore.pendingAudioURL(
            relativePath: relativePath, dictationsFolder: folder,
            directory: recoveryDirectory, fileManager: fileManager
        )
    }

    // MARK: - Delete

    /// Deletes one take's kept audio (M4A and WAV) when its dictation is
    /// deleted for good. `dictationsFolder` is the folder holding the entry's
    /// day file. Returns how many files it removed.
    @discardableResult
    static func deleteKeptAudio(
        relativePath: String,
        dictationsFolder: URL,
        recoveryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int {
        lockStorageMutation()
        defer { unlockStorageMutation() }
        guard let stem = takeStem(fromRelativePath: relativePath) else { return 0 }
        let audioFolder = audioFolder(in: dictationsFolder)
        // A pending archive belongs to this entry too. Erase it before a
        // later launch can retry and resurrect a deliberately deleted take.
        var removed = recoveryDirectory.map {
            DictationStoppedAudioRecoveryStore.deletePendingAudio(
                relativePath: relativePath, dictationsFolder: dictationsFolder,
                directory: $0, fileManager: fileManager
            ) ? 1 : 0
        } ?? 0
        guard isPlainDirectory(audioFolder, fileManager: fileManager) else { return removed }
        for ext in ["m4a", "wav"] {
            let url = audioFolder.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
            if isRegularFile(url, fileManager: fileManager), (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Deletes a deleted dictation entry's kept audio, if it had any. The
    /// audio sits next to the entry's day file, in `audio/`.
    @discardableResult
    static func deleteKeptAudio(
        for entry: SavedDictationEntry,
        recoveryDirectory: URL = DictationStoppedAudioRecoveryStore.defaultDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        lockStorageMutation()
        defer { unlockStorageMutation() }
        guard let audioRelativePath = entry.audioRelativePath else { return 0 }
        return deleteKeptAudio(
            relativePath: audioRelativePath,
            dictationsFolder: entry.url.deletingLastPathComponent(),
            recoveryDirectory: recoveryDirectory,
            fileManager: fileManager
        )
    }

    // MARK: - Prune

    /// Deletes kept audio older than the window: everything for `off`,
    /// nothing for `forever`. Only touches regular files directly in the audio
    /// folder that carry our names; never follows symlinks. Returns how many
    /// files it removed.
    @discardableResult
    static func prune(
        window: DictationAudioKeepWindow,
        now: Date = Date(),
        dictationsFolder: URL? = nil,
        fileManager: FileManager = .default,
        currentKeepWindow: (() -> DictationAudioKeepWindow)? = nil
    ) -> Int {
        lockStorageMutation()
        defer { unlockStorageMutation() }
        // This front door already runs at launch and after a retention change.
        // Custom-library fixtures do not read the real recovery directory.
        let policy = currentKeepWindow ?? {
            dictationsFolder == nil ? AudioStoragePreferences.dictationAudioKeepWindow() : window
        }
        let initialWindow = policy()
        var pendingRemoved = 0
        if dictationsFolder == nil {
            DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(
                window: initialWindow, currentKeepWindow: policy,
                now: now, fileManager: fileManager,
                onDiscard: { _ in pendingRemoved += 1 }
            )
        }
        guard initialWindow.days != nil else { return pendingRemoved }
        let folder = dictationsFolder ?? DictationStoragePaths.transcriptsFolder
        let audioFolder = audioFolder(in: folder)
        guard isPlainDirectory(audioFolder, fileManager: fileManager),
              let names = try? fileManager.contentsOfDirectory(atPath: audioFolder.path) else { return pendingRemoved }
        var removed = pendingRemoved
        for name in names where isOurFileName(name) {
            let url = audioFolder.appendingPathComponent(name, isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let date = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
            // Production maintenance follows the current setting, including
            // a relaxation made while this directory was being inventoried.
            // An explicit custom-folder window remains fixed unless injected.
            guard let days = policy().days else { continue }
            let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
            guard days == 0 || (date.map { $0 < cutoff } ?? false) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Names

    private static let tempMarker = "compress-"

    /// The `<uuid>` of `audio/<uuid>.m4a|.wav`, lowercased, or nil for any
    /// other shape (absolute, `..`, nested, hidden, not a UUID).
    static func takeStem(fromRelativePath relativePath: String) -> String? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == folderName else { return nil }
        let filename = String(parts[1])
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        guard ext == "m4a" || ext == "wav",
              UUID(uuidString: stem) != nil else { return nil }
        return stem.lowercased()
    }

    /// `<uuid>.m4a`, `<uuid>.wav`, or our hidden compression temp file.
    static func isOurFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        if ext == "m4a" || ext == "wav", UUID(uuidString: stem) != nil {
            return true
        }
        guard ext == "m4a", stem.hasPrefix(".") else { return false }
        let parts = stem.dropFirst().components(separatedBy: ".\(tempMarker)")
        return parts.count == 2
            && UUID(uuidString: parts[0]) != nil
            && UUID(uuidString: parts[1]) != nil
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        // attributesOfItem does not follow a final symlink, so a link reads as
        // .typeSymbolicLink and is rejected here.
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    private static func isPlainDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}
