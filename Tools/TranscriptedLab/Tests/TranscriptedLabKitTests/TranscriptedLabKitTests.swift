import XCTest
@testable import TranscriptedLabKit

final class TranscriptedLabKitTests: XCTestCase {
    func testRuntimeAnalyzerScoresLatencyAndFallbackGate() throws {
        let root = try temporaryDirectory()
        let events = root.appendingPathComponent("events.jsonl")
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        var lines: [String] = []
        for _ in 0..<10 {
            lines.append(jsonLine(event: "transcription_complete", timestamp: timestamp, context: ["elapsed_s": 0.25, "rtf": 0.02]))
            lines.append(jsonLine(event: "dictation_recording_fast_start", timestamp: timestamp, context: ["start_ms": 100, "request_to_recording_ms": 120]))
            lines.append(jsonLine(event: "audio_samples_detected", timestamp: timestamp, context: ["start_to_first_sample_ms": 180]))
            lines.append(jsonLine(event: "dictation_stop_latency_measured", timestamp: timestamp, context: ["stop_to_paste_ms": 400, "stop_to_done_ms": 600]))
        }
        lines.append(jsonLine(event: "dictation_recording_retry", timestamp: timestamp, context: [:]))
        try (lines.joined(separator: "\n") + "\n").write(to: events, atomically: true, encoding: .utf8)

        let analysis = try RuntimeEventAnalyzer.analyze(
            eventsURL: events,
            windowHours: 24,
            minimumSamples: 10,
            strictGates: true,
            now: now
        )

        XCTAssertEqual(analysis.scorecard.overallScore, 97)
        XCTAssertEqual(analysis.scorecard.hardGateFailures.count, 1)
        XCTAssertEqual(analysis.metrics.first(where: { $0.key == "transcription.rtf.p95" })?.value, 0.02)
    }

    func testDictationAnalyzerRejectsUnstableOutput() throws {
        let root = try temporaryDirectory()
        let result = root.appendingPathComponent("run.jsonl")
        let rows = [
            #"{"record_type":"run_start","model_init_s":1.2}"#,
            #"{"record_type":"case_result","case_id":"short","audio_duration_s":10,"decode_s":0.2,"stop_to_text_s":0.3,"stop_to_delivery_s":0.5,"no_speech":false,"saved":true,"text_hash":"aaa"}"#,
            #"{"record_type":"case_result","case_id":"short","audio_duration_s":10,"decode_s":0.2,"stop_to_text_s":0.3,"stop_to_delivery_s":0.5,"no_speech":false,"saved":true,"text_hash":"bbb"}"#,
            #"{"record_type":"case_result","case_id":"silence_guardrail","audio_duration_s":5,"stop_to_text_s":0.1,"stop_to_delivery_s":0.1,"no_speech":true,"saved":false,"text_hash":""}"#,
        ]
        try (rows.joined(separator: "\n") + "\n").write(to: result, atomically: true, encoding: .utf8)

        let analysis = try DictationBenchmarkAnalyzer.analyze(resultURL: result, summaryURL: nil)
        XCTAssertFalse(analysis.scorecard.hardGateFailures.isEmpty)
        XCTAssertEqual(analysis.metrics.first(where: { $0.key == "cases.unstable" })?.value, 1)
    }

    func testSpeakerSweepUsesSafetyFirstOrdering() throws {
        let root = try temporaryDirectory()
        let reports = root.appendingPathComponent("data/eval/ami/reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try speakerScore(
            consolidation: "0.88",
            match: 0.60,
            der: 0.2,
            fragmentation: 1.0,
            falseMerges: 1,
            reID: 1.0,
            profiles: 2,
            trueSpeakers: ["a", "b"]
        ).write(to: reports.appendingPathComponent("cons_0.88_match_0.60.json"), atomically: true, encoding: .utf8)
        try speakerScore(
            consolidation: "0.85",
            match: 0.65,
            der: 0.25,
            fragmentation: 1.2,
            falseMerges: 0,
            reID: 0.8,
            profiles: 2,
            trueSpeakers: ["a", "b"]
        ).write(to: reports.appendingPathComponent("cons_0.85_match_0.65.json"), atomically: true, encoding: .utf8)

        var config = LabRunConfiguration.defaults(repositoryPath: root.path, homeDirectory: root)
        config.speakerCorpus = .ami
        config.consolidationThresholds = "0.88 0.85"
        config.matchThresholds = "0.60 0.65"
        let analysis = try SpeakerSweepAnalyzer.analyze(configuration: config)

        XCTAssertTrue(analysis.scorecard.hardGateFailures.isEmpty)
        XCTAssertEqual(analysis.metrics.first(where: { $0.key == "speaker.false-merges" })?.value, 0)
        XCTAssertEqual(analysis.metrics.first(where: { $0.key == "speaker.match" })?.value, 0.65)
    }

