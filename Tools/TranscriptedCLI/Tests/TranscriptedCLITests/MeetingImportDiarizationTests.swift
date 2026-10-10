#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import Foundation
import XCTest
import TranscriptedCore
@testable import transcripted_cli

/// Promises of `import-audio`'s diarization engine:
///   - `--diarization-engine app` (the default) picks the same engine the app
///     uses: Nemotron when nothing is set, the app's stored preference, or
///     `TRANSCRIPTED_DIARIZATION_BACKEND`;
///   - an explicit `nemotron` or `pyannote` wins over that;
///   - the bundle provider hands Nemotron its own folder, so a pyannote path
///     cannot make Nemotron fail-and-fall-back.
final class MeetingImportDiarizationTests: XCTestCase {
    func testAppChoiceDefaultsToTheAppNemotronEngine() {
        XCTAssertEqual(MeetingImportDiarization.hostDefault, .nemotron)
        XCTAssertEqual(
            MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: nil),
            .nemotron
        )
        XCTAssertEqual(
            MeetingImportDiarization.preferenceKey,
            "diarization-backend-preference"
        )
        XCTAssertEqual(
            MeetingImportDiarization.environmentKey,
            "TRANSCRIPTED_DIARIZATION_BACKEND"
        )
    }

    func testAppChoiceHonorsTheStoredPreferenceAndEnvironment() {
        let storedPyannote: [String: Any] = [MeetingImportDiarization.preferenceKey: "pyannote"]
        XCTAssertEqual(
            MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: storedPyannote),
            .pyannote
        )
        XCTAssertEqual(
            MeetingImportDiarization.backend(
                choice: "app",
                environment: [MeetingImportDiarization.environmentKey: "NEMOTRON"],
                appDefaults: storedPyannote
            ),
            .nemotron,
            "env wins over the stored preference, like the app"
        )
        XCTAssertEqual(
            MeetingImportDiarization.backend(
                choice: "app",
                environment: [MeetingImportDiarization.environmentKey: "garbage"],
                appDefaults: nil
            ),
            .nemotron,
            "garbage env falls through to the app default"
        )
    }

    func testExplicitEngineOverridesTheAppChoice() {
        let storedPyannote: [String: Any] = [MeetingImportDiarization.preferenceKey: "pyannote"]
        let envNemotron = [MeetingImportDiarization.environmentKey: "nemotron"]
        XCTAssertEqual(
            MeetingImportDiarization.backend(
                choice: "pyannote", environment: envNemotron, appDefaults: ["diarization-backend-preference": "nemotron"]
            ),
            .pyannote
        )
        XCTAssertEqual(
            MeetingImportDiarization.backend(choice: "nemotron", environment: [:], appDefaults: storedPyannote),
            .nemotron
        )
    }

    func testBundleProviderDoesNotHandThePyannoteFolderToNemotron() {
        let pyannote = URL(fileURLWithPath: "/tmp/offline-diarizer-models")
        let nemotron = URL(fileURLWithPath: "/tmp/nemotron-diarizer-models")
        let provider = MeetingImportDiarization.bundleProvider(pyannote: pyannote, nemotron: nemotron)
        XCTAssertEqual(provider("offline-diarizer-models"), pyannote)
        XCTAssertEqual(provider("nemotron-diarizer-models"), nemotron)
        XCTAssertNil(provider("eres2net-embedding"))
    }

    func testBundledNemotronUsesTheFlatAppLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Relocated.app/Contents/Resources")
        let bundle = resources.appendingPathComponent("nemotron-diarizer-models")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Nemotron3Diarizer_fast128.mlmodelc"),
            withIntermediateDirectories: true
        )
        try Data().write(to: bundle.appendingPathComponent("learnable_sil_emb.bin"))
        XCTAssertEqual(MeetingImportModels.bundledNemotronModels(in: [resources]), bundle)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("learnable_sil_emb.bin"))
        XCTAssertNil(MeetingImportModels.bundledNemotronModels(in: [resources]))
    }

    func testBundleProviderReturnsNilWhenNemotronIsNotLocal() {
        let pyannote = URL(fileURLWithPath: "/tmp/offline-diarizer-models")
        let provider = MeetingImportDiarization.bundleProvider(pyannote: pyannote, nemotron: nil)
        XCTAssertEqual(provider("offline-diarizer-models"), pyannote)
        XCTAssertNil(provider("nemotron-diarizer-models"),
                     "nil means cache-or-download, not 'load Nemotron from the pyannote folder'")
    }
}
#endif
