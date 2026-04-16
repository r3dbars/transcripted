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

    runSuite("Transcripted capture library helpers — custom capture folders stay owner-only") {
        let original = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        defer {
            restore(original, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        }

        let customRoot = FileManager.default.temporaryDirectory
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
}
