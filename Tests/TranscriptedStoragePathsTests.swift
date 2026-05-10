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

        TranscriptedStoragePreferences.setCaptureLibraryURL(customRoot)

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

    runSuite("Transcripted capture library helpers — prepare writable folders before saving") {
        let customRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-prepared-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: customRoot) }

        do {
            let preparedURL = try TranscriptedStoragePreferences.prepareCaptureLibraryURL(customRoot)
            assertEqual(
                preparedURL,
                customRoot.standardizedFileURL,
                "prepared capture-library URL should use the standardized selected folder"
            )
            assertTrue(
                FileManager.default.fileExists(atPath: preparedURL.path),
                "preparing a capture library should create the selected folder immediately"
            )
            assertEqual(
                permissions(of: preparedURL),
                NSNumber(value: 0o700),
                "prepared capture-library folder should be private"
            )
        } catch {
            assertTrue(false, "expected writable capture library to prepare successfully: \(error)")
        }
    }

    runSuite("Transcripted capture library helpers — reject file selections before saving") {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-file-\(UUID().uuidString).txt", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        FileManager.default.createFile(atPath: fileURL.path, contents: Data("not a folder".utf8))

        do {
            _ = try TranscriptedStoragePreferences.prepareCaptureLibraryURL(fileURL)
            assertTrue(false, "file selections should not prepare as capture libraries")
        } catch let error as TranscriptedStoragePreferences.CaptureLibraryValidationError {
            assertEqual(
                error,
                .notDirectory,
                "file selections should fail with the not-directory validation error"
            )
        } catch {
            assertTrue(false, "unexpected validation error: \(error)")
        }
    }

    runSuite("Transcripted capture library helpers — reject non-writable folders before saving") {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-readonly-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500]
        )

        do {
            _ = try TranscriptedStoragePreferences.prepareCaptureLibraryURL(directory)
            assertTrue(false, "non-writable folders should not prepare as capture libraries")
        } catch let error as TranscriptedStoragePreferences.CaptureLibraryValidationError {
            assertEqual(
                error,
                .notWritable,
                "non-writable folders should fail with the writable-folder validation error"
            )
        } catch {
            assertTrue(false, "unexpected validation error: \(error)")
        }
    }

    runSuite("Transcripted capture library helpers — reject unsafe capture folders") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }

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
}
