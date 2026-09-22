import ArgumentParser
import Foundation
import XCTest
@testable import transcripted_cli

final class ImportAudioCommandTests: XCTestCase {
    func testDefaultsPreserveSourceAndSavePlayback() throws {
        let command = try ImportAudio.parse(["memo.m4a"])
        XCTAssertEqual(command.mediaPath, "memo.m4a")
        XCTAssertNil(command.outputDir)
        XCTAssertFalse(command.noRetainAudio)
        XCTAssertFalse(command.noSpeakerIdentification)
        XCTAssertEqual(command.speakerEmbedder, "app")
    }

    func testOptionsAreAvailableInBothBuildModes() throws {
        let command = try ImportAudio.parse(["äänet test.mp4", "--output-dir", "/tmp/Meeting Notes", "--no-retain-audio",
                                           "--no-speaker-identification", "--speaker-embedder", "wespeaker", "--title", "Roadmap",
                                           "--no-download", "--json", "--models-dir", "models", "--diarization-models-dir", "voices"])
        XCTAssertTrue(command.noRetainAudio)
        XCTAssertTrue(command.noSpeakerIdentification)
        XCTAssertTrue(command.noDownload)
        XCTAssertTrue(command.json)
        XCTAssertEqual(command.resolvedOutputDirectory.path, "/tmp/Meeting Notes")
        XCTAssertEqual(command.title, "Roadmap")
    }

    func testRejectsContradictoryOrEmptyOptions() {
        for args in [["memo.wav", "--speaker-embedder", "unknown"], ["memo.wav", "--title", "  "],
                     ["memo.wav", "--no-speaker-identification", "--speaker-db", "people.sqlite"],
                     ["memo.wav", "--output-dir", ""], [], ["one.wav", "two.wav"]] {
            XCTAssertThrowsError(try ImportAudio.parse(args), "\(args)")
        }
    }

    func testRootRegistersImportWithoutChangingTranscribe() throws {
        XCTAssertTrue(try TranscriptedCLI.parseAsRoot(["import-audio", "memo.wav"]) is ImportAudio)
        XCTAssertTrue(try TranscriptedCLI.parseAsRoot(["transcribe", "memo.wav", "--json"]) is Transcribe)
    }

    func testDefaultWriteDirectoryFollowsAppManifestNotLegacyReadFallback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("CLIImportPaths-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/Transcripted")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let selected = home.appendingPathComponent("Custom Library")
        let manifest: [String: Any] = ["version": 1, "captureLibraryDirectory": selected.path,
                                      "meetingsDirectory": selected.appendingPathComponent("meetings").path,
                                      "dictationsDirectory": selected.appendingPathComponent("dictations").path]
        try JSONSerialization.data(withJSONObject: manifest).write(to: support.appendingPathComponent("mcp-directories.json"))
        let legacy = home.appendingPathComponent("Library/Application Support/Draft/meetings/transcripts")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("---\ncapture_type: meeting\n---\n## Full Transcript\n".utf8).write(to: legacy.appendingPathComponent("legacy.md"))
        XCTAssertEqual(ImportAudio.outputDirectory(override: nil, environment: [:], homeDirectory: home).path, selected.appendingPathComponent("meetings").path)
        XCTAssertEqual(ImportAudio.outputDirectory(override: "/tmp/direct", environment: ["TRANSCRIPTED_MEETINGS_DIR": "/tmp/env"], homeDirectory: home).path, "/tmp/direct")
        XCTAssertEqual(ImportAudio.outputDirectory(override: nil, environment: ["TRANSCRIPTED_MEETINGS_DIR": "/tmp/env"], homeDirectory: home).path, "/tmp/env")
        try FileManager.default.removeItem(at: support.appendingPathComponent("mcp-directories.json"))
        XCTAssertEqual(ImportAudio.outputDirectory(override: nil, environment: [:], homeDirectory: home).path, support.appendingPathComponent("captures/meetings").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("captures").path), "Resolving the write location alone must not create a library")
    }
}
