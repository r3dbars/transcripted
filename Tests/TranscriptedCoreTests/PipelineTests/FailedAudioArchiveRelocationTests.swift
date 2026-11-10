import XCTest
import AVFoundation
@testable import TranscriptedCore

@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testUnexpectedStopKeepsScratchRetryRowAfterLibrarySwitch() async throws {
        try await assertUnexpectedStopKeepsScratchRetryRowAfterLibrarySwitch(hasMicrophone: true)
    }

    func testSystemOnlyUnexpectedStopKeepsScratchRetryRowAfterLibrarySwitch() async throws {
        try await assertUnexpectedStopKeepsScratchRetryRowAfterLibrarySwitch(hasMicrophone: false)
    }

    func testUnexpectedStopKeepsOriginalAudioWhenBothQueueAttemptsFail() async throws {
        let archive = tempDirectory.appendingPathComponent("transcripts/audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: archive)
        let scratch = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        let micURL = scratch.appendingPathComponent("mic.wav")
        let systemURL = scratch.appendingPathComponent("system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)
        let micBytes = try Data(contentsOf: micURL)
        let systemBytes = try Data(contentsOf: systemURL)
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            withIntermediateDirectories: true
        )

        let persisted = await manager.persistUnexpectedCaptureStopFailure(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Synthetic capture failure"
        )

        XCTAssertFalse(persisted)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: micURL), micBytes)
        XCTAssertEqual(try Data(contentsOf: systemURL), systemBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.path), [])
    }

    private func assertUnexpectedStopKeepsScratchRetryRowAfterLibrarySwitch(hasMicrophone: Bool) async throws {
        var selectedArchive = tempDirectory.appendingPathComponent("transcripts/audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectoryProvider: { selectedArchive })
        // The host follows a newly selected capture library, while the queue
        // still admits its launch-time archive root and stable scratch root.
        selectedArchive = tempDirectory.appendingPathComponent("new-library/audio", isDirectory: true)
        let scratch = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        let micURL = hasMicrophone ? scratch.appendingPathComponent("mic.wav") : nil
        let systemURL = scratch.appendingPathComponent("system.wav")
        if let micURL { try writeMonoWAV(to: micURL, duration: 2.5) }
        try writeMonoWAV(to: systemURL, duration: 2.5)
        let originalMicBytes = try micURL.map { try Data(contentsOf: $0) }
        let originalSystemBytes = try Data(contentsOf: systemURL)
        let id = UUID()
        let recordedAt = Date(timeIntervalSince1970: 1_797_000_000)

        let persisted = await manager.persistUnexpectedCaptureStopFailure(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Synthetic capture failure",
            taskId: id,
            meetingTitle: "Synthetic retry",
            recordingDate: recordedAt,
            splitLocalSpeakers: true,
            languageSelection: .explicit(code: "es"),
            micOnlyByChoice: false
        )

        XCTAssertTrue(persisted, "an archive outside the queue's launch-time roots must fall back to its owned scratch audio")
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        let row = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.systemAudioURL, systemURL)
        XCTAssertEqual(row.meetingTitle, "Synthetic retry")
        XCTAssertEqual(row.recordingDate, recordedAt)
        XCTAssertEqual(row.errorMessage, "Synthetic capture failure")
        XCTAssertEqual(row.languageSelection, .explicit(code: "es"))
        XCTAssertTrue(row.splitLocalSpeakers)
        if let micURL {
            XCTAssertEqual(row.micAudioURL, micURL)
            XCTAssertEqual(try Data(contentsOf: micURL), originalMicBytes)
        } else {
            XCTAssertEqual(row.micAudioURL.deletingLastPathComponent(), scratch)
            let placeholder = try AVAudioFile(forReading: row.micAudioURL)
            XCTAssertGreaterThan(placeholder.length, 0, "a system-only retry needs a readable microphone placeholder")
        }
        XCTAssertEqual(try Data(contentsOf: systemURL), originalSystemBytes)

        let reloaded = makeManager(retainedAudioDirectoryProvider: { selectedArchive })
        XCTAssertEqual(reloaded.failedTranscriptionManager.failedTranscriptions.count, 1)
        let durableRow = try XCTUnwrap(reloaded.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(durableRow.id, id)
        XCTAssertEqual(durableRow.micAudioURL, row.micAudioURL)
        XCTAssertEqual(durableRow.systemAudioURL, systemURL)
        XCTAssertEqual(durableRow.languageSelection, .explicit(code: "es"))
        XCTAssertTrue(durableRow.splitLocalSpeakers)
    }
}
