import Foundation
import XCTest
@testable import transcripted_mcp

final class AgentCaptureQueryTelemetryTests: XCTestCase {
    func testObservationKeepsOnlyBucketedPayload() throws {
        let observation = AgentCaptureQueryObservation(
            toolKind: "search",
            captureKind: "mixed",
            sourceCount: 4
        )

        XCTAssertEqual(observation.properties["client_family"], "mcp")
        XCTAssertEqual(observation.properties["tool_kind"], "search")
        XCTAssertEqual(observation.properties["capture_kind"], "mixed")
        XCTAssertEqual(observation.properties["result"], "success")
        XCTAssertEqual(observation.properties["source_count_bucket"], "4_9")
        XCTAssertEqual(Set(observation.properties.keys), AgentCaptureQueryTelemetryPolicy.allowedProperties)
    }

    func testTelemetryPolicyStripsForbiddenPayloads() throws {
        let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize([
            "client_family": "mcp",
            "capture_kind": "meeting",
            "result": "success",
            "source_count_bucket": "1",
            "tool_kind": "read",
            "agent_target": "mcp_client",
            "artifact_kind": "meeting",
            "capture_age_bucket": "24_48h",
            "query_kind": "read",
            "return_window_bucket": "18_36h",
            "surface": "mcp",
            "query_text": "what did Alice say about the roadmap?",
            "transcript_text": "private transcript words",
            "speaker_name": "Alice",
            "meeting_title": "Customer Roadmap",
            "source_app_name": "Slack",
            "file_path": "/Users/redbars/private.md",
            "raw_capture_id": "cap_private",
            "url": "https://example.com/private",
            "token": "secret",
        ])

        XCTAssertEqual(sanitized["client_family"], "mcp")
        XCTAssertEqual(sanitized["capture_kind"], "meeting")
        XCTAssertEqual(sanitized["result"], "success")
        XCTAssertEqual(sanitized["source_count_bucket"], "1")
        XCTAssertEqual(sanitized["tool_kind"], "read")
        XCTAssertNil(sanitized["agent_target"])
        XCTAssertNil(sanitized["artifact_kind"])
        XCTAssertNil(sanitized["capture_age_bucket"])
        XCTAssertNil(sanitized["query_kind"])
        XCTAssertNil(sanitized["return_window_bucket"])
        XCTAssertNil(sanitized["surface"])
        XCTAssertNil(sanitized["query_text"])
        XCTAssertNil(sanitized["transcript_text"])
        XCTAssertNil(sanitized["speaker_name"])
        XCTAssertNil(sanitized["meeting_title"])
        XCTAssertNil(sanitized["source_app_name"])
        XCTAssertNil(sanitized["file_path"])
        XCTAssertNil(sanitized["raw_capture_id"])
        XCTAssertNil(sanitized["url"])
        XCTAssertNil(sanitized["token"])
    }

    func testTelemetryPolicyAllowsOrientationToolKinds() throws {
        for toolKind in ["action_items", "commitments", "decisions", "digest", "list", "open_questions", "recent"] {
            let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize([
                "client_family": "mcp",
                "capture_kind": "meeting",
                "result": "success",
                "source_count_bucket": "1",
                "tool_kind": toolKind,
            ])

            XCTAssertEqual(sanitized["tool_kind"], toolKind)
        }
    }

    func testTelemetryPolicyRejectsUnexpectedEnumValues() throws {
        let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize([
            "client_family": "raw-agent-name",
            "capture_kind": "meeting",
            "result": "success",
            "source_count_bucket": "1",
            "tool_kind": "raw prompt: customer roadmap",
        ])

        XCTAssertNil(sanitized["client_family"])
        XCTAssertNil(sanitized["tool_kind"])
        XCTAssertEqual(sanitized["capture_kind"], "meeting")
    }

