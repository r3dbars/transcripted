import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class LegacyAgentFolderCleanupTests: XCTestCase {
    func testRemoveLegacyHelperFilesDeletesLegacyDocsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyAgentFolderCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentURL = root.appendingPathComponent("AGENT.md")
        let claudeURL = root.appendingPathComponent("CLAUDE.md")
        let transcriptURL = root.appendingPathComponent("Meeting with Alex.md")

        try "agent".write(to: agentURL, atomically: true, encoding: .utf8)
        try "claude".write(to: claudeURL, atomically: true, encoding: .utf8)
        try "transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        LegacyAgentFolderCleanup.removeLegacyHelperFiles(from: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
    }
}
