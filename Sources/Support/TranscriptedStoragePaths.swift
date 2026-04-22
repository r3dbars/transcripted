// TranscriptedStoragePaths.swift
// Shared storage layout helpers for Transcripted.

import Foundation

enum TranscriptedStoragePreferences {
    static let captureLibraryLocationKey = "transcriptSaveLocation"

    static func captureLibraryURL(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        if let customPath = userDefaults.string(forKey: captureLibraryLocationKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty {
            let candidate = URL(fileURLWithPath: customPath, isDirectory: true).standardizedFileURL
            // Security: reject tampered preferences that redirect captures outside the
            // app-managed Library root or the legacy ~/Documents/Transcripted tree.
            if isAllowedCaptureLibraryURL(candidate, fileManager: fileManager) {
                return candidate
            }
        }

        return fileManager.transcriptedDefaultCaptureLibraryDir
    }

    static func setCaptureLibraryURL(
        _ url: URL?,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        if let url {
            let candidate = url.standardizedFileURL
            // Security: only persist capture-library locations that stay inside the
            // approved Transcripted roots, so UI selection cannot redirect writes to
            // arbitrary folders elsewhere on disk.
            guard isAllowedCaptureLibraryURL(candidate, fileManager: fileManager) else {
                userDefaults.removeObject(forKey: captureLibraryLocationKey)
                return
            }
            userDefaults.set(candidate.path, forKey: captureLibraryLocationKey)
        } else {
            userDefaults.removeObject(forKey: captureLibraryLocationKey)
        }
    }

    static func isAllowedCaptureLibraryURL(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let documentsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let libraryRoot = fileManager.transcriptedDefaultCaptureLibraryDir
            .standardizedFileURL
            .resolvingSymlinksInPath()

        return candidate == documentsRoot
            || candidate.isDescendant(of: documentsRoot)
            || candidate == libraryRoot
            || candidate.isDescendant(of: libraryRoot)
    }
}

private extension URL {
    func isDescendant(of directory: URL) -> Bool {
        let candidatePath = standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return candidatePath.hasPrefix(directoryPath + "/")
    }
}

extension FileManager {
    private var userApplicationSupportDir: URL {
        urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    var transcriptedAppSupportRootURL: URL {
        userApplicationSupportDir.appendingPathComponent("Transcripted", isDirectory: true)
    }

    var transcriptedLogsDirURL: URL {
        transcriptedAppSupportRootURL.appendingPathComponent("logs", isDirectory: true)
    }

    private func logDirectoryCreationFailure(context: String, url: URL, error: Error) {
        fputs("⚠️ STORAGE | failed to create \(context) at \(url.path): \(error.localizedDescription)\n", stderr)
    }

    private func ensuredPrivateDirectory(at url: URL, context: String) -> URL {
        ensurePrivateDirectory(at: url, context: context)
        return url
    }

    private func setPOSIXPermissionsIfNeeded(_ permissions: NSNumber, ofItemAtPath path: String) {
        guard fileExists(atPath: path) else { return }

        if let attributes = try? attributesOfItem(atPath: path),
           let currentPermissions = attributes[.posixPermissions] as? NSNumber,
           currentPermissions == permissions {
            return
        }

        try? setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }

    func ensurePrivateDirectory(at url: URL, context: String) {
        do {
            try createPrivateDirectory(at: url)
        } catch {
            logDirectoryCreationFailure(context: context, url: url, error: error)
        }
    }

    /// App-owned Transcripted root.
    var transcriptedAppSupportDir: URL {
        ensuredPrivateDirectory(at: transcriptedAppSupportRootURL, context: "Transcripted app support root")
    }

    /// Historic Draft compatibility root, retained only for migration / cleanup flows.
    var draftAppSupportDir: URL {
        userApplicationSupportDir.appendingPathComponent("Draft", isDirectory: true)
    }

    var transcriptedDefaultCaptureLibraryDir: URL {
        let url = transcriptedAppSupportDir.appendingPathComponent("captures", isDirectory: true)
        return ensuredPrivateDirectory(at: url, context: "Transcripted capture library parent")
    }

    var transcriptedCaptureLibraryDir: URL {
        let url = TranscriptedStoragePreferences.captureLibraryURL(fileManager: self)
        return ensuredPrivateDirectory(at: url, context: "Transcripted capture library")
    }

    var transcriptedStateDir: URL {
        let url = transcriptedAppSupportDir.appendingPathComponent("state", isDirectory: true)
        return ensuredPrivateDirectory(at: url, context: "Transcripted state")
    }

    var transcriptedCacheDir: URL {
        let url = transcriptedAppSupportDir.appendingPathComponent("cache", isDirectory: true)
        return ensuredPrivateDirectory(at: url, context: "Transcripted cache")
    }

    var transcriptedWhisperModelsDir: URL {
        let url = transcriptedCacheDir.appendingPathComponent("whisperkit", isDirectory: true)
        return ensuredPrivateDirectory(at: url, context: "Transcripted Whisper models")
    }

    var transcriptedLogsDir: URL {
        ensuredPrivateDirectory(at: transcriptedLogsDirURL, context: "Transcripted logs")
    }

    var transcriptedTemporaryDir: URL {
        let url = transcriptedAppSupportDir.appendingPathComponent("tmp", isDirectory: true)
        return ensuredPrivateDirectory(at: url, context: "Transcripted tmp")
    }

    var transcriptedRecordingsDir: URL {
        let url = transcriptedTemporaryDir.appendingPathComponent("recordings", isDirectory: true)
        return ensuredPrivateDirectory(at: url, context: "Transcripted temporary recordings")
    }

    /// <capture-library>/meetings/
    var meetingSupportDir: URL {
        transcriptedCaptureLibrarySubdirectory("meetings")
    }

    /// <capture-library>/dictations/
    var dictationSupportDir: URL {
        transcriptedCaptureLibrarySubdirectory("dictations")
    }

    private func transcriptedCaptureLibrarySubdirectory(_ name: String) -> URL {
        let url = transcriptedCaptureLibraryDir.appendingPathComponent(name, isDirectory: true)
        return ensuredPrivateDirectory(at: url, context: "Transcripted \(name) folder")
    }

    /// Create a directory and tighten it to owner-only access (0700).
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
        setPOSIXPermissionsIfNeeded(NSNumber(value: 0o700), ofItemAtPath: url.path)
    }

    /// Tighten a file to owner-only access (0600).
    func restrictFileToOwnerOnly(at url: URL) {
        setPOSIXPermissionsIfNeeded(NSNumber(value: 0o600), ofItemAtPath: url.path)
    }
}
