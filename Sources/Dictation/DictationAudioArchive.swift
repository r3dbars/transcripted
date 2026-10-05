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
    /// `<uuid>.wav` and removes its recovery metadata, so the launch reminder
    /// no longer offers it. Returns the kept WAV, or nil when nothing moved
    /// (the recovery copy is left alone in that case).
    @discardableResult
    static func keep(
        recovery: DictationStoppedAudioRecovery,
        relativePath: String,
        dictationsFolder: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let folder = dictationsFolder ?? DictationStoragePaths.transcriptsFolder
        guard let stem = takeStem(fromRelativePath: relativePath) else { return nil }
        let audioFolder = audioFolder(in: folder)
        let destination = audioFolder.appendingPathComponent("\(stem).wav", isDirectory: false)
        do {
            try fileManager.createPrivateDirectory(at: audioFolder)
            guard isPlainDirectory(audioFolder, fileManager: fileManager) else { return nil }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            do {
                try fileManager.moveItem(at: recovery.url, to: destination)
            } catch {
                // Another volume (a relocated library on an external disk):
                // copy, then drop the original only once the copy is in place.
                try fileManager.copyItem(at: recovery.url, to: destination)
                try? fileManager.removeItem(at: recovery.url)
            }
            fileManager.restrictFileToOwnerOnly(at: destination)
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
            guard isRegularFile(temp, fileManager: fileManager),
                  fileSize(temp) > 0,
                  isUsable(temp, wavURL) else {
                try? fileManager.removeItem(at: temp)
                return false
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temp, to: destination)
            fileManager.restrictFileToOwnerOnly(at: destination)
        } catch {
            try? fileManager.removeItem(at: temp)
            return false
        }
        try? fileManager.removeItem(at: wavURL)
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
        fileManager: FileManager = .default
    ) -> URL? {
        let folder = dictationsFolder ?? DictationStoragePaths.transcriptsFolder
        guard let stem = takeStem(fromRelativePath: relativePath) else { return nil }
        let audioFolder = audioFolder(in: folder)
        guard isPlainDirectory(audioFolder, fileManager: fileManager) else { return nil }
        for ext in ["m4a", "wav"] {
            let candidate = audioFolder.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
            if isRegularFile(candidate, fileManager: fileManager) {
                return candidate
            }
        }
        return nil
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
        fileManager: FileManager = .default
    ) -> Int {
        guard let days = window.days else { return 0 }
        let folder = dictationsFolder ?? DictationStoragePaths.transcriptsFolder
        let audioFolder = audioFolder(in: folder)
        guard isPlainDirectory(audioFolder, fileManager: fileManager),
              let names = try? fileManager.contentsOfDirectory(atPath: audioFolder.path) else { return 0 }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        var removed = 0
        for name in names where isOurFileName(name) {
            let url = audioFolder.appendingPathComponent(name, isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let date = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
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
