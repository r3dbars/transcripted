import Foundation
import XCTest
@testable import TranscriptedCore

/// Promises of the one voiceprint rule the app and the CLI share:
///   - every row of Tests/Fixtures/speaker-voiceprint-resolution.json resolves to
///     the listed model, embedder, database and fallback (the app and CLI tests
///     assert the same rows through their own wiring);
///   - the model ids it names are the real embedders' ids, so the database names
///     it hands out are the files those embedders' people live in.
final class SpeakerVoiceprintSelectionTests: XCTestCase {
    private struct Table: Decodable {
        struct Case: Decodable {
            let name: String
            let stored: String?
            let env: String?
            let present: [String]
            let failed: [String]
            let model: String
            let identifier: String?
            let database: String
            let fallback: String?
        }
        let cases: [Case]
    }

    func testEveryRowOfTheSharedTableResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/speaker-voiceprint-resolution.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        XCTAssertFalse(table.cases.isEmpty)
        for row in table.cases {
            let chosen = SpeakerVoiceprintSelection.effectiveModel(
                storedPreference: row.stored,
                environment: row.env.map { [SpeakerVoiceprintSelection.environmentKey: $0] } ?? [:]
            )
            let resolution = SpeakerVoiceprintSelection.resolve(
                chosen: chosen,
                modelFileIsPresent: { row.present.contains($0.rawValue) },
                failedOnThisBuild: { row.failed.contains($0) }
            )
            XCTAssertEqual(resolution.chosen.rawValue, row.model, row.name)
            XCTAssertEqual(resolution.embedderIdentifier, row.identifier, row.name)
            XCTAssertEqual(resolution.databaseFileName, row.database, row.name)
            XCTAssertEqual(resolution.fallback?.rawValue, row.fallback, row.name)
        }
    }

    func testModelIdsAreTheRealEmbeddersIds() {
        let unused = URL(fileURLWithPath: "/nonexistent/Model.mlmodelc")
        XCTAssertEqual(SpeakerVoiceprintSelection.Model.reDimNet2.embedderIdentifier, ReDimNet2Embedder.identifier)
        XCTAssertEqual(SpeakerVoiceprintSelection.Model.reDimNet2.embedderIdentifier,
                       ReDimNet2Embedder.configuration(modelURL: unused).identifier)
        XCTAssertEqual(SpeakerVoiceprintSelection.Model.eRes2Net.embedderIdentifier,
                       ERes2NetEmbedder.configuration(modelURL: unused).identifier)
        XCTAssertNil(SpeakerVoiceprintSelection.Model.weSpeaker.embedderIdentifier)
    }

    func testRecordedFailureOnlyCountsOnTheSameBuild() {
        let key = SpeakerVoiceprintSelection.buildKey(bundleVersion: "100", operatingSystemVersion: "macOS 26.1")
        let failures = ["redimnet2-b4": key]
        XCTAssertTrue(SpeakerVoiceprintSelection.failedOnThisBuild("redimnet2-b4", recordedFailures: failures, buildKey: key))
        XCTAssertFalse(SpeakerVoiceprintSelection.failedOnThisBuild(
            "redimnet2-b4", recordedFailures: failures,
            buildKey: SpeakerVoiceprintSelection.buildKey(bundleVersion: "101", operatingSystemVersion: "macOS 26.1")))
        XCTAssertEqual(SpeakerVoiceprintSelection.buildKey(bundleVersion: nil, operatingSystemVersion: "x"), "unknown|x")
    }
}
