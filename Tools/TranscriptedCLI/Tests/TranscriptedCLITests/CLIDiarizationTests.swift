import ArgumentParser
import XCTest
@testable import transcripted_cli

/// Promises of every CLI diarization path (`import-audio`, `diarize`, `batch`):
///   - the default engine is `app`, which resolves to Nemotron like the Mac app;
///   - pyannote stays available only behind `--diarization-engine pyannote`;
///   - all three commands share one windowing snapshot, the app-tuned
///     10.0 s / 0.266 step that yields 1431 windows on a 3806 s file (not
///     FluidAudio's 0.2 step, which yields 1903).
final class CLIDiarizationTests: XCTestCase {
    func testDiarizeAndBatchDefaultToTheAppEngine() throws {
        XCTAssertEqual(try Diarize.parse(["memo.wav"]).diarizationEngine, "app")
        XCTAssertEqual(try Batch.parse(["clips"]).diarizationEngine, "app")
        XCTAssertEqual(CLIDiarization.defaultEngineChoice, "app")
        for engine in CLIDiarization.engineChoices {
            XCTAssertEqual(try Diarize.parse(["memo.wav", "--diarization-engine", engine]).diarizationEngine, engine)
            XCTAssertEqual(try Batch.parse(["clips", "--diarization-engine", engine]).diarizationEngine, engine)
        }
        XCTAssertThrowsError(try Diarize.parse(["memo.wav", "--diarization-engine", "sortformer"]))
        XCTAssertThrowsError(try Batch.parse(["clips", "--diarization-engine", "sortformer"]))
    }

    func testAppChoiceResolvesToNemotronUnlessTheAppSaysOtherwise() throws {
        XCTAssertEqual(
            try CLIDiarization.resolvedEngine(choice: "app", environment: [:], storedPreference: nil),
            "nemotron"
        )
        XCTAssertEqual(
            try CLIDiarization.resolvedEngine(
                choice: "app",
                environment: [:],
                storedPreference: "pyannote"
            ),
            "pyannote"
        )
        XCTAssertEqual(
            try CLIDiarization.resolvedEngine(
                choice: "app",
                environment: [CLIDiarization.environmentKey: "NEMOTRON"],
                storedPreference: "pyannote"
            ),
            "nemotron"
        )
        XCTAssertEqual(
            try CLIDiarization.resolvedEngine(choice: "pyannote", environment: [:], storedPreference: "nemotron"),
            "pyannote"
        )
    }

