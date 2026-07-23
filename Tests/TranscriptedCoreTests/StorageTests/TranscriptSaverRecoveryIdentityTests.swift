import Foundation
import XCTest
@testable import TranscriptedCore

final class TranscriptSaverRecoveryIdentityTests: XCTestCase {
    func testFindsStableTranscriptIdentityWithoutFollowingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptSaverRecoveryIdentityTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let transcriptId = UUID()
        let expectedURL = root.appendingPathComponent("committed.md")
        let unrelatedURL = root.appendingPathComponent("unrelated.md")
        let outsideURL = root.deletingLastPathComponent().appendingPathComponent(
            "outside-\(UUID().uuidString).md"
        )
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        try syntheticTranscript(id: UUID()).write(
            to: unrelatedURL,
            atomically: true,
            encoding: .utf8
        )
        try syntheticTranscript(id: transcriptId).write(
            to: expectedURL,
            atomically: true,
            encoding: .utf8
        )
        try syntheticTranscript(id: transcriptId).write(
            to: outsideURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.md"),
            withDestinationURL: outsideURL
        )

        XCTAssertEqual(
            TranscriptSaver.existingTranscriptURL(in: root, transcriptId: transcriptId)?
                .resolvingSymlinksInPath(),
            expectedURL.resolvingSymlinksInPath()
        )
        XCTAssertNil(
            TranscriptSaver.existingTranscriptURL(in: root, transcriptId: UUID())
        )
    }

    private func syntheticTranscript(id: UUID) -> String {
        """
        ---
        transcript_id: \(id.uuidString)
        ---
        Synthetic recovery fixture.
        """
    }
}
