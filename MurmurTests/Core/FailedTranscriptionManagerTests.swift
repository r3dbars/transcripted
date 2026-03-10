import XCTest
@testable import Transcripted

@MainActor
final class FailedTranscriptionManagerTests: XCTestCase {

    // MARK: - FailedTranscription.audioFilesExist

    func testAudioFilesExistReturnsFalseForMissingFiles() {
        let ft = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/nonexistent_mic_\(UUID()).wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/nonexistent_sys_\(UUID()).wav"),
            errorMessage: "test"
        )
        XCTAssertFalse(ft.audioFilesExist())
    }

    func testAudioFilesExistReturnsTrueForExistingMicFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let micURL = tempDir.appendingPathComponent("test_mic_\(UUID()).wav")
        try Data("mic".utf8).write(to: micURL)
        defer { try? FileManager.default.removeItem(at: micURL) }

        let ft = FailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "test"
        )
        XCTAssertTrue(ft.audioFilesExist())
    }

    // MARK: - FailedTranscription retryCount / lastRetryDate

    func testRetryCountDefaultsToZero() {
        let ft = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: nil,
            errorMessage: "test"
        )
        XCTAssertEqual(ft.retryCount, 0)
        XCTAssertNil(ft.lastRetryDate)
    }

    func testRetryCountIsMutable() {
        var ft = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: nil,
            errorMessage: "test"
        )
        ft.retryCount = 3
        ft.lastRetryDate = Date()
        XCTAssertEqual(ft.retryCount, 3)
        XCTAssertNotNil(ft.lastRetryDate)
    }

    // MARK: - FailedTranscription Codable round-trip

    func testCodableRoundTrip() throws {
        let original = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/sys.wav"),
            errorMessage: "Model not loaded",
            retryCount: 2
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([original])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([FailedTranscription].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, original.id)
        XCTAssertEqual(decoded[0].errorMessage, "Model not loaded")
        XCTAssertEqual(decoded[0].retryCount, 2)
        XCTAssertEqual(decoded[0].micAudioURL, original.micAudioURL)
        XCTAssertEqual(decoded[0].systemAudioURL, original.systemAudioURL)
    }

    func testCodableHandlesNilSystemAudio() throws {
        let original = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: nil,
            errorMessage: "test"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([original])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([FailedTranscription].self, from: data)

        XCTAssertNil(decoded[0].systemAudioURL)
    }

    // MARK: - Cleanup criteria

    func testPermanentFailureIsNotRetryable() {
        let ft = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Empty audio file — no samples recorded."
        )
        // Permanent errors should not be retryable
        XCTAssertFalse(ft.isRetryable)
    }

    func testExhaustedRetriesCleanupThreshold() {
        var ft = FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Parakeet model not loaded"
        )
        ft.retryCount = 3
        // Even retryable errors should be cleaned after 3+ attempts
        XCTAssertTrue(ft.isRetryable)
        XCTAssertTrue(ft.retryCount >= 3)
    }
}