    func testCommandBuilderExposesDictationKnobs() throws {
        let root = try fakeRepository()
        var config = LabRunConfiguration.defaults(repositoryPath: root.path, homeDirectory: root)
        config.bench = .dictationStop
        config.name = "Fast Stop"
        config.repetitions = 7
        config.dictationVariant = .chunked
        config.encoderComputeMode = .cpuAndGPU
        config.skipBuild = true
        config.includeSilence = true
        config.simulateAutoEnter = false

        let command = try XCTUnwrap(LabCommandBuilder.build(
            configuration: config,
            runID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            artifactDirectory: root.appendingPathComponent("artifacts")
        ))

        XCTAssertEqual(command.executable, "/bin/bash")
        XCTAssertTrue(command.arguments.contains("chunked"))
        XCTAssertTrue(command.arguments.contains("7"))
        XCTAssertTrue(command.arguments.contains("cpu-and-gpu"))
        XCTAssertTrue(command.arguments.contains("--skip-build"))
        XCTAssertTrue(command.arguments.contains("--include-silence"))
        XCTAssertTrue(command.arguments.contains("--no-auto-enter"))
    }

    func testReportStoreRoundTripAndComparison() throws {
        let root = try temporaryDirectory()
        let store = LabReportStore(rootDirectory: root)
        let config = LabRunConfiguration.defaults(repositoryPath: "/tmp")
        let baseline = makeReport(id: UUID(), score: 80, metric: 500, config: config)
        let candidate = makeReport(id: UUID(), score: 90, metric: 400, config: config)
        try store.save(baseline)
        try store.save(candidate)

        XCTAssertEqual(try store.loadAll().count, 2)
        let comparison = LabReportComparator.compare(baseline: baseline, candidate: candidate)
        XCTAssertEqual(comparison.scoreDelta, 10)
        XCTAssertEqual(comparison.metricDeltas.first?.delta, -100)
    }

    private func makeReport(id: UUID, score: Int, metric: Double, config: LabRunConfiguration) -> LabRunReport {
        LabRunReport(
            id: id,
            startedAt: Date(),
            finishedAt: Date(),
            status: .passed,
            configuration: config,
            summary: "test",
            scorecard: LabScorecard(overallScore: score),
            metrics: [LabMetric(key: "latency", label: "Latency", value: metric, unit: "ms")],
            command: nil,
            process: nil,
            artifacts: [],
            sourceRevision: nil
        )
    }

    private func fakeRepository() throws -> URL {
        let root = try temporaryDirectory()
        for relative in [
            "AGENTS.md",
            "scripts/ops/transcripted-qa-bench.sh",
            "scripts/ops/dictation-stop-autoeval.sh",
            "scripts/run_speaker_eval.sh",
            "scripts/run_speaker_autoresearch.py",
            "Tools/SpeakerEvalHarness/Package.swift",
        ] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "fixture".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func jsonLine(event: String, timestamp: String, context: [String: Any]) -> String {
        let object: [String: Any] = ["event": event, "timestamp": timestamp, "context": context]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func speakerScore(
        consolidation: String,
        match: Double,
        der: Double,
        fragmentation: Double,
        falseMerges: Int,
        reID: Double,
        profiles: Int,
        trueSpeakers: [String]
    ) -> String {
        let object: [String: Any] = [
            "config": ["consolidationThreshold": consolidation, "matchThreshold": match],
            "der": ["mean_der": der],
            "fragmentation": ["mean_profiles_per_person": fragmentation, "max_profiles_per_person": fragmentation],
            "false_merge": ["count": falseMerges],
            "reid_curve_by_appearance": ["1": 0.0, "2": reID, "3": reID],
            "profiles_at_end": profiles,
            "true_speakers": trueSpeakers,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
