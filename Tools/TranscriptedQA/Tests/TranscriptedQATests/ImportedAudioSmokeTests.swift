import XCTest
@testable import transcripted_qa

final class ImportedAudioSmokeTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedAudioSmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testImportedAudioSmokePassesAndWritesEvidence() throws {
        let results = try ImportedAudioSmokeRunner(outputDirectory: tempRoot, preserve: true, mode: .fixtureOnly).run()

        XCTAssertFalse(results.contains { $0.status == .fail })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/capture-type" && $0.status == .pass })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/sources" && $0.target == "system_audio" })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/speaker-channel" && $0.target == "system-only" })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/transcript-validator" && $0.status == .pass })

        XCTAssertTrue(results.contains { $0.check == "imported-audio/fixture-only" && $0.status == .warn })
        XCTAssertFalse(results.contains { $0.check == "imported-audio/core-pipeline" })
        let evidence = try XCTUnwrap(results.first { $0.check == "imported-audio/evidence-root" })
        let root = URL(fileURLWithPath: evidence.target)
        let transcript = root.appendingPathComponent("captures/meetings/Imported Partner Brief.md")
        let retainedAudio = root.appendingPathComponent("captures/meetings/audio/Imported Partner Brief_audio/recording.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedAudio.path))
    }

    func testCommandRequiresAnExplicitEvidenceMode() throws {
        XCTAssertThrowsError(try ImportedAudioSmoke.parse([]))
        XCTAssertNoThrow(try ImportedAudioSmoke.parse(["--fixture-only"]))
        XCTAssertThrowsError(try ImportedAudioSmoke.parse(["--fixture-only", "--producer", "/usr/bin/true"]))
    }

    func testFailedProducerCannotFallBackToTheHandwrittenFixture() throws {
        XCTAssertThrowsError(try ImportedAudioSmokeRunner(
            outputDirectory: tempRoot, mode: .producer(URL(fileURLWithPath: "/usr/bin/false"))
        ).run())
        let markdown = FileManager.default.enumerator(at: tempRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        XCTAssertTrue(markdown.isEmpty)
    }

    func testSuccessfulExitWithoutAProducerReceiptCannotPass() throws {
        XCTAssertThrowsError(try ImportedAudioSmokeRunner(
            outputDirectory: tempRoot, mode: .producer(URL(fileURLWithPath: "/usr/bin/true"))
        ).run())
    }


    func testProducerCannotReturnArtifactsOutsideItsEvidenceRoot() throws {
        let producer = try makeProducerReceipt(transcript: "../outside.md", speechCalls: 1)
        try "owned outside sentinel".write(to: tempRoot.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ImportedAudioSmokeRunner(outputDirectory: tempRoot, mode: .producer(producer)).run())
    }

    func testProducerMustActuallyCallTheSyntheticSpeechEngine() throws {
        let producer = try makeProducerReceipt(transcript: "source/Imported Partner Brief.wav", speechCalls: 0)
        XCTAssertThrowsError(try ImportedAudioSmokeRunner(outputDirectory: tempRoot, mode: .producer(producer)).run())
    }

    private func makeProducerReceipt(transcript: String, speechCalls: Int) throws -> URL {
        let payload: [String: Any] = ["formatVersion": 1, "transcript": transcript,
                                    "retainedAudio": "source/Imported Partner Brief.wav",
                                    "speechCalls": speechCalls, "diarizationCalls": 1]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let producer = tempRoot.appendingPathComponent("receipt-producer.sh")
        let script = """
        #!/bin/bash
        cat > "$2/producer-receipt.json" <<'RECEIPT'
        \(json)
        RECEIPT
        """
        try script.write(to: producer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: producer.path)
        return producer
    }

}
