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

    runSuite("AnalyticsReporter default properties include exact build metadata") {
        let properties = AnalyticsReporter.defaultProperties(
            distinctID: "anonymous-device",
            sessionID: "session-1",
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456",
            ],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        assertEqual(properties["distinct_id"], "anonymous-device", "distinct id should be included")
        assertEqual(properties["app_version"], "1.2.3", "app version should be included")
        assertEqual(properties["build_version"], "456", "build version should be included")
        assertEqual(properties["os_major"], "15", "OS major version should be included")
        assertEqual(properties["session_id"], "session-1", "sanitized session id should be included")
    }

    runSuite("AnalyticsReporter keeps caller build metadata over current defaults") {
        let properties = AnalyticsReporter.captureProperties(
            sanitizedProperties: [
                "app_version": "1.2.2",
                "build_version": "455",
            ],
            distinctID: "anonymous-device",
            sessionID: "session-1",
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456",
            ],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        assertEqual(properties["app_version"], "1.2.2", "caller app version should win")
        assertEqual(properties["build_version"], "455", "caller build version should win")
        assertEqual(properties["distinct_id"], "anonymous-device", "default distinct id should remain")
        assertEqual(properties["session_id"], "session-1", "default session id should remain")
    }
}
