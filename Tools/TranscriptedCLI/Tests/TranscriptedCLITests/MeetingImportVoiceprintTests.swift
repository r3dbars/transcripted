#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import Foundation
import XCTest
import TranscriptedCore
@testable import transcripted_cli

/// Promises of `import-audio`'s voiceprint choice:
///   - `--speaker-embedder app` (the default) picks the same model and speaker
///     database as the app for every row of the shared table
///     (Tests/Fixtures/speaker-voiceprint-resolution.json, also asserted by Core and
///     the app's fast tests), including ReDimNet2 by default;
///   - the database it reads is the one that model's people live in, and matching
///     uses that model's naming bars;
///   - an explicit model never falls back silently;
///   - the state folder follows the app's TRANSCRIPTED_CONTAINER_DIR override.
/// Everything runs against scratch folders; nothing touches real app data.
final class MeetingImportVoiceprintTests: XCTestCase {
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

    private let buildKey = SpeakerVoiceprintSelection.buildKey(bundleVersion: "100", operatingSystemVersion: "macOS 26.1")

    func testAppChoiceMatchesTheAppForEveryRowOfTheSharedTable() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/speaker-voiceprint-resolution.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: fixture))
        XCTAssertFalse(table.cases.isEmpty)
        for row in table.cases {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("Transcripted.app/Contents/Resources")
            for raw in row.present {
                try installModel(SpeakerVoiceprintSelection.Model(rawValue: raw)!, resources: resources)
            }
            let plan = MeetingImportModels.voiceprintPlan(
                choice: "app",
                environment: row.env.map { [SpeakerVoiceprintSelection.environmentKey: $0] } ?? [:],
                appDefaults: appDefaults(stored: row.stored, failed: row.failed),
                resourceDirectories: [resources], homeDirectory: root.appendingPathComponent("home"),
                stateDirectory: root.appendingPathComponent("state"), appBuildKey: .some(buildKey)
            )
            XCTAssertEqual(plan.model.rawValue, row.model, row.name)
            XCTAssertEqual(plan.resolution.embedderIdentifier, row.identifier, row.name)
            XCTAssertEqual(plan.resolution.fallback?.rawValue, row.fallback, row.name)
            XCTAssertEqual(plan.databaseURL.lastPathComponent, row.database, row.name)
            XCTAssertEqual(plan.databaseURL.deletingLastPathComponent().lastPathComponent, "state", row.name)

            // Loading: the database read and the bars used come from the same model.
            let voiceprint = try MeetingImportModels.voiceprint(choice: "app", plan: plan, load: fakeLoader)
            XCTAssertEqual(voiceprint.databaseURL.lastPathComponent, row.database, row.name)
            XCTAssertEqual(voiceprint.embedder?.identifier, row.identifier, row.name)
            XCTAssertEqual(voiceprint.thresholds, row.identifier == "redimnet2-b4" ? .reDimNet2B4
                           : row.identifier == "eres2net" ? .eRes2Net : .weSpeaker, row.name)
        }
    }

    func testDefaultIsReDimNet2AndItsDatabaseWithNoAppPreference() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // The shared FluidAudio cache is enough, like a dev build of the app.
        let home = root.appendingPathComponent("home")
        let cached = home.appendingPathComponent("Library/Application Support/FluidAudio/Models/redimnet2-b4-slim/Model.mlmodelc")
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        let plan = MeetingImportModels.voiceprintPlan(
            choice: "app", environment: [:], appDefaults: nil, resourceDirectories: [],
            homeDirectory: home, stateDirectory: root.appendingPathComponent("state"), appBuildKey: .some(nil)
        )
        XCTAssertEqual(plan.model, .reDimNet2)
        XCTAssertEqual(plan.modelURL?.standardizedFileURL, cached.standardizedFileURL)
        XCTAssertEqual(plan.databaseURL.lastPathComponent, "speakers_redimnet2-b4.sqlite")
    }

    func testExplicitModelNeverFallsBackSilently() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        let home = root.appendingPathComponent("home")
        let state = root.appendingPathComponent("state")
        for model in ["redimnet2", "eres2net"] {
            let missing = MeetingImportModels.voiceprintPlan(
                choice: model, environment: [:], appDefaults: nil, resourceDirectories: [resources],
                homeDirectory: home, stateDirectory: state, appBuildKey: .some(buildKey))
            XCTAssertThrowsError(try MeetingImportModels.voiceprint(choice: model, plan: missing, load: fakeLoader), model)
        }
        // Present but unloadable: an error, not WeSpeaker.
        try installModel(.reDimNet2, resources: resources)
        let present = MeetingImportModels.voiceprintPlan(
            choice: "redimnet2", environment: [SpeakerVoiceprintSelection.environmentKey: "wespeaker"],
            appDefaults: appDefaults(stored: "eres2net", failed: ["redimnet2-b4"]), resourceDirectories: [resources],
            homeDirectory: home, stateDirectory: state, appBuildKey: .some(buildKey))
        XCTAssertEqual(present.model, .reDimNet2, "explicit choice wins over env and app preference")
        XCTAssertEqual(present.resolution.embedderIdentifier, "redimnet2-b4", "explicit choice ignores the app's failure memory")
        XCTAssertThrowsError(try MeetingImportModels.voiceprint(choice: "redimnet2", plan: present, load: { _, _ in nil }))
        // Explicit WeSpeaker reads speakers.sqlite.
        let wespeaker = MeetingImportModels.voiceprintPlan(
            choice: "wespeaker", environment: [:], appDefaults: nil, resourceDirectories: [resources],
            homeDirectory: home, stateDirectory: state, appBuildKey: .some(buildKey))
        XCTAssertEqual(try MeetingImportModels.voiceprint(choice: "wespeaker", plan: wespeaker, load: fakeLoader).databaseURL.lastPathComponent,
                       "speakers.sqlite")
    }

    func testAppDefaultThatCannotLoadFallsBackToWeSpeakerLikeTheApp() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        try installModel(.reDimNet2, resources: resources)
        let plan = MeetingImportModels.voiceprintPlan(
            choice: "app", environment: [:], appDefaults: nil, resourceDirectories: [resources],
            homeDirectory: root, stateDirectory: root.appendingPathComponent("state"), appBuildKey: .some(buildKey))
        let voiceprint = try MeetingImportModels.voiceprint(choice: "app", plan: plan, load: { _, _ in nil })
        XCTAssertNil(voiceprint.embedder)
        XCTAssertEqual(voiceprint.databaseURL.lastPathComponent, "speakers.sqlite")
        XCTAssertEqual(voiceprint.thresholds, .weSpeaker)
    }

    func testStateFolderFollowsTheAppContainerOverride() {
        XCTAssertEqual(MeetingImportModels.appStateDirectory(environment: ["TRANSCRIPTED_CONTAINER_DIR": "/tmp/tx-container "]).path,
                       "/tmp/tx-container/state")
        let standard = CoreStoragePaths.default.speakerDB.deletingLastPathComponent()
        XCTAssertEqual(MeetingImportModels.appStateDirectory(environment: ["TRANSCRIPTED_CONTAINER_DIR": "relative/path"]), standard)
        XCTAssertEqual(MeetingImportModels.appStateDirectory(environment: [:]), standard)
        // Library-only overrides move output, never the saved people.
        XCTAssertEqual(MeetingImportModels.appStateDirectory(environment: ["TRANSCRIPTED_DATA_DIR": "/tmp/data", "TRANSCRIPTED_MEETINGS_DIR": "/tmp/m"]), standard)
    }

    func testMissingReDimNet2DatabaseExplainsTheMigration() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let voiceprint = MeetingImportVoiceprint(
            model: .reDimNet2, embedder: FakeEmbedder(identifier: "redimnet2-b4", thresholds: .reDimNet2B4),
            databaseURL: state.appendingPathComponent("speakers_redimnet2-b4.sqlite"), note: nil)
        XCTAssertEqual(voiceprint.missingDatabaseReason(), "there's no saved speaker database for ReDimNet2")
        FileManager.default.createFile(atPath: state.appendingPathComponent("speakers.sqlite").path, contents: Data())
        XCTAssertTrue(voiceprint.missingDatabaseReason().contains("open Transcripted once"))
    }

    func testDatabaseFromAnotherModelIsDetected() {
        func profile(_ size: Int) -> SpeakerProfile {
            SpeakerProfile(id: UUID(), displayName: "Fixture", nameSource: NameSource.userManual,
                           embedding: [Float](repeating: 0.1, count: size), firstSeen: .distantPast,
                           lastSeen: .distantPast, callCount: 1, confidence: 0.5, disputeCount: 0)
        }
        let redimnet = MeetingImportVoiceprint(
            model: .reDimNet2, embedder: FakeEmbedder(identifier: "redimnet2-b4", thresholds: .reDimNet2B4),
            databaseURL: URL(fileURLWithPath: "/tmp/x.sqlite"), note: nil)
        let wespeaker = MeetingImportVoiceprint(model: .weSpeaker, embedder: nil,
                                                databaseURL: URL(fileURLWithPath: "/tmp/y.sqlite"), note: nil)
        XCTAssertEqual(MeetingImportVoiceprint.dimensionMismatch(profiles: [profile(256)], voiceprint: redimnet), "256-dimension")
        XCTAssertNil(MeetingImportVoiceprint.dimensionMismatch(profiles: [profile(192)], voiceprint: redimnet))
        XCTAssertNil(MeetingImportVoiceprint.dimensionMismatch(profiles: [profile(256)], voiceprint: wespeaker))
        XCTAssertEqual(MeetingImportVoiceprint.dimensionMismatch(profiles: [profile(192)], voiceprint: wespeaker), "192-dimension")
        XCTAssertNil(MeetingImportVoiceprint.dimensionMismatch(profiles: [], voiceprint: redimnet))
    }

    // MARK: - Helpers

    private func fakeLoader(_ model: SpeakerVoiceprintSelection.Model, _ url: URL) -> (any SpeakerSegmentEmbedder)? {
        switch model {
        case .weSpeaker: return nil
        case .reDimNet2: return FakeEmbedder(identifier: "redimnet2-b4", thresholds: .reDimNet2B4)
        case .eRes2Net: return FakeEmbedder(identifier: "eres2net", thresholds: .eRes2Net)
        }
    }

    private func appDefaults(stored: String?, failed: [String]) -> [String: Any] {
        var defaults: [String: Any] = [:]
        if let stored { defaults[SpeakerVoiceprintSelection.preferenceKey] = stored }
        if !failed.isEmpty {
            defaults[SpeakerVoiceprintSelection.loadFailuresKey] = Dictionary(uniqueKeysWithValues: failed.map { ($0, buildKey) })
        }
        return defaults
    }

    private func installModel(_ model: SpeakerVoiceprintSelection.Model, resources: URL) throws {
        let directory = model == .reDimNet2 ? "redimnet2-voiceprint" : "eres2net-embedding"
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent(directory).appendingPathComponent("Model.mlmodelc"),
            withIntermediateDirectories: true)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cli-voiceprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct FakeEmbedder: SpeakerSegmentEmbedder {
    let identifier: String
    let thresholds: SpeakerEmbeddingThresholds
    var dimension: Int { 192 }
    func embed(samples: [Float], sampleRate: Int) -> [Float]? { nil }
}
#endif