    func testUnknownEngineIsAClearErrorInsteadOfSilentNemotron() {
        XCTAssertThrowsError(
            try CLIDiarization.resolvedEngine(choice: "sortformer", environment: [:], storedPreference: nil)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("sortformer"), message)
            XCTAssertTrue(message.contains("app"), message)
            XCTAssertTrue(message.contains("nemotron"), message)
            XCTAssertTrue(message.contains("pyannote"), message)
            XCTAssertFalse(message.contains("falling back"), message)
        }
        XCTAssertThrowsError(
            try CLIDiarization.resolvedEngine(choice: "whisper", environment: [:], storedPreference: nil)
        )
    }

    func testThinAudioBuildFallsBackToPyannoteWhenNemotronIsUnavailable() throws {
        let fallback = try CLIDiarization.runnableEngine(
            choice: "app", environment: [:], storedPreference: nil, nemotronAvailable: false
        )
        XCTAssertEqual(fallback.engine, "pyannote")
        let note = try XCTUnwrap(fallback.fallbackNote)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("nemotron"), note)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("pyannote"), note)

        let explicitPyannote = try CLIDiarization.runnableEngine(
            choice: "pyannote", environment: [:], storedPreference: "nemotron", nemotronAvailable: false
        )
        XCTAssertEqual(explicitPyannote.engine, "pyannote")
        XCTAssertNil(explicitPyannote.fallbackNote)

        let available = try CLIDiarization.runnableEngine(
            choice: "app", environment: [:], storedPreference: nil, nemotronAvailable: true
        )
        XCTAssertEqual(available.engine, "nemotron")
        XCTAssertNil(available.fallbackNote)
    }

    func testExplicitNemotronDoesNotFallBackWhenUnavailable() {
        XCTAssertThrowsError(
            try CLIDiarization.runnableEngine(
                choice: "nemotron", environment: [:], storedPreference: nil, nemotronAvailable: false
            )
        ) { error in
            XCTAssertTrue(error is CLIDiarization.NemotronUnavailable)
        }
    }

    func testExplicitNemotronErrorsWhenPyannoteLoadedInstead() {
        XCTAssertThrowsError(
            try CLIDiarization.acceptLoadedEngine(
                requested: "nemotron", actual: "pyannote", choice: "nemotron"
            )
        ) { error in
            XCTAssertEqual(
                error as? CLIDiarization.RequestedEngineUnavailable,
                CLIDiarization.RequestedEngineUnavailable(requested: "nemotron", actual: "pyannote")
            )
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("nemotron"), message)
            XCTAssertTrue(message.contains("pyannote"), message)
            XCTAssertFalse(message.contains("falling back"), message)
        }
    }

    func testDefaultPathNotesWhenNemotronFallsBackToPyannote() throws {
        let fallback = try CLIDiarization.acceptLoadedEngine(
            requested: "nemotron", actual: "pyannote", choice: "app"
        )
        XCTAssertEqual(fallback.engine, "pyannote")
        let note = try XCTUnwrap(fallback.fallbackNote)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("nemotron"), note)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("pyannote"), note)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("falling back"), note)

        let matched = try CLIDiarization.acceptLoadedEngine(
            requested: "nemotron", actual: "nemotron", choice: "app"
        )
        XCTAssertEqual(matched.engine, "nemotron")
        XCTAssertNil(matched.fallbackNote)

        let explicitPyannote = try CLIDiarization.acceptLoadedEngine(
            requested: "pyannote", actual: "pyannote", choice: "pyannote"
        )
        XCTAssertEqual(explicitPyannote.engine, "pyannote")
        XCTAssertNil(explicitPyannote.fallbackNote)
    }

    func testConfigSelectsPyannoteWithoutRequiringTheEngineFlag() throws {
        XCTAssertEqual(try Diarize.parse(["memo.wav", "--config", "knobs.json"]).diarizationEngine, "app")
        XCTAssertEqual(try Batch.parse(["clips", "--config", "knobs.json"]).diarizationEngine, "app")
        XCTAssertEqual(
            try Diarize.parse(["memo.wav", "--diarization-engine", "pyannote", "--config", "knobs.json"]).diarizationEngine,
            "pyannote"
        )
        XCTAssertEqual(
            try Batch.parse(["clips", "--diarization-engine", "pyannote", "--config", "knobs.json"]).diarizationEngine,
            "pyannote"
        )

        let fromDefault = try CLIDiarization.applyConfigSelection(
            choice: "app", engine: "nemotron", hasConfig: true
        )
        XCTAssertEqual(fromDefault.engine, "pyannote")
        let note = try XCTUnwrap(fromDefault.fallbackNote)
        XCTAssertTrue(note.contains("--config"), note)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("pyannote"), note)

        let alreadyPyannote = try CLIDiarization.applyConfigSelection(
            choice: "pyannote", engine: "pyannote", hasConfig: true
        )
        XCTAssertEqual(alreadyPyannote.engine, "pyannote")
        XCTAssertNil(alreadyPyannote.fallbackNote)

        let noConfig = try CLIDiarization.applyConfigSelection(
            choice: "nemotron", engine: "nemotron", hasConfig: false
        )
        XCTAssertEqual(noConfig.engine, "nemotron")
        XCTAssertNil(noConfig.fallbackNote)
    }

    func testExplicitNemotronRejectsAPyannoteConfigFile() {
        XCTAssertThrowsError(
            try CLIDiarization.applyConfigSelection(
                choice: "nemotron", engine: "nemotron", hasConfig: true
            )
        ) { error in
            XCTAssertEqual(error as? CLIDiarization.ConfigConflictsWithNemotron, .init())
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("--config"), message)
            XCTAssertTrue(message.contains("nemotron"), message)
            XCTAssertTrue(message.contains("pyannote"), message)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("using pyannote"), message)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("falling back"), message)
        }

        XCTAssertThrowsError(
            try Diarize.parse(["memo.wav", "--diarization-engine", "nemotron", "--config", "knobs.json"])
        ) { error in
            XCTAssertTrue(
                error is CLIDiarization.ConfigConflictsWithNemotron
                    || String(describing: error).localizedCaseInsensitiveContains("nemotron"),
                String(describing: error)
            )
        }
        XCTAssertThrowsError(
            try Batch.parse(["clips", "--diarization-engine", "nemotron", "--config", "knobs.json"])
        )
    }

    func testEveryCLIPathSharesTheAppTunedPyannoteWindowing() {
        XCTAssertEqual(ImportAudio.sharedDiarizationWindowing, Diarize.sharedDiarizationWindowing)
        XCTAssertEqual(Diarize.sharedDiarizationWindowing, Batch.sharedDiarizationWindowing)

        let windowing = Diarize.sharedDiarizationWindowing
        XCTAssertEqual(windowing.windowDuration, 10.0)
        XCTAssertEqual(windowing.segmentationStepRatio, 0.266, accuracy: 1e-12)
        XCTAssertEqual(windowing.nemotronSliceSeconds, 10.0)
        // Same audio, two step ratios: the tester's 1431 vs 1903 window counts.
        XCTAssertEqual(windowing.pyannoteWindowCount(audioDurationSeconds: 3806), 1431)
        XCTAssertEqual(
            CLIDiarization.windowCount(audioDurationSeconds: 3806, windowDuration: 10.0, stepRatio: 0.2),
            1903
        )
    }
}

