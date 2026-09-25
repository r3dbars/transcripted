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
            manifest.writingDirectory,
            captureRoot.appendingPathComponent("writing", isDirectory: true).standardizedFileURL.path,
            "manifest should expose the writing root"
        )
        assertEqual(
            permissions(of: manifestURL),
            NSNumber(value: 0o600),
            "manifest should be restricted to owner-only access"
        )
    }

    runSuite("Transcripted MCP directory manifest — matches the live meeting/dictation support dirs") {
        // Drift guard: the manifest writer used to re-derive "meetings"/"dictations"
        // inline instead of reusing `meetingSupportDir`/`dictationSupportDir`'s
        // naming. This proves the on-disk manifest for a real (temp) capture-library
        // root always matches what those computed properties report, so a future
        // rename of one without the other fails this test instead of shipping.
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }

        let customRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedStoragePathsTests-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: customRoot) }

        let persisted = TranscriptedStoragePreferences.setCaptureLibraryURL(customRoot)
        assertTrue(persisted, "test setup should persist a safe custom capture-library root")

        let manifestURL = FileManager.default.transcriptedMCPDirectoriesManifestURL
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: data) else {
            assertTrue(false, "manifest should be readable JSON after setting a custom capture library")
            return
        }

        let meetings = FileManager.default.meetingSupportDir
        let dictations = FileManager.default.dictationSupportDir
        let writing = FileManager.default.writingSupportDir

        assertEqual(
            manifest.meetingsDirectory,
            meetings.path,
            "manifest meetingsDirectory should match FileManager.meetingSupportDir for the same capture root"
        )
        assertEqual(
            manifest.dictationsDirectory,
            dictations.path,
            "manifest dictationsDirectory should match FileManager.dictationSupportDir for the same capture root"
        )
        assertEqual(
            manifest.writingDirectory,
            writing.path,
            "manifest writingDirectory should match FileManager.writingSupportDir for the same capture root"
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
        assertTrue(
            FileManager.default.fileExists(atPath: customRoot.appendingPathComponent("writing", isDirectory: true).path),
            "setting a custom capture library should prepare the writing folder before writers use it"
        )

        let captureLibrary = FileManager.default.transcriptedCaptureLibraryDir
        let meetings = FileManager.default.meetingSupportDir
        let dictations = FileManager.default.dictationSupportDir
        let writing = FileManager.default.writingSupportDir

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
        assertEqual(
            writing,
            captureLibrary.appendingPathComponent("writing", isDirectory: true),
            "writing storage should stay inside the chosen capture library"
        )

        for directory in [captureLibrary, meetings, dictations, writing] {
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

    runSuite("Transcripted capture library helpers — writing is a sibling of meetings and dictations") {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-helpers-\(UUID().uuidString)", isDirectory: true)

        assertEqual(FileManager.writingDirectoryName, "writing", "the writing folder name is part of the capture-library contract")
        assertEqual(
            FileManager.writingDirectory(in: library),
            library.appendingPathComponent("writing", isDirectory: true),
            "writing day files live in <capture-library>/writing/"
        )
        assertEqual(
            FileManager.meetingsDirectory(in: library),
            library.appendingPathComponent("meetings", isDirectory: true),
            "the meetings helper should keep the existing folder name"
        )
        assertEqual(
            FileManager.dictationsDirectory(in: library),
            library.appendingPathComponent("dictations", isDirectory: true),
            "the dictations helper should keep the existing folder name"
        )
        assertFalse(
            FileManager.default.fileExists(atPath: library.path),
            "the pure folder helpers must not create anything"
        )
    }

    runSuite("Transcripted MCP directory manifest — a pre-Writing manifest decodes and is rewritten with the writing key") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-prewriting-\(UUID().uuidString)", isDirectory: true)
        let captureRoot = tempRoot.appendingPathComponent("captures", isDirectory: true).standardizedFileURL
        let manifestURL = tempRoot.appendingPathComponent("mcp-directories.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Exactly the shape builds before Writing wrote: no writingDirectory key.
        let meetingsPath = captureRoot.appendingPathComponent("meetings", isDirectory: true).path
        let dictationsPath = captureRoot.appendingPathComponent("dictations", isDirectory: true).path
        let preWriting: [String: Any] = [
            "version": 1,
            "captureLibraryDirectory": captureRoot.path,
            "meetingsDirectory": meetingsPath,
            "dictationsDirectory": dictationsPath,
            "updatedAt": "1970-01-01T00:00:00Z",
        ]
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: preWriting) {
            try? data.write(to: manifestURL, options: [.atomic])
        }

        guard let oldData = try? Data(contentsOf: manifestURL),
              let old = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: oldData) else {
            assertTrue(false, "a manifest without writingDirectory should still decode")
            return
        }
        assertNil(old.writingDirectory, "a pre-Writing manifest has no writing folder")
        assertEqual(old.meetingsDirectory, meetingsPath, "older keys should decode unchanged")
        assertEqual(old.dictationsDirectory, dictationsPath, "older keys should decode unchanged")

        try? FileManager.default.writeTranscriptedMCPDirectoriesManifestIfNeeded(
            captureLibraryURL: captureRoot,
            manifestURL: manifestURL,
            updatedAt: Date(timeIntervalSince1970: 86_400)
        )

        guard let newData = try? Data(contentsOf: manifestURL),
              let rewritten = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: newData) else {
            assertTrue(false, "the rewritten manifest should decode")
            return
        }
        assertEqual(
            rewritten.writingDirectory,
            captureRoot.appendingPathComponent("writing", isDirectory: true).path,
            "the equality shortcut must not keep a manifest that lacks the writing folder"
        )
        assertEqual(rewritten.updatedAt, "1970-01-02T00:00:00Z", "the pre-Writing manifest should have been rewritten")
        assertEqual(rewritten.version, 1, "an optional key is additive, so the version stays 1")
        assertEqual(rewritten.meetingsDirectory, meetingsPath, "the rewrite should keep the meetings folder")
        assertEqual(rewritten.dictationsDirectory, dictationsPath, "the rewrite should keep the dictations folder")
    }

    runSuite("Transcripted MCP directory manifest — a current manifest round-trips and is not rewritten") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-roundtrip-\(UUID().uuidString)", isDirectory: true)
        let captureRoot = tempRoot.appendingPathComponent("captures", isDirectory: true)
        let manifestURL = tempRoot.appendingPathComponent("mcp-directories.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.writeTranscriptedMCPDirectoriesManifestIfNeeded(
            captureLibraryURL: captureRoot,
            manifestURL: manifestURL,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try? FileManager.default.writeTranscriptedMCPDirectoriesManifestIfNeeded(
            captureLibraryURL: captureRoot,
            manifestURL: manifestURL,
            updatedAt: Date(timeIntervalSince1970: 86_400)
        )

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: data) else {
            assertTrue(false, "manifest should be readable JSON")
            return
        }
        assertEqual(manifest.updatedAt, "1970-01-01T00:00:00Z", "an up-to-date manifest with the writing key should not be rewritten")
        assertNotNil(manifest.writingDirectory, "the written manifest should carry the writing folder")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = try? encoder.encode(manifest)
        assertEqual(
            reencoded.flatMap { try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: $0) },
            manifest,
            "the manifest should round-trip through Codable unchanged"
        )

        let withoutWriting = TranscriptedMCPDirectoriesManifest(
            version: 1,
            captureLibraryDirectory: manifest.captureLibraryDirectory,
            meetingsDirectory: manifest.meetingsDirectory,
            dictationsDirectory: manifest.dictationsDirectory,
            writingDirectory: nil,
            updatedAt: manifest.updatedAt
        )
        guard let withoutWritingData = try? encoder.encode(withoutWriting),
              let withoutWritingKeys = (try? JSONSerialization.jsonObject(with: withoutWritingData)) as? [String: Any] else {
            assertTrue(false, "a manifest without the writing folder should encode")
            return
        }
        assertFalse(
            withoutWritingKeys.keys.contains("writingDirectory"),
            "a nil writing folder should be omitted, keeping the pre-Writing shape"
        )
        assertEqual(
            try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: withoutWritingData),
            withoutWriting,
            "a manifest without the writing key should round-trip too"
        )
    }

    runSuite("Transcripted MCP directory manifest — matches the shared reader/writer contract fixture") {
        // Round-trip contract for mcp-directories.json: TranscriptedMCPDirectoriesManifest
        // (this file) and TranscriptedCaptureKit's CaptureDirectoryManifest are two
        // independently declared Codable structs with no compiler-enforced link between
        // them. Tests/Fixtures/mcp-directories-manifest/golden.json pins the exact shape
        // the real writer produces; TranscriptedCaptureKit's
        // CaptureLibraryResolverTests.testResolveDecodesRealAppWrittenManifestFixture
        // stages the same fixture and confirms the reader still agrees with it.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TranscriptedStoragePathsTests.swift
            .appendingPathComponent("Fixtures/mcp-directories-manifest/golden.json")

        guard let goldenData = try? Data(contentsOf: fixtureURL) else {
            assertTrue(false, "golden mcp-directories.json fixture should be readable at \(fixtureURL.path)")
            return
        }
        guard let golden = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: goldenData) else {
            assertTrue(false, "golden mcp-directories.json fixture should decode as TranscriptedMCPDirectoriesManifest")
            return
        }

        let tempManifestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedStoragePathsTests-manifest-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempManifestURL) }

        let captureLibraryURL = URL(fileURLWithPath: golden.captureLibraryDirectory, isDirectory: true)
        try? FileManager.default.writeTranscriptedMCPDirectoriesManifestIfNeeded(
            captureLibraryURL: captureLibraryURL,
            manifestURL: tempManifestURL,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        guard let writtenData = try? Data(contentsOf: tempManifestURL) else {
            assertTrue(false, "app writer should produce a readable manifest for the fixture's capture-library input")
            return
        }

        if let writtenKeys = (try? JSONSerialization.jsonObject(with: writtenData)) as? [String: Any],
           let goldenKeys = (try? JSONSerialization.jsonObject(with: goldenData)) as? [String: Any] {
            assertEqual(
                Set(writtenKeys.keys),
                Set(goldenKeys.keys),
                "app writer's mcp-directories.json key set diverged from the shared reader/writer contract fixture — update TranscriptedCaptureKit's CaptureDirectoryManifest and this fixture together"
            )
        } else {
            assertTrue(false, "writer output and golden fixture should both decode as JSON objects")
        }

        guard let written = try? JSONDecoder().decode(TranscriptedMCPDirectoriesManifest.self, from: writtenData) else {
            assertTrue(false, "app writer output should decode as TranscriptedMCPDirectoriesManifest")
            return
        }

        assertEqual(
            written,
            golden,
            "app writer output for the fixture's capture-library input should match the golden fixture exactly"
        )
    }
}
