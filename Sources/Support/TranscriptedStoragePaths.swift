// TranscriptedStoragePaths.swift
// Shared storage layout helpers for Transcripted.

import Foundation

struct TranscriptedMCPDirectoriesManifest: Codable, Equatable {
    let version: Int
    let captureLibraryDirectory: String
    let meetingsDirectory: String
    let dictationsDirectory: String
    let updatedAt: String
}

enum TranscriptedStoragePreferences {
    static let captureLibraryLocationKey = "transcriptSaveLocation"

    static func captureLibraryURL(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        if let customPath = userDefaults.string(forKey: captureLibraryLocationKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty {
            guard customPath.hasPrefix("/") else {
                return fileManager.transcriptedDefaultCaptureLibraryDir
            }

            let candidate = URL(fileURLWithPath: customPath, isDirectory: true)
            // Security: reject tampered preferences that target traversal or system
            // roots while preserving the user's ability to choose their own library.
            if isSafeCaptureLibraryURL(candidate) {
                return candidate.standardizedFileURL
            }
        }

        return fileManager.transcriptedDefaultCaptureLibraryDir
    }

    @discardableResult
    static func setCaptureLibraryURL(
        _ url: URL?,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        if let url {
            // Security: keep unsafe roots out of preferences while preserving custom
            // capture-library locations chosen in Settings.
            guard prepareCaptureLibraryURL(url, fileManager: fileManager) else {
                try? fileManager.writeTranscriptedMCPDirectoriesManifestIfNeeded(
                    captureLibraryURL: captureLibraryURL(userDefaults: userDefaults, fileManager: fileManager)
                )
                return false
            }
            let candidate = url.standardizedFileURL
            userDefaults.set(candidate.path, forKey: captureLibraryLocationKey)
        } else {
            userDefaults.removeObject(forKey: captureLibraryLocationKey)
        }

        try? fileManager.writeTranscriptedMCPDirectoriesManifestIfNeeded(
            captureLibraryURL: captureLibraryURL(userDefaults: userDefaults, fileManager: fileManager)
        )
        return true
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

    static func prepareCaptureLibraryURL(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard isSafeCaptureLibraryURL(url) else {
            return false
        }

        let root = url.standardizedFileURL
        let meetings = root.appendingPathComponent("meetings", isDirectory: true)
        let dictations = root.appendingPathComponent("dictations", isDirectory: true)
        let probe = root.appendingPathComponent(".transcripted-write-test-\(UUID().uuidString)", isDirectory: false)

        do {
            try fileManager.createPrivateDirectory(at: root)
            try fileManager.createPrivateDirectory(at: meetings)
            try fileManager.createPrivateDirectory(at: dictations)
            try Data().write(to: probe, options: [.atomic])
            fileManager.restrictFileToOwnerOnly(at: probe)
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            try? fileManager.removeItem(at: probe)
            return false
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

    var transcriptedMCPDirectoriesManifestURL: URL {
        transcriptedAppSupportRootURL.appendingPathComponent("mcp-directories.json", isDirectory: false)
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
        let captureLibrary = ensuredPrivateDirectory(at: url, context: "Transcripted capture library")
        try? writeTranscriptedMCPDirectoriesManifestIfNeeded(captureLibraryURL: captureLibrary)
        return captureLibrary
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

    func writeTranscriptedMCPDirectoriesManifestIfNeeded(
        captureLibraryURL: URL,
        manifestURL: URL? = nil,
        updatedAt: Date = Date()
    ) throws {
        let manifestURL = manifestURL ?? transcriptedMCPDirectoriesManifestURL
        let captureLibrary = captureLibraryURL.standardizedFileURL
        let meetings = captureLibrary.appendingPathComponent("meetings", isDirectory: true)
        let dictations = captureLibrary.appendingPathComponent("dictations", isDirectory: true)

        if let existingData = try? Data(contentsOf: manifestURL),
           let existing = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: existingData),
           existing.captureLibraryDirectory == captureLibrary.path,
           existing.meetingsDirectory == meetings.path,
           existing.dictationsDirectory == dictations.path {
            restrictFileToOwnerOnly(at: manifestURL)
            return
        }

        let manifest = TranscriptedMCPDirectoriesManifest(
            version: 1,
            captureLibraryDirectory: captureLibrary.path,
            meetingsDirectory: meetings.path,
            dictationsDirectory: dictations.path,
            updatedAt: ISO8601DateFormatter().string(from: updatedAt)
        )

        try createPrivateDirectory(at: manifestURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
        restrictFileToOwnerOnly(at: manifestURL)
    }
}
