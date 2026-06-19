import XCTest
import MCP
@testable import transcripted_mcp

final class AgentCaptureQueryTelemetryTests: XCTestCase {
    func testSearchContextObservationStaysAggregateOnly() {
        let result = toolTextResult("""
        {
          "results" : [
            { "kind" : "meeting", "filename" : "Call_2026-06-19_10-00-00", "title" : "Private call" },
            { "kind" : "dictation", "entry_id" : "dictation-20260619-private", "text" : "private words" }
          ]
        }
        """)

        let observation = AgentCaptureQueryTelemetry.observation(
            toolName: "search_context",
            result: result,
            clientFamily: "claude_desktop"
        )
        let properties = AgentCaptureQueryTelemetry.sanitizedProperties(observation)

        XCTAssertEqual(properties, [
            "capture_kind": "mixed",
            "client_family": "claude_desktop",
            "result": "success",
            "source_count_bucket": "2_3",
            "tool_kind": "search",
        ])
        XCTAssertFalse(properties.values.joined(separator: " ").contains("Private call"))
        XCTAssertFalse(properties.values.joined(separator: " ").contains("dictation-20260619-private"))
        XCTAssertFalse(properties.values.joined(separator: " ").contains("private words"))
    }

    func testReadMeetingObservationCountsOneSourceWithoutFilename() {
        let result = toolTextResult("""
        # Private Meeting

        [00:00] [System/Alice] Sensitive transcript text
        """)

        let observation = AgentCaptureQueryTelemetry.observation(
            toolName: "read_meeting",
            result: result,
            clientFamily: "cursor"
        )

        XCTAssertEqual(observation.captureKind, "meeting")
        XCTAssertEqual(observation.toolKind, "read")
        XCTAssertEqual(observation.result, "success")
        XCTAssertEqual(observation.sourceCountBucket, "1")
        XCTAssertEqual(observation.clientFamily, "cursor")
    }

    func testNoResultsAndErrorsUseZeroSourceBucket() {
        let noResults = AgentCaptureQueryTelemetry.observation(
            toolName: "recent_context",
            result: toolTextResult("No recent context found."),
            clientFamily: "codex"
        )
        XCTAssertEqual(noResults.result, "no_results")
        XCTAssertEqual(noResults.sourceCountBucket, "0")

        let error = AgentCaptureQueryTelemetry.observation(
            toolName: "read_dictation",
            result: toolTextResult("Invalid filename: ../secret", isError: true),
            clientFamily: "unknown-client"
        )
        XCTAssertEqual(error.result, "error")
        XCTAssertEqual(error.sourceCountBucket, "0")
        XCTAssertEqual(error.clientFamily, "unknown")
    }

    func testAnalyticsPreferenceReadsAppPlistWhenStandardDefaultsUnset() throws {
        let tempDir = makeTempDir()
        defer { removeTempDir(tempDir) }

        let preferencesURL = tempDir.appendingPathComponent("com.justinbetker.draft.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["observability-anonymous-analytics-enabled": false],
            format: .xml,
            options: 0
        )
        try data.write(to: preferencesURL)

        let suiteName = "AgentCaptureQueryTelemetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AgentCaptureQueryTelemetry.isAnalyticsEnabled(userDefaults: defaults, preferencesURL: preferencesURL))
    }

    private func toolTextResult(_ text: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }
}