    func testReporterBuildsPostHogCaptureWithoutPrivateFields() throws {
        let configuration = AgentCaptureQueryTelemetryConfiguration(
            apiKey: "phc_test",
            host: URL(string: "https://us.i.posthog.com")!,
            distinctID: "anonymous-device"
        )
        let reporter = AgentCaptureQueryTelemetry(configuration: configuration)
        let request = try XCTUnwrap(reporter.makeRequest(
            for: AgentCaptureQueryObservation(
                toolKind: "read",
                captureKind: "dictation",
                sourceCount: 1
            ),
            now: Date(timeIntervalSince1970: 1_766_102_400)
        ))

        XCTAssertEqual(request.url?.absoluteString, "https://us.i.posthog.com/capture/")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(object?["event"] as? String, "agent_capture_query_observed")

        let properties = try XCTUnwrap(object?["properties"] as? [String: String])
        XCTAssertEqual(properties["client_family"], "mcp")
        XCTAssertEqual(properties["capture_kind"], "dictation")
        XCTAssertEqual(properties["tool_kind"], "read")
        XCTAssertEqual(properties["source_count_bucket"], "1")
        XCTAssertNil(properties["agent_target"])
        XCTAssertNil(properties["artifact_kind"])
        XCTAssertNil(properties["query_kind"])
        XCTAssertNil(properties["surface"])
        XCTAssertNil(properties["query_text"])
        XCTAssertNil(properties["transcript_text"])
        XCTAssertNil(properties["file_path"])
        XCTAssertNil(properties["meeting_title"])
        XCTAssertNil(properties["source_app_name"])
    }

    func testReporterRechecksConfigurationBeforeEachRequest() throws {
        let configuration = AgentCaptureQueryTelemetryConfiguration(
            apiKey: "phc_test",
            host: URL(string: "https://us.i.posthog.com")!,
            distinctID: "anonymous-device"
        )
        var enabled = true
        let reporter = AgentCaptureQueryTelemetry(configurationProvider: {
            enabled ? configuration : nil
        })
        let observation = AgentCaptureQueryObservation(
            toolKind: "read",
            captureKind: "meeting",
            sourceCount: 1
        )

        XCTAssertNotNil(reporter.makeRequest(for: observation))

        enabled = false
        XCTAssertNil(
            reporter.makeRequest(for: observation),
            "long-running MCP servers must honor analytics opt-out changes before sending the next event"
        )
    }

    func testConfigurationUsesOverridesAndHonorsAnalyticsOptOut() throws {
        let appSupport = makeTempDir()
        defer { removeTempDir(appSupport) }
        let transcriptedSupport = appSupport.appendingPathComponent("Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptedSupport, withIntermediateDirectories: true)
        let overrides = [
            AgentCaptureQueryTelemetryConfiguration.apiKeyInfoKey: "phc_override",
            AgentCaptureQueryTelemetryConfiguration.hostInfoKey: "https://us.i.posthog.com",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: overrides, format: .xml, options: 0)
        try data.write(to: transcriptedSupport.appendingPathComponent("observability-overrides.plist"))

        let suiteName = "AgentCaptureQueryTelemetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enabled = AgentCaptureQueryTelemetryConfiguration.resolve(
            environment: [:],
            userDefaults: defaults,
            appUserDefaults: nil,
            appSupportDirectory: appSupport,
            bundleInfo: [:]
        )
        XCTAssertEqual(enabled?.apiKey, "phc_override")
        XCTAssertEqual(enabled?.host.absoluteString, "https://us.i.posthog.com")

        defaults.set(false, forKey: "observability-anonymous-analytics-enabled")
        let disabled = AgentCaptureQueryTelemetryConfiguration.resolve(
            environment: [:],
            userDefaults: defaults,
            appUserDefaults: nil,
            appSupportDirectory: appSupport,
            bundleInfo: [:]
        )
        XCTAssertNil(disabled)
    }

