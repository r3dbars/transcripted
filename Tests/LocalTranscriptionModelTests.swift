import Foundation

func testLocalTranscriptionModel() {
    runSuite("LocalTranscriptionModelPreferences defaults to Parakeet TDT V3") {
        let suiteName = "LocalTranscriptionModelTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            LocalTranscriptionModelPreferences.selectedModel(userDefaults: defaults),
            .parakeetTdtV3,
            "local model selection should default to the recommended multilingual model"
        )
    }

    runSuite("LocalTranscriptionModelPreferences persists explicit model changes") {
        let suiteName = "LocalTranscriptionModelTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LocalTranscriptionModelPreferences.setSelectedModel(.parakeetTdtV2, userDefaults: defaults)

        assertEqual(
            LocalTranscriptionModelPreferences.selectedModel(userDefaults: defaults),
            .parakeetTdtV2,
            "local model selection should round-trip through UserDefaults"
        )
    }

    runSuite("LocalTranscriptionModelResolver prefers bundled model assets when present") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranscriptionModelTests-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundledModelURL = tempRoot
            .appendingPathComponent("parakeet-models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)
        try? FileManager.default.createDirectory(at: bundledModelURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: bundledModelURL.appendingPathComponent("Encoder.mlmodelc").path,
            contents: Data(),
            attributes: nil
        )

        let availability = LocalTranscriptionModelResolver.availability(
            for: .parakeetTdtV2,
            resourceRootURL: tempRoot,
            applicationSupportURL: tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        )

        assertEqual(availability.source, .bundled, "bundled assets should win over cache or download")
        assertEqual(availability.directoryURL, bundledModelURL, "resolver should return the bundled model directory")
    }

    runSuite("LocalTranscriptionModelResolver falls back to the local cache before requiring a download") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranscriptionModelTests-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let applicationSupportURL = tempRoot.appendingPathComponent("Application Support", isDirectory: true)
        let cachedModelURL = applicationSupportURL
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        try? FileManager.default.createDirectory(at: cachedModelURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: cachedModelURL.appendingPathComponent("Encoder.mlmodelc").path,
            contents: Data(),
            attributes: nil
        )

        let availability = LocalTranscriptionModelResolver.availability(
            for: .parakeetTdtV3,
            resourceRootURL: tempRoot.appendingPathComponent("NoBundle", isDirectory: true),
            applicationSupportURL: applicationSupportURL
        )

        assertEqual(availability.source, .cached, "cached model assets should avoid an unnecessary download")
        assertEqual(availability.directoryURL, cachedModelURL, "resolver should return the cached model directory")
    }

    runSuite("LocalTranscriptionModelResolver surfaces download-required state when no local assets exist") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranscriptionModelTests-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let availability = LocalTranscriptionModelResolver.availability(
            for: .parakeetTdtV3,
            resourceRootURL: tempRoot.appendingPathComponent("NoBundle", isDirectory: true),
            applicationSupportURL: tempRoot.appendingPathComponent("Application Support", isDirectory: true)
        )

        assertEqual(availability.source, .downloadRequired, "resolver should be explicit when setup needs a first download")
        assertNil(availability.directoryURL, "download-required state should not pretend a local folder exists")
    }
}
