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

    private func logDirectoryCreationFailure(context: String, url: URL, error: Error) {
        fputs("⚠️ STORAGE | failed to create \(context) at \(url.path): \(error.localizedDescription)\n", stderr)
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
        let url = userApplicationSupportDir.appendingPathComponent("Transcripted", isDirectory: true)
        let captures = url.appendingPathComponent("captures", isDirectory: true)
        let meetings = captures.appendingPathComponent("meetings", isDirectory: true)
        let dictations = captures.appendingPathComponent("dictations", isDirectory: true)
        let state = url.appendingPathComponent("state", isDirectory: true)
        let cache = url.appendingPathComponent("cache", isDirectory: true)
        let logs = url.appendingPathComponent("logs", isDirectory: true)
        let tmp = url.appendingPathComponent("tmp", isDirectory: true)
        let recordings = tmp.appendingPathComponent("recordings", isDirectory: true)

        let directories: [(URL, String)] = [
            (url, "Transcripted app support root"),
            (captures, "Transcripted capture library parent"),
            (meetings, "Transcripted meeting captures"),
            (dictations, "Transcripted dictation captures"),
            (state, "Transcripted state"),
            (cache, "Transcripted cache"),
            (logs, "Transcripted logs"),
            (tmp, "Transcripted tmp"),
            (recordings, "Transcripted temporary recordings"),
        ]

        for (directory, context) in directories {
            ensurePrivateDirectory(at: directory, context: context)
        }
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
        ensurePrivateDirectory(at: url, context: "Transcripted capture library")
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
        transcriptedCaptureLibrarySubdirectory("meetings")
    }

    /// <capture-library>/dictations/
    var dictationSupportDir: URL {
        transcriptedCaptureLibrarySubdirectory("dictations")
    }

    private func transcriptedCaptureLibrarySubdirectory(_ name: String) -> URL {
        let url = transcriptedCaptureLibraryDir.appendingPathComponent(name, isDirectory: true)
        ensurePrivateDirectory(at: url, context: "Transcripted \(name) folder")
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
