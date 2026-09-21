import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
extension TranscriptionTaskManagerMetadataTests {
    func testSavedRetranscriptionLanguagePreservesSelectionNotDetectedGuess() throws {
        let url = tempDirectory.appendingPathComponent("language.md")
        try "---\ntranscription_language: fi\ntranscription_language_resolved: fi\n---\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptionTaskManager.savedLanguageSelection(from: url), .explicit(code: "fi"))
        try "---\ntranscription_language: auto\ntranscription_language_resolved: fi\n---\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptionTaskManager.savedLanguageSelection(from: url), .automatic)
        try "---\ntitle: Legacy\n---\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptionTaskManager.savedLanguageSelection(from: url), .automatic)
        XCTAssertEqual(TranscriptionTaskManager.savedLanguageSelection(from: nil), .automatic)
    }

    func testFailedAudioRetentionPersistsRequestedLanguage() throws {
        let manager = makeManager()
        let mic = tempDirectory.appendingPathComponent("audio/language.wav")
        try writeMonoWAV(to: mic, duration: 3)
        let id = UUID()
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: mic, systemAudioURL: nil, errorMessage: "test failure", taskId: id,
            archiveAudio: false, languageSelection: .explicit(code: "fi")
        ))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.first { $0.id == id }?.languageSelection, .explicit(code: "fi"))
        let reloaded = makeManager()
        XCTAssertEqual(reloaded.failedTranscriptionManager.failedTranscriptions.first { $0.id == id }?.languageSelection, .explicit(code: "fi"))
    }

    func testShutdownPreservesCapturedJobLanguage() async throws {
        let manager = makeManager()
        let mic = tempDirectory.appendingPathComponent("audio/shutdown-language.wav")
        try writeMonoWAV(to: mic, duration: 3)
        let id = UUID()
        manager.startTranscription(
            taskId: id, micURL: mic, systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            languageSelection: .explicit(code: "fi")
        )
        let task = manager.activeTasks[id]
        XCTAssertEqual(manager.preserveActiveTranscriptionsForShutdown(errorMessage: "test shutdown"), 1)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.first { $0.id == id }?.languageSelection, .explicit(code: "fi"))
        await task?.value
    }
}
