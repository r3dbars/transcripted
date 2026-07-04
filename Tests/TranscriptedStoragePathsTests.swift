import Foundation

func testTranscriptedStoragePaths() {
    func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func permissions(of url: URL) -> NSNumber? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.posixPermissions] as? NSNumber
    }

    let originalManifestURL = FileManager.default.transcriptedMCPDirectoriesManifestURL
    let originalManifestExists = FileManager.default.fileExists(atPath: originalManifestURL.path)
    let originalManifestData = try? Data(contentsOf: originalManifestURL)
    defer {
        if originalManifestExists, let originalManifestData {
            try? FileManager.default.createPrivateDirectory(at: originalManifestURL.deletingLastPathComponent())
            try? originalManifestData.write(to: originalManifestURL, options: [.atomic])
            FileManager.default.restrictFileToOwnerOnly(at: originalManifestURL)
        } else {
            try? FileManager.default.removeItem(at: originalManifestURL)
        }
    }

    runSuite("FileManager.createPrivateDirectory — tightens existing directories to owner-only") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-existing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        assertEqual(
            permissions(of: directory),
            NSNumber(value: 0o755),
            "test setup should start from a broader directory permission"
        )

        try? FileManager.default.createPrivateDirectory(at: directory)

        assertEqual(
            permissions(of: directory),
            NSNumber(value: 0o700),
            "private-directory helper should tighten existing directories back to owner-only access"
        )
    }

    runSuite("FileManager.restrictFileToOwnerOnly — tightens existing files to owner-only") {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-file-\(UUID().uuidString).txt", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: file) }

        FileManager.default.createFile(
            atPath: file.path,
            contents: Data("hello".utf8),
            attributes: [.posixPermissions: 0o644]
        )

        assertEqual(
            permissions(of: file),
            NSNumber(value: 0o644),
            "test setup should start from a broader file permission"
        )

        FileManager.default.restrictFileToOwnerOnly(at: file)

        assertEqual(
            permissions(of: file),
            NSNumber(value: 0o600),
            "owner-only file helper should tighten permissions to 0600"
        )
    }

    runSuite("Transcripted MCP directory manifest — writes current capture roots") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-mcp-\(UUID().uuidString)", isDirectory: true)
        let captureRoot = tempRoot.appendingPathComponent("captures", isDirectory: true)
        let manifestURL = tempRoot
            .appendingPathComponent("support", isDirectory: true)
            .appendingPathComponent("mcp-directories.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.writeTranscriptedMCPDirectoriesManifestIfNeeded(
            captureLibraryURL: captureRoot,
            manifestURL: manifestURL,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: data) else {
            assertTrue(false, "manifest should be readable JSON")
            return
        }

        assertEqual(manifest.version, 1, "manifest should include a version")
        assertEqual(manifest.captureLibraryDirectory, captureRoot.standardizedFileURL.path, "manifest should expose capture root")
        assertEqual(
            manifest.meetingsDirectory,
            captureRoot.appendingPathComponent("meetings", isDirectory: true).standardizedFileURL.path,
            "manifest should expose meetings root"
        )
        assertEqual(
            manifest.dictationsDirectory,
            captureRoot.appendingPathComponent("dictations", isDirectory: true).standardizedFileURL.path,
            "manifest should expose dictations root"
        )
        assertEqual(
            permissions(of: manifestURL),
            NSNumber(value: 0o600),
            "manifest should be restricted to owner-only access"
        )
    }

    runSuite("Transcripted capture library helpers — custom capture folders stay owner-only") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }

        let customRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: customRoot) }

        let persisted = TranscriptedStoragePreferences.setCaptureLibraryURL(customRoot)

        assertTrue(persisted, "safe custom capture-library folders should persist")
        assertTrue(
            FileManager.default.fileExists(atPath: customRoot.path),
            "setting a custom capture library should create the selected root immediately"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: customRoot.appendingPathComponent("meetings", isDirectory: true).path),
            "setting a custom capture library should prepare the meetings folder before writers use it"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: customRoot.appendingPathComponent("dictations", isDirectory: true).path),
            "setting a custom capture library should prepare the dictations folder before writers use it"
        )

        let captureLibrary = FileManager.default.transcriptedCaptureLibraryDir
        let meetings = FileManager.default.meetingSupportDir
        let dictations = FileManager.default.dictationSupportDir

        assertEqual(
            captureLibrary,
            customRoot.standardizedFileURL,
            "custom capture-library preference should drive the app-facing storage roots"
        )
        assertEqual(
            meetings,
            captureLibrary.appendingPathComponent("meetings", isDirectory: true),
            "meeting storage should stay inside the chosen capture library"
        )
        assertEqual(
            dictations,
            captureLibrary.appendingPathComponent("dictations", isDirectory: true),
            "dictation storage should stay inside the chosen capture library"
        )

        for directory in [captureLibrary, meetings, dictations] {
            assertTrue(
                FileManager.default.fileExists(atPath: directory.path),
                "expected storage directory to exist: \(directory.lastPathComponent)"
            )
            assertEqual(
                permissions(of: directory),
                NSNumber(value: 0o700),
                "storage directory should be restricted to owner-only access: \(directory.lastPathComponent)"
            )
        }
    }

    runSuite("Transcripted capture library helpers — reject unsafe capture folders") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }
        UserDefaults.standard.removeObject(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)

        let disallowedRoot = URL(fileURLWithPath: "/System/Library/Transcripted", isDirectory: true)

        TranscriptedStoragePreferences.setCaptureLibraryURL(disallowedRoot)

        assertEqual(
            UserDefaults.standard.string(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey),
            nil,
            "unsafe capture-library paths should not be persisted"
        )
        assertEqual(
            FileManager.default.transcriptedCaptureLibraryDir,
            FileManager.default.transcriptedDefaultCaptureLibraryDir,
            "storage should fall back to the default Transcripted Library capture root"
        )
    }

    runSuite("Transcripted capture library helpers — reject relative capture folders") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }

        UserDefaults.standard.set(
            "relative-capture-root",
            forKey: TranscriptedStoragePreferences.captureLibraryLocationKey
        )

        assertEqual(
            FileManager.default.transcriptedCaptureLibraryDir,
            FileManager.default.transcriptedDefaultCaptureLibraryDir,
            "relative capture-library paths should fall back to the default Transcripted Library capture root"
        )
        assertEqual(
            FileManager.default.meetingSupportDir,
            FileManager.default.transcriptedDefaultCaptureLibraryDir.appendingPathComponent("meetings", isDirectory: true),
            "meeting storage should also stay under the default root when preferences are tampered with"
        )
        assertEqual(
            FileManager.default.dictationSupportDir,
            FileManager.default.transcriptedDefaultCaptureLibraryDir.appendingPathComponent("dictations", isDirectory: true),
            "dictation storage should also stay under the default root when preferences are tampered with"
        )
    }

    runSuite("Transcripted capture library helpers — missing custom folders fall back without recreating") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }

        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: missingRoot) }

        UserDefaults.standard.set(
            missingRoot.path,
            forKey: TranscriptedStoragePreferences.captureLibraryLocationKey
        )

        assertFalse(
            FileManager.default.fileExists(atPath: missingRoot.path),
            "test setup should start with a missing custom capture library"
        )
        assertEqual(
            TranscriptedStoragePreferences.customCaptureLibraryURL(),
            nil,
            "missing custom capture-library preferences should not resolve as usable"
        )
        assertEqual(
            TranscriptedStoragePreferences.unavailableCustomCaptureLibraryPath(),
            missingRoot.path,
            "settings should be able to explain which saved custom library is unavailable"
        )
        assertEqual(
            FileManager.default.transcriptedCaptureLibraryDir,
            FileManager.default.transcriptedDefaultCaptureLibraryDir,
            "runtime storage should fall back to the default capture root when a custom library is gone"
        )
        assertFalse(
            FileManager.default.fileExists(atPath: missingRoot.path),
            "resolving storage should not recreate a missing custom capture library or phantom mount point"
        )
    }

    runSuite("Transcripted capture library helpers — reject file-shaped capture folders") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }
        UserDefaults.standard.removeObject(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)

        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-file-root-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        FileManager.default.createFile(atPath: fileURL.path, contents: Data("not a directory".utf8))

        let persisted = TranscriptedStoragePreferences.setCaptureLibraryURL(fileURL)

        assertFalse(persisted, "file-shaped capture-library roots should be rejected before persistence")
        assertEqual(
            UserDefaults.standard.string(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey),
            nil,
            "unusable capture-library paths should not stay in preferences"
        )
        assertEqual(
            FileManager.default.transcriptedCaptureLibraryDir,
            FileManager.default.transcriptedDefaultCaptureLibraryDir,
            "storage should fall back to the default capture root after rejecting an unusable folder"
        )
    }

    runSuite("Transcripted capture library helpers — preserve current folder after failed replacement") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }

        let existingRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-existing-root-\(UUID().uuidString)", isDirectory: true)
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-replacement-file-root-\(UUID().uuidString)", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: existingRoot)
            try? FileManager.default.removeItem(at: fileURL)
        }

        assertTrue(
            TranscriptedStoragePreferences.setCaptureLibraryURL(existingRoot),
            "test setup should persist the existing safe capture library"
        )
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("not a directory".utf8))

        let persisted = TranscriptedStoragePreferences.setCaptureLibraryURL(fileURL)

        assertFalse(persisted, "unusable replacement folders should be rejected")
        assertEqual(
            UserDefaults.standard.string(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey),
            existingRoot.standardizedFileURL.path,
            "rejecting a replacement folder should preserve the current capture-library preference"
        )
        assertEqual(
            FileManager.default.transcriptedCaptureLibraryDir,
            existingRoot.standardizedFileURL,
            "storage should keep using the previous capture library after a rejected replacement"
        )
    }
}
