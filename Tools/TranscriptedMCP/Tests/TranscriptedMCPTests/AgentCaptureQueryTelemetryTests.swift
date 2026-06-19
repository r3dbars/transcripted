import Foundation
import XCTest
@testable import transcripted_mcp

final class AgentCaptureQueryTelemetryTests: XCTestCase {
    func testObservationKeepsOnlyBucketedPayload() throws {
        let now = Date(timeIntervalSince1970: 1_766_102_400)
        let captureDate = now.addingTimeInterval(-72 * 3_600)
        let observation = AgentCaptureQueryObservation(
            queryKind: "search",
            artifactKind: "mixed",
            captureDate: captureDate,
            sourceCount: 4,
            now: now
        )

        XCTAssertEqual(observation.properties["agent_target"], "mcp_client")
        XCTAssertEqual(observation.properties["query_kind"], "search")
        XCTAssertEqual(observation.properties["artifact_kind"], "mixed")
        XCTAssertEqual(observation.properties["result"], "success")
        XCTAssertEqual(observation.properties["surface"], "mcp")
        XCTAssertEqual(observation.properties["return_window_bucket"], "3_7d")
        XCTAssertEqual(observation.properties["capture_age_bucket"], "2_7d")
        XCTAssertEqual(observation.properties["source_count_bucket"], "4_9")
    }

    func testTelemetryPolicyStripsForbiddenPayloads() throws {
        let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize([
            "agent_target": "mcp_client",
            "artifact_kind": "meeting",
            "capture_age_bucket": "24_48h",
            "query_kind": "read",
            "result": "success",
            "return_window_bucket": "18_36h",
            "source_count_bucket": "1",
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

        XCTAssertEqual(sanitized["agent_target"], "mcp_client")
        XCTAssertEqual(sanitized["artifact_kind"], "meeting")
        XCTAssertEqual(sanitized["capture_age_bucket"], "24_48h")
        XCTAssertEqual(sanitized["query_kind"], "read")
        XCTAssertEqual(sanitized["result"], "success")
        XCTAssertEqual(sanitized["return_window_bucket"], "18_36h")
        XCTAssertEqual(sanitized["source_count_bucket"], "1")
        XCTAssertEqual(sanitized["surface"], "mcp")
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

    func testTelemetryPolicyRejectsUnexpectedEnumValues() throws {
        let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize([
            "agent_target": "raw-agent-name",
            "artifact_kind": "meeting",
            "capture_age_bucket": "24_48h",
            "query_kind": "raw prompt: customer roadmap",
            "result": "success",
            "return_window_bucket": "18_36h",
            "source_count_bucket": "1",
            "surface": "mcp",
        ])

        XCTAssertNil(sanitized["agent_target"])
        XCTAssertNil(sanitized["query_kind"])
        XCTAssertEqual(sanitized["artifact_kind"], "meeting")
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
                queryKind: "read",
                artifactKind: "dictation",
                captureDate: nil,
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
        XCTAssertEqual(properties["agent_target"], "mcp_client")
        XCTAssertEqual(properties["artifact_kind"], "dictation")
        XCTAssertEqual(properties["query_kind"], "read")
        XCTAssertEqual(properties["surface"], "mcp")
        XCTAssertEqual(properties["source_count_bucket"], "1")
        XCTAssertNil(properties["query_text"])
        XCTAssertNil(properties["transcript_text"])
        XCTAssertNil(properties["file_path"])
        XCTAssertNil(properties["meeting_title"])
        XCTAssertNil(properties["source_app_name"])
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
            appSupportDirectory: appSupport,
            bundleInfo: [:]
        )
        XCTAssertEqual(enabled?.apiKey, "phc_override")
        XCTAssertEqual(enabled?.host.absoluteString, "https://us.i.posthog.com")

        defaults.set(false, forKey: "observability-anonymous-analytics-enabled")
        let disabled = AgentCaptureQueryTelemetryConfiguration.resolve(
            environment: [:],
            userDefaults: defaults,
            appSupportDirectory: appSupport,
            bundleInfo: [:]
        )
        XCTAssertNil(disabled)
    }
}