    func testConfigurationUsesInstalledHelperObservabilityConfig() throws {
        let appSupport = makeTempDir()
        defer { removeTempDir(appSupport) }
        let transcriptedSupport = appSupport.appendingPathComponent("Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptedSupport, withIntermediateDirectories: true)
        let helperConfig = [
            AgentCaptureQueryTelemetryConfiguration.apiKeyInfoKey: "phc_helper",
            AgentCaptureQueryTelemetryConfiguration.hostInfoKey: "https://us.i.posthog.com",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: helperConfig, format: .xml, options: 0)
        try data.write(to: transcriptedSupport.appendingPathComponent(AgentCaptureQueryTelemetryConfiguration.mcpObservabilityFileName))

        let suiteName = "AgentCaptureQueryTelemetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AgentCaptureQueryTelemetryConfiguration.resolve(
            environment: [:],
            userDefaults: defaults,
            appUserDefaults: nil,
            appSupportDirectory: appSupport,
            bundleInfo: [:]
        )

        XCTAssertEqual(configuration?.apiKey, "phc_helper")
        XCTAssertEqual(configuration?.host.absoluteString, "https://us.i.posthog.com")
    }

    func testConfigurationHonorsAppDefaultsOptOutBeforeHelperDefaults() throws {
        let appSupport = makeTempDir()
        defer { removeTempDir(appSupport) }

        let helperSuiteName = "AgentCaptureQueryTelemetryTests.helper.\(UUID().uuidString)"
        let appSuiteName = "AgentCaptureQueryTelemetryTests.app.\(UUID().uuidString)"
        let helperDefaults = try XCTUnwrap(UserDefaults(suiteName: helperSuiteName))
        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: appSuiteName))
        defer {
            helperDefaults.removePersistentDomain(forName: helperSuiteName)
            appDefaults.removePersistentDomain(forName: appSuiteName)
        }

        helperDefaults.set(true, forKey: "observability-anonymous-analytics-enabled")
        appDefaults.set(false, forKey: "observability-anonymous-analytics-enabled")
        helperDefaults.set("helper-device", forKey: "observability-anonymous-analytics-id")
        appDefaults.set("app-device", forKey: "observability-anonymous-analytics-id")

        let disabled = AgentCaptureQueryTelemetryConfiguration.resolve(
            environment: [
                "POSTHOG_API_KEY": "phc_env",
                "POSTHOG_HOST": "https://us.i.posthog.com",
            ],
            userDefaults: helperDefaults,
            appUserDefaults: appDefaults,
            appSupportDirectory: appSupport,
            bundleInfo: [:]
        )

        XCTAssertNil(disabled)
    }

    func testConfigurationUsesAppDefaultsDistinctIDWhenEnabled() throws {
        let appSupport = makeTempDir()
        defer { removeTempDir(appSupport) }

        let helperSuiteName = "AgentCaptureQueryTelemetryTests.helper.\(UUID().uuidString)"
        let appSuiteName = "AgentCaptureQueryTelemetryTests.app.\(UUID().uuidString)"
        let helperDefaults = try XCTUnwrap(UserDefaults(suiteName: helperSuiteName))
        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: appSuiteName))
        defer {
            helperDefaults.removePersistentDomain(forName: helperSuiteName)
            appDefaults.removePersistentDomain(forName: appSuiteName)
        }

        helperDefaults.set(false, forKey: "observability-anonymous-analytics-enabled")
        appDefaults.set(true, forKey: "observability-anonymous-analytics-enabled")
        helperDefaults.set("helper-device", forKey: "observability-anonymous-analytics-id")
        appDefaults.set("app-device", forKey: "observability-anonymous-analytics-id")

        let configuration = AgentCaptureQueryTelemetryConfiguration.resolve(
            environment: [
                "POSTHOG_API_KEY": "phc_env",
                "POSTHOG_HOST": "https://us.i.posthog.com",
            ],
            userDefaults: helperDefaults,
            appUserDefaults: appDefaults,
            appSupportDirectory: appSupport,
            bundleInfo: [:]
        )

        XCTAssertEqual(configuration?.distinctID, "app-device")
    }
}
