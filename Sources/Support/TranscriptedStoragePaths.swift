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
            return URL(fileURLWithPath: customPath, isDirectory: true).standardizedFileURL
        }

        return fileManager.transcriptedDefaultCaptureLibraryDir
    }

    static func setCaptureLibraryURL(_ url: URL?, userDefaults: UserDefaults = .standard) {
        if let url {
            userDefaults.set(url.standardizedFileURL.path, forKey: captureLibraryLocationKey)
        } else {
            userDefaults.removeObject(forKey: captureLibraryLocationKey)
        }
    }
}

extension FileManager {
    private var userApplicationSupportDir: URL {
        urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// App-owned Transcripted root.
    var transcriptedAppSupportDir: URL {
        let url = userApplicationSupportDir.appendingPathComponent("Transcripted", isDirectory: true)
        try? createPrivateDirectory(at: url)
        try? createPrivateDirectory(at: url.appendingPathComponent("captures", isDirectory: true))
        try? createPrivateDirectory(at: url.appendingPathComponent("captures/meetings", isDirectory: true))
        try? createPrivateDirectory(at: url.appendingPathComponent("captures/dictations", isDirectory: true))
        try? createPrivateDirectory(at: url.appendingPathComponent("state", isDirectory: true))
        try? createPrivateDirectory(at: url.appendingPathComponent("cache", isDirectory: true))
        try? createPrivateDirectory(at: url.appendingPathComponent("logs", isDirectory: true))
        try? createPrivateDirectory(at: url.appendingPathComponent("tmp", isDirectory: true))
        try? createPrivateDirectory(at: url.appendingPathComponent("tmp/recordings", isDirectory: true))
        return url
    }

    /// Historic Draft compatibility root, retained only for migration / cleanup flows.
    var draftAppSupportDir: URL {
        userApplicationSupportDir.appendingPathComponent("Draft", isDirectory: true)
    }

    var transcriptedDefaultCaptureLibraryDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("captures", isDirectory: true)
    }

    var transcriptedCaptureLibraryDir: URL {
        let url = TranscriptedStoragePreferences.captureLibraryURL(fileManager: self)
        try? createPrivateDirectory(at: url)
        return url
    }

    var transcriptedStateDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("state", isDirectory: true)
    }

    var transcriptedCacheDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("cache", isDirectory: true)
    }

    var transcriptedLogsDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("logs", isDirectory: true)
    }

    var transcriptedTemporaryDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("tmp", isDirectory: true)
    }

    var transcriptedRecordingsDir: URL {
        transcriptedTemporaryDir.appendingPathComponent("recordings", isDirectory: true)
    }

    /// <capture-library>/meetings/
    var meetingSupportDir: URL {
        let url = transcriptedCaptureLibraryDir.appendingPathComponent("meetings", isDirectory: true)
        try? createPrivateDirectory(at: url)
        return url
    }

    /// <capture-library>/dictations/
    var dictationSupportDir: URL {
        let url = transcriptedCaptureLibraryDir.appendingPathComponent("dictations", isDirectory: true)
        try? createPrivateDirectory(at: url)
        return url
    }

    /// Create a directory and tighten it to owner-only access (0700).
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
        try? setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Tighten a file to owner-only access (0600).
    func restrictFileToOwnerOnly(at url: URL) {
        try? setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
