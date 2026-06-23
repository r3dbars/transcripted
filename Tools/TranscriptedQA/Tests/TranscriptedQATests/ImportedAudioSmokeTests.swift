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
        let results = try ImportedAudioSmokeRunner(outputDirectory: tempRoot, preserve: true).run()

        XCTAssertFalse(results.contains { $0.status == .fail })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/capture-type" && $0.status == .pass })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/sources" && $0.target == "system_audio" })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/speaker-channel" && $0.target == "system-only" })
        XCTAssertTrue(results.contains { $0.check == "imported-audio/transcript-validator" && $0.status == .pass })

        let transcript = tempRoot.appendingPathComponent("captures/meetings/Imported Partner Brief.md")
        let retainedAudio = tempRoot.appendingPathComponent("captures/meetings/audio/Imported Partner Brief_audio/recording.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedAudio.path))
    }
}
