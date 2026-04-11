import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AgentOutputTests: XCTestCase {

    func testRemoveLegacyAgentHelperFilesDeletesLegacyDocsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentURL = root.appendingPathComponent("AGENT.md")
        let claudeURL = root.appendingPathComponent("CLAUDE.md")
        let indexURL = root.appendingPathComponent("transcripted.json")

        try "agent".write(to: agentURL, atomically: true, encoding: .utf8)
        try "claude".write(to: claudeURL, atomically: true, encoding: .utf8)
        try "{}".write(to: indexURL, atomically: true, encoding: .utf8)

        AgentOutput.removeLegacyAgentHelperFiles(from: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
    }
}