#if TRANSCRIPTEDCLI_WITH_DIARIZATION && canImport(FluidAudio)
import FluidAudio

extension CLIDiarizationTests {
    func testDiarizeDefaultConfigUsesTheSharedAppTunedWindowing() {
        let config = DiarizerCompatibility.legacyDefaultConfig
        let windowing = CLIDiarization.windowing
        XCTAssertEqual(config.windowDuration, windowing.windowDuration)
        XCTAssertEqual(config.segmentationStepRatio, windowing.segmentationStepRatio, accuracy: 1e-12)
        XCTAssertEqual(config.segmentationStepRatio, 0.266, accuracy: 1e-12)
    }
}
#endif

#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore) && canImport(FluidAudio)
import FluidAudio
import TranscriptedCore

extension CLIDiarizationTests {
    func testSharedWindowingMatchesTheAppTunedOfflineConfig() {
        let app = FluidAudioCompatibility.tunedOfflineDiarizerConfig()
        let windowing = CLIDiarization.windowing
        XCTAssertEqual(app.windowDuration, windowing.windowDuration)
        XCTAssertEqual(app.segmentationStepRatio, windowing.segmentationStepRatio, accuracy: 1e-12)

        let diarize = DiarizerCompatibility.legacyDefaultConfig
        XCTAssertEqual(diarize.windowDuration, app.windowDuration)
        XCTAssertEqual(diarize.segmentationStepRatio, app.segmentationStepRatio, accuracy: 1e-12)
        XCTAssertEqual(diarize.Fa, app.Fa)
        XCTAssertEqual(diarize.minGapDuration, app.minGapDuration)
    }

    func testImportAudioAndDiarizeResolveTheSameEngine() throws {
        XCTAssertEqual(CLIDiarization.appDefaultsDomain, SpeakerVoiceprintSelection.appDefaultsDomain)
        XCTAssertEqual(CLIDiarization.preferenceKey, DiarizationBackend.preferenceKey)
        XCTAssertEqual(CLIDiarization.environmentKey, DiarizationBackend.environmentKey)
        XCTAssertEqual(CLIDiarization.windowing.nemotronSliceSeconds, DiarizationBackend.nemotronSliceSeconds)
        XCTAssertEqual(
            try MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: nil).rawValue,
            try CLIDiarization.resolvedEngine(choice: "app", environment: [:], storedPreference: nil)
        )
        let stored: [String: Any] = [MeetingImportDiarization.preferenceKey: "pyannote"]
        XCTAssertEqual(
            try MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: stored).rawValue,
            try CLIDiarization.resolvedEngine(choice: "app", environment: [:], storedPreference: "pyannote")
        )
    }
}
#endif
