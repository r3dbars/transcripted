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

    func testAppChoiceResolvesToNemotronUnlessTheAppSaysOtherwise() {
        XCTAssertEqual(
            CLIDiarization.resolvedEngine(choice: "app", environment: [:], storedPreference: nil),
            "nemotron"
        )
        XCTAssertEqual(
            CLIDiarization.resolvedEngine(
                choice: "app",
                environment: [:],
                storedPreference: "pyannote"
            ),
            "pyannote"
        )
        XCTAssertEqual(
            CLIDiarization.resolvedEngine(
                choice: "app",
                environment: [CLIDiarization.environmentKey: "NEMOTRON"],
                storedPreference: "pyannote"
            ),
            "nemotron"
        )
        XCTAssertEqual(
            CLIDiarization.resolvedEngine(choice: "pyannote", environment: [:], storedPreference: "nemotron"),
            "pyannote"
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

    func testImportAudioAndDiarizeResolveTheSameEngine() {
        XCTAssertEqual(CLIDiarization.appDefaultsDomain, SpeakerVoiceprintSelection.appDefaultsDomain)
        XCTAssertEqual(CLIDiarization.preferenceKey, DiarizationBackend.preferenceKey)
        XCTAssertEqual(CLIDiarization.environmentKey, DiarizationBackend.environmentKey)
        XCTAssertEqual(
            MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: nil).rawValue,
            CLIDiarization.resolvedEngine(choice: "app", environment: [:], storedPreference: nil)
        )
        let stored: [String: Any] = [MeetingImportDiarization.preferenceKey: "pyannote"]
        XCTAssertEqual(
            MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: stored).rawValue,
            CLIDiarization.resolvedEngine(choice: "app", environment: [:], storedPreference: "pyannote")
        )
    }
}
#endif
