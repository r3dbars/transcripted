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
            let candidate = URL(fileURLWithPath: customPath, isDirectory: true)
            // Security: reject tampered preferences that target traversal or system
            // roots while preserving the user's ability to choose their own library.
            if isSafeCaptureLibraryURL(candidate) {
                return candidate.standardizedFileURL
            }
        }

        return fileManager.transcriptedDefaultCaptureLibraryDir
    }

    static func setCaptureLibraryURL(
        _ url: URL?,
        userDefaults: UserDefaults = .standard
    ) {
        if let url {
            // Security: keep unsafe roots out of preferences while preserving custom
            // capture-library locations chosen in Settings.
            guard isSafeCaptureLibraryURL(url) else {
                userDefaults.removeObject(forKey: captureLibraryLocationKey)
                return
            }
            let candidate = url.standardizedFileURL
            userDefaults.set(candidate.path, forKey: captureLibraryLocationKey)
        } else {
            userDefaults.removeObject(forKey: captureLibraryLocationKey)
        }
    }

    static func isSafeCaptureLibraryURL(_ url: URL) -> Bool {
        // Security: reject relative paths from tampered preferences so Transcripted
        // never resolves a capture library against the process working directory.
        guard url.isFileURL, url.path.hasPrefix("/") else {
            return false
        }

        if url.pathComponents.contains("..") {
            return false
        }

        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let forbiddenPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]
        return !forbiddenPrefixes.contains { prefix in
            candidate.path == prefix || candidate.path.hasPrefix(prefix + "/")
        }
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
