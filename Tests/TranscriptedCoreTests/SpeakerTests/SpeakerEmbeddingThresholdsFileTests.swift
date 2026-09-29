import XCTest
@testable import TranscriptedCore

/// A new voiceprint model's cosine bars come from a calibration file. Promises:
/// the file loads to exactly the values it holds, in snake_case or camelCase, with
/// or without provenance around it; a missing or impossible value is an error,
/// never a silent fallback to another model's bars; and the loaded bars are the
/// ones the pipeline uses when that model is injected.
@available(macOS 14.0, *)
final class SpeakerEmbeddingThresholdsFileTests: XCTestCase {

    private let calibrated = SpeakerEmbeddingThresholds(
        matchOneSegment: 0.61, matchFewSegments: 0.53, matchManySegments: 0.47,
        ghostMergeFloor: 0.44, consolidation: 0.58, absorb: 0.46, microAbsorb: 0.39,
        perSegmentSplit: 0.41, knownProfileConflict: 0.48)

    private let snakeCaseJSON = """
    {"match_one_segment": 0.61, "match_few_segments": 0.53, "match_many_segments": 0.47,
     "ghost_merge_floor": 0.44, "consolidation": 0.58, "absorb": 0.46, "micro_absorb": 0.39,
     "per_segment_split": 0.41, "known_profile_conflict": 0.48}
    """

    private func decode(_ json: String) throws -> SpeakerEmbeddingThresholds {
        try SpeakerEmbeddingThresholds.decode(jsonData: Data(json.utf8))
    }

    private func assertFileError(_ json: String, mentions word: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), file: file, line: line) { error in
            guard let fileError = error as? SpeakerEmbeddingThresholdsFileError else {
                return XCTFail("expected SpeakerEmbeddingThresholdsFileError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(fileError.message.contains(word), "\(fileError.message) should mention \(word)",
                          file: file, line: line)
        }
    }

    func testSnakeCaseCalibrationFileLoadsExactlyItsValues() throws {
        XCTAssertEqual(try decode(snakeCaseJSON), calibrated)
    }

    func testCamelCaseCalibrationFileLoadsExactlyItsValues() throws {
        let json = """
        {"matchOneSegment": 0.61, "matchFewSegments": 0.53, "matchManySegments": 0.47,
         "ghostMergeFloor": 0.44, "consolidation": 0.58, "absorb": 0.46, "microAbsorb": 0.39,
         "perSegmentSplit": 0.41, "knownProfileConflict": 0.48}
        """
        XCTAssertEqual(try decode(json), calibrated)
    }

    func testThresholdsNestedBesideProvenanceLoad() throws {
        let json = """
        {"model_id": "candidate-a", "matched_to": "wespeaker",
         "false_accept_rates": {"match_one_segment": 0.001},
         "thresholds": \(snakeCaseJSON)}
        """
        XCTAssertEqual(try decode(json), calibrated)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = snakeCaseJSON.replacingOccurrences(of: "{", with: "{\"notes\": \"eer 1.2%\", ")
        XCTAssertEqual(try decode(json), calibrated)
    }

    func testMissingFieldIsAnErrorNamingIt() {
        let json = snakeCaseJSON.replacingOccurrences(of: "\"micro_absorb\": 0.39,", with: "")
        assertFileError(json, mentions: "microAbsorb")
    }

    func testValueOutsideCosineRangeIsAnError() {
        let json = snakeCaseJSON.replacingOccurrences(of: "\"absorb\": 0.46", with: "\"absorb\": 1.5")
        assertFileError(json, mentions: "absorb")
    }

    func testNonNumericValueIsAnError() {
        let json = snakeCaseJSON.replacingOccurrences(of: "\"ghost_merge_floor\": 0.44", with: "\"ghost_merge_floor\": \"0.44\"")
        assertFileError(json, mentions: "ghostMergeFloor")
    }

    func testNonObjectFileIsAnError() {
        assertFileError("[0.61, 0.53]", mentions: "JSON object")
        assertFileError("{\"thresholds\": 0.5}", mentions: "thresholds")
    }

    /// A file written from a preset loads back to that exact preset, so a
    /// calibration that lands on today's values changes nothing.
    func testPresetWrittenToFileLoadsBackUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        for preset in [SpeakerEmbeddingThresholds.weSpeaker, .eRes2Net] {
            let data = try encoder.encode(preset)
            XCTAssertEqual(try SpeakerEmbeddingThresholds.decode(jsonData: data), preset)
        }
    }

    func testLoadReadsAFileFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thresholds-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("thresholds.json")
        try Data(snakeCaseJSON.utf8).write(to: url)
        XCTAssertEqual(try SpeakerEmbeddingThresholds.load(contentsOf: url), calibrated)
        XCTAssertThrowsError(try SpeakerEmbeddingThresholds.load(contentsOf: dir.appendingPathComponent("missing.json")))
    }

    /// The loaded bars reach the pipeline through the injected embedder, the same
    /// seam the presets use.
    func testInjectedEmbedderCarriesFileThresholdsIntoDiarization() async throws {
        let thresholds = try decode(snakeCaseJSON)
        let plan = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: 8000, maxSamples: 480_000, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: nil)
        let embedder = try CoreMLSpeakerSegmentEmbedder(
            identifier: "candidate-a", dimension: 4, thresholds: thresholds, plan: plan,
            predict: { _ in [1, 0, 0, 0] })
        let service = await MainActor.run { DiarizationService(segmentEmbedder: embedder, backend: .nemotron) }
        XCTAssertEqual(service.activeSpeakerThresholds, calibrated)
    }
}
