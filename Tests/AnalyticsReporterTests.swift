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

    runSuite("AnalyticsReporter countBucket keeps zero start attempts explicit") {
        assertEqual(
            AnalyticsReporter.countBucket(0),
            "0",
            "start-failure telemetry should preserve that no recording attempt ran"
        )
    }

    runSuite("AnalyticsReporter countBucket preserves a single start attempt") {
        assertEqual(
            AnalyticsReporter.countBucket(1),
            "1",
            "one failed recording attempt should stay distinguishable from retry loops"
        )
    }

    runSuite("AnalyticsReporter countBucket groups midrange retry attempts") {
        assertEqual(AnalyticsReporter.countBucket(2), "2_3", "two attempts should enter the first retry bucket")
        assertEqual(AnalyticsReporter.countBucket(3), "2_3", "three attempts should stay in the first retry bucket")
        assertEqual(AnalyticsReporter.countBucket(4), "4_9", "four attempts should enter the repeated retry bucket")
        assertEqual(AnalyticsReporter.countBucket(9), "4_9", "nine attempts should remain below the high retry bucket")
    }

    runSuite("AnalyticsReporter countBucket caps unexpected retry spikes") {
        assertEqual(
            AnalyticsReporter.countBucket(10),
            "10_plus",
            "ten or more failed starts should be bucketed instead of exposing raw counts"
        )
        assertEqual(
            AnalyticsReporter.countBucket(37),
            "10_plus",
            "large retry spikes should stay privacy-safe and dashboard-stable"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket keeps empty meeting queues explicit") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(0),
            "0",
            "empty meeting queues should stay distinguishable from queued work"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket preserves a single queued job") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(1),
            "1",
            "one queued meeting job should stay visible as a single-job backlog"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket groups small meeting backlogs") {
        assertEqual(AnalyticsReporter.queueDepthBucket(2), "2_3", "two queued meeting jobs should enter the small backlog bucket")
        assertEqual(AnalyticsReporter.queueDepthBucket(3), "2_3", "three queued meeting jobs should stay in the small backlog bucket")
    }

    runSuite("AnalyticsReporter queueDepthBucket caps larger meeting backlogs") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(4),
            "4_plus",
            "four or more queued meeting jobs should be bucketed instead of exposing raw depth"
        )
        assertEqual(
            AnalyticsReporter.queueDepthBucket(21),
            "4_plus",
            "large queued meeting backlogs should stay coarse for analytics"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket treats invalid negative depths as empty") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(-3),
            "0",
            "invalid negative depths should fail closed to the empty queue bucket"
        )
    }

    runSuite("AnalyticsReporter durationBucket keeps short captures coarse") {
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: 5),
            "lt_10s",
            "short dictation and meeting durations should stay in the shortest coarse bucket"
        )
    }

    runSuite("AnalyticsReporter durationBucket switches buckets at second boundaries") {
        assertEqual(AnalyticsReporter.durationBucket(seconds: 10), "10_29s", "ten seconds should enter the next bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 30), "30_119s", "thirty seconds should enter the next bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 120), "2_9m", "two minutes should enter the minutes bucket")
    }

    runSuite("AnalyticsReporter durationBucket keeps upper edges in their current bucket") {
        assertEqual(AnalyticsReporter.durationBucket(seconds: 29.9), "10_29s", "values below thirty seconds should stay in the second bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 119.9), "30_119s", "values below two minutes should stay in the midrange bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 599.9), "2_9m", "values below ten minutes should stay in the short meeting bucket")
    }

    runSuite("AnalyticsReporter durationBucket caps long sessions") {
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: 1800),
            "30m_plus",
            "thirty minutes or more should stay bucketed instead of exposing raw duration"
        )
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: 7200),
            "30m_plus",
            "multi-hour sessions should stay in the same coarse analytics bucket"
        )
    }

    runSuite("AnalyticsReporter durationBucket treats invalid negative durations as short") {
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: -1),
            "lt_10s",
            "invalid negative durations should fail closed to the shortest duration bucket"
        )
    }
}
