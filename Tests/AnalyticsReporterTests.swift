import Foundation

func testAnalyticsReporter() {
    runSuite("AnalyticsRuntimeConfiguration prefers Transcripted overrides before legacy Draft") {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AnalyticsReporterTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        defer { try? fm.removeItem(at: appSupport) }

        let transcriptedOverrides = appSupport
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("observability-overrides.plist")
        let draftOverrides = appSupport
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("observability-overrides.plist")

        try? fm.createDirectory(at: transcriptedOverrides.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: draftOverrides.deletingLastPathComponent(), withIntermediateDirectories: true)

        NSDictionary(dictionary: [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: "transcripted-key",
        ]).write(to: transcriptedOverrides, atomically: true)
        NSDictionary(dictionary: [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: "draft-key",
        ]).write(to: draftOverrides, atomically: true)

        let value = AnalyticsRuntimeConfiguration.localOverrideValue(
            forKey: AnalyticsRuntimeConfiguration.apiKeyInfoKey,
            appSupportDirectory: appSupport
        )

        assertEqual(value, "transcripted-key", "Transcripted override should win over legacy Draft fallback")
    }

    runSuite("AnalyticsRuntimeConfiguration falls back to Draft overrides for legacy local secrets") {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AnalyticsReporterTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        defer { try? fm.removeItem(at: appSupport) }

        let draftOverrides = appSupport
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("observability-overrides.plist")

        try? fm.createDirectory(at: draftOverrides.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSDictionary(dictionary: [
            AnalyticsRuntimeConfiguration.hostInfoKey: "https://legacy.example.com",
        ]).write(to: draftOverrides, atomically: true)

        let value = AnalyticsRuntimeConfiguration.localOverrideValue(
            forKey: AnalyticsRuntimeConfiguration.hostInfoKey,
            appSupportDirectory: appSupport
        )

        assertEqual(value, "https://legacy.example.com", "legacy Draft override should still work when Transcripted override is absent")
    }
}
