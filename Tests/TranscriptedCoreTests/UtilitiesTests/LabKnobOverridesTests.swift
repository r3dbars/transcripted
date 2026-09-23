import XCTest
@testable import TranscriptedCore

/// Coverage for `LabKnobOverrides`, the read-once hill-climb lab override table.
/// The process-wide table is read once from `TRANSCRIPTED_LAB_KNOBS_FILE`, so
/// these tests drive the internal `parse` / `load` / `resolve*` functions with
/// their own data instead of mutating the process environment.
final class LabKnobOverridesTests: XCTestCase {

    private func table(_ json: String) -> [String: LabKnobValue] {
        return LabKnobOverrides.parse(Data(json.utf8))
    }

    // MARK: - No env var

    func testNoEnvironmentVariableReturnsDefaults() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment[LabKnobOverrides.environmentKey] != nil,
            "TRANSCRIPTED_LAB_KNOBS_FILE is set for this test process"
        )
        XCTAssertEqual(LabKnobOverrides.double("diarization.clustering_threshold", default: 0.6), 0.6)
        XCTAssertEqual(LabKnobOverrides.float("speaker.cluster.small_cluster_absorb.eres2net", default: 0.55), 0.55)
        XCTAssertEqual(LabKnobOverrides.int("some.int.knob", default: 24), 24)
        XCTAssertEqual(LabKnobOverrides.bool("some.bool.knob", default: true), true)
        XCTAssertTrue(LabKnobOverrides.activeOverrideIDs.isEmpty)
        XCTAssertTrue(LabKnobOverrides.activeOverrides.isEmpty)
    }

    func testEmptyTableReturnsDefaults() {
        let empty: [String: LabKnobValue] = [:]
        XCTAssertEqual(LabKnobOverrides.resolveDouble(id: "a", default: 1.5, in: empty), 1.5)
        XCTAssertEqual(LabKnobOverrides.resolveFloat(id: "a", default: 0.88, in: empty), 0.88)
        XCTAssertEqual(LabKnobOverrides.resolveInt(id: "a", default: 7, in: empty), 7)
        XCTAssertEqual(LabKnobOverrides.resolveBool(id: "a", default: false, in: empty), false)
    }

    // MARK: - Valid file

    func testValidJSONOverridesEachType() {
        let parsed = table("""
        {"diarization.vbx_fa": 0.3, "speaker.cluster.same_voice_consolidation.eres2net": 0.7,
         "some.int.knob": 12, "some.bool.knob": false}
        """)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(LabKnobOverrides.resolveDouble(id: "diarization.vbx_fa", default: 0.25, in: parsed), 0.3)
        XCTAssertEqual(
            LabKnobOverrides.resolveFloat(id: "speaker.cluster.same_voice_consolidation.eres2net", default: 0.65, in: parsed),
            Float(0.7)
        )
        XCTAssertEqual(LabKnobOverrides.resolveInt(id: "some.int.knob", default: 24, in: parsed), 12)
        XCTAssertEqual(LabKnobOverrides.resolveBool(id: "some.bool.knob", default: true, in: parsed), false)
        // Ids not in the file keep their defaults.
        XCTAssertEqual(LabKnobOverrides.resolveDouble(id: "diarization.vbx_fb", default: 0.63, in: parsed), 0.63)
    }

    func testLoadReadsFileFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabKnobOverridesTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"diarization.clustering_threshold\": 0.55}".utf8).write(to: url)

        let loaded = LabKnobOverrides.load(contentsOf: url)
        XCTAssertEqual(loaded["diarization.clustering_threshold"], LabKnobValue.number(0.55))
        XCTAssertEqual(
            LabKnobOverrides.resolveDouble(id: "diarization.clustering_threshold", default: 0.6, in: loaded),
            0.55
        )
    }

    func testIntegerJSONValueWorksForDoubleKnob() {
        let parsed = table("{\"pipeline.utterance_merge.max_gap_seconds\": 2}")
        XCTAssertEqual(
            LabKnobOverrides.resolveDouble(id: "pipeline.utterance_merge.max_gap_seconds", default: 1.5, in: parsed),
            2.0
        )
    }

    // MARK: - Wrong type

    func testWrongTypeFallsBackToDefault() {
        let parsed = table("""
        {"num.as.bool": true, "bool.as.num": 1, "fractional.int": 2.5, "text": "0.7", "nested": {"a": 1}, "nothing": null}
        """)
        // Booleans never become numbers, and numbers never become booleans.
        XCTAssertEqual(LabKnobOverrides.resolveDouble(id: "num.as.bool", default: 0.6, in: parsed), 0.6)
        XCTAssertEqual(LabKnobOverrides.resolveFloat(id: "num.as.bool", default: 0.6, in: parsed), 0.6)
        XCTAssertEqual(LabKnobOverrides.resolveInt(id: "num.as.bool", default: 3, in: parsed), 3)
        XCTAssertEqual(LabKnobOverrides.resolveBool(id: "bool.as.num", default: false, in: parsed), false)
        // A fractional value is not an Int.
        XCTAssertEqual(LabKnobOverrides.resolveInt(id: "fractional.int", default: 24, in: parsed), 24)
        // Strings, objects, and null are dropped at parse time.
        XCTAssertNil(parsed["text"])
        XCTAssertNil(parsed["nested"])
        XCTAssertNil(parsed["nothing"])
        XCTAssertEqual(LabKnobOverrides.resolveDouble(id: "text", default: 0.6, in: parsed), 0.6)
        // The well-typed keys in the same file still load.
        XCTAssertEqual(parsed["num.as.bool"], LabKnobValue.bool(true))
        XCTAssertEqual(parsed["bool.as.num"], LabKnobValue.number(1))
    }

    // MARK: - Malformed file

    func testMalformedJSONYieldsNoOverrides() {
        XCTAssertTrue(table("{\"diarization.vbx_fa\": 0.3,").isEmpty)
        XCTAssertTrue(table("not json at all").isEmpty)
        XCTAssertTrue(table("").isEmpty)
    }

    func testNonObjectTopLevelYieldsNoOverrides() {
        XCTAssertTrue(table("[0.3, 0.4]").isEmpty)
    }

    func testMissingFileYieldsNoOverrides() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabKnobOverridesTests-missing-\(UUID().uuidString).json")
        XCTAssertTrue(LabKnobOverrides.load(contentsOf: url).isEmpty)
    }
}
