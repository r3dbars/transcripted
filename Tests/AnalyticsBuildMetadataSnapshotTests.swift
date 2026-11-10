import Foundation

func testAnalyticsBuildMetadataSnapshot() {
    runSuite("Event and person metadata keep the captured build environment") {
        let keys = [AnalyticsRuntimeConfiguration.buildChannelEnvironmentKey,
                    AnalyticsRuntimeConfiguration.buildRevisionEnvironmentKey]
        let originalEnvironment = ProcessInfo.processInfo.environment
        defer {
            for key in keys {
                let result = originalEnvironment[key].map { setenv(key, $0, 1) } ?? unsetenv(key)
                assertEqual(result, 0, "the test must restore each build override")
            }
        }

        // Initialize the existing snapshot before changing this process's env.
        _ = AnalyticsRuntimeConfiguration.processBuildMetadataEnvironment
        let defaults = BuildMetadataReadOnlyDefaults()
        let beforeEvent = snapshotEventProperties()
        let beforePerson = InstallIdentity.traits(userDefaults: defaults)
        let beforeValues = Set([beforeEvent["build_channel"], beforeEvent["build_revision"],
                                beforePerson["install_channel"], beforePerson["build_revision"]].compactMap { $0 })
        // Five candidates guarantee a value distinct from the four saved fields.
        let changed = ["postcache_a", "postcache_b", "postcache_c", "postcache_d", "postcache_e"]
            .first { !beforeValues.contains($0) }!
        for key in keys {
            assertEqual(setenv(key, changed, 1), 0, "the synthetic build override must apply")
        }

        let afterEvent = snapshotEventProperties()
        let afterPerson = InstallIdentity.traits(userDefaults: defaults)
        assertEqual(afterEvent["build_channel"], beforeEvent["build_channel"],
                    "event channel must use the captured build environment")
        assertEqual(afterEvent["build_revision"], beforeEvent["build_revision"],
                    "event revision must use the captured build environment")
        assertEqual(afterPerson["install_channel"], beforePerson["install_channel"],
                    "person channel must use the same captured environment")
        assertEqual(afterPerson["build_revision"], beforePerson["build_revision"],
                    "person revision must use the same captured environment")
        assertEqual(defaults.unexpectedWrites, 0, "metadata lookup must not write preferences")
    }

    runSuite("Caller-supplied historical build metadata still overrides current defaults") {
        let properties = AnalyticsReporter.captureProperties(
            sanitizedProperties: ["build_channel": "historical_fixture", "build_revision": "fixture_revision"],
            distinctID: "11111111-1111-1111-1111-111111111111",
            sessionID: "22222222-2222-2222-2222-222222222222"
        )
        assertEqual(properties["build_channel"], "historical_fixture", "historical channel must survive")
        assertEqual(properties["build_revision"], "fixture_revision", "historical revision must survive")
    }
}

private func snapshotEventProperties() -> [String: String] {
    AnalyticsReporter.captureProperties(
        sanitizedProperties: [:],
        distinctID: "11111111-1111-1111-1111-111111111111",
        sessionID: "22222222-2222-2222-2222-222222222222",
        infoDictionary: [
            AnalyticsInfoPlistKeys.buildChannelInfoKey: "fixture_channel",
            AnalyticsInfoPlistKeys.buildRevisionInfoKey: "fixture_revision",
        ]
    )
}

/// Only the explicit synthetic first-observed day is readable. Never forwards
/// preference reads or writes to CFPreferences; no reporter instance is created.
private final class BuildMetadataReadOnlyDefaults: UserDefaults, @unchecked Sendable {
    private(set) var unexpectedWrites = 0

    init(inMemory: Void = ()) { super.init(suiteName: nil)! }

    override func string(forKey defaultName: String) -> String? {
        defaultName == "observability-first-launch-day" ? "2026-01-02" : nil
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        unexpectedWrites += 1
    }
}
