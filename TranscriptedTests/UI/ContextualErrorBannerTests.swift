import XCTest
@testable import Transcripted

final class ContextualErrorBannerTests: XCTestCase {

    // MARK: - Keyword Classification

    func testMicrophoneKeywordClassifiesAsMicError() {
        let error = ContextualError.from(message: "Microphone not available")
        if case .microphoneError = error {} else {
            XCTFail("Expected .microphoneError, got \(error)")
        }
    }

    func testMicKeywordClassifiesAsMicError() {
        let error = ContextualError.from(message: "Mic input failed")
        if case .microphoneError = error {} else {
            XCTFail("Expected .microphoneError, got \(error)")
        }
    }

    func testAudioInputKeywordClassifiesAsMicError() {
        let error = ContextualError.from(message: "No audio input detected")
        if case .microphoneError = error {} else {
            XCTFail("Expected .microphoneError, got \(error)")
        }
    }

    func testSpeechKeywordClassifiesAsTranscriptionFailed() {
        let error = ContextualError.from(message: "Speech recognition failed")
        if case .transcriptionFailed = error {} else {
            XCTFail("Expected .transcriptionFailed, got \(error)")
        }
    }

    func testTranscriKeywordClassifiesAsTranscriptionFailed() {
        let error = ContextualError.from(message: "Transcription engine error")
        if case .transcriptionFailed = error {} else {
            XCTFail("Expected .transcriptionFailed, got \(error)")
        }
    }

    func testRecognitionKeywordClassifiesAsTranscriptionFailed() {
        let error = ContextualError.from(message: "Recognition service unavailable")
        if case .transcriptionFailed = error {} else {
            XCTFail("Expected .transcriptionFailed, got \(error)")
        }
    }

    func testNetworkKeywordClassifiesAsNetworkError() {
        let error = ContextualError.from(message: "Network request failed")
        if case .networkError = error {} else {
            XCTFail("Expected .networkError, got \(error)")
        }
    }

    func testConnectionKeywordClassifiesAsNetworkError() {
        let error = ContextualError.from(message: "Connection lost")
        if case .networkError = error {} else {
            XCTFail("Expected .networkError, got \(error)")
        }
    }

    func testInternetKeywordClassifiesAsNetworkError() {
        let error = ContextualError.from(message: "No internet available")
        if case .networkError = error {} else {
            XCTFail("Expected .networkError, got \(error)")
        }
    }

    func testOfflineKeywordClassifiesAsNetworkError() {
        let error = ContextualError.from(message: "Device is offline")
        if case .networkError = error {} else {
            XCTFail("Expected .networkError, got \(error)")
        }
    }

    func testDiskKeywordClassifiesAsStorageFull() {
        let error = ContextualError.from(message: "Disk write failed")
        if case .storageFull = error {} else {
            XCTFail("Expected .storageFull, got \(error)")
        }
    }

    func testStorageKeywordClassifiesAsStorageFull() {
        let error = ContextualError.from(message: "Storage unavailable")
        if case .storageFull = error {} else {
            XCTFail("Expected .storageFull, got \(error)")
        }
    }

    func testSpaceKeywordClassifiesAsStorageFull() {
        let error = ContextualError.from(message: "Not enough space")
        if case .storageFull = error {} else {
            XCTFail("Expected .storageFull, got \(error)")
        }
    }

    func testFullKeywordClassifiesAsStorageFull() {
        let error = ContextualError.from(message: "Disk is full")
        if case .storageFull = error {} else {
            XCTFail("Expected .storageFull, got \(error)")
        }
    }

    func testPermissionKeywordClassifiesAsPermissionDenied() {
        let error = ContextualError.from(message: "Permission not granted")
        if case .permissionDenied = error {} else {
            XCTFail("Expected .permissionDenied, got \(error)")
        }
    }

    func testDeniedKeywordClassifiesAsPermissionDenied() {
        let error = ContextualError.from(message: "Request denied by system")
        if case .permissionDenied = error {} else {
            XCTFail("Expected .permissionDenied, got \(error)")
        }
    }

    func testAccessKeywordClassifiesAsPermissionDenied() {
        let error = ContextualError.from(message: "Access restricted")
        if case .permissionDenied = error {} else {
            XCTFail("Expected .permissionDenied, got \(error)")
        }
    }

    func testUnknownMessageClassifiesAsUnknown() {
        let error = ContextualError.from(message: "Something went wrong")
        if case .unknown = error {} else {
            XCTFail("Expected .unknown, got \(error)")
        }
    }

    func testEmptyMessageClassifiesAsUnknown() {
        let error = ContextualError.from(message: "")
        if case .unknown = error {} else {
            XCTFail("Expected .unknown, got \(error)")
        }
    }

    func testClassificationIsCaseInsensitive() {
        let error = ContextualError.from(message: "MICROPHONE ERROR")
        if case .microphoneError = error {} else {
            XCTFail("Expected .microphoneError for uppercase, got \(error)")
        }
    }

    // MARK: - Icon Properties

    func testEveryErrorTypeHasNonEmptyIcon() {
        let errors: [ContextualError] = [
            .microphoneError(message: ""),
            .transcriptionFailed(message: ""),
            .networkError(message: ""),
            .storageFull(message: ""),
            .permissionDenied(message: ""),
            .unknown(message: "")
        ]
        for error in errors {
            XCTAssertFalse(error.icon.isEmpty, "\(error) has empty icon")
        }
    }

    // MARK: - Title Properties

    func testEveryErrorTypeHasNonEmptyTitle() {
        let errors: [ContextualError] = [
            .microphoneError(message: ""),
            .transcriptionFailed(message: ""),
            .networkError(message: ""),
            .storageFull(message: ""),
            .permissionDenied(message: ""),
            .unknown(message: "")
        ]
        for error in errors {
            XCTAssertFalse(error.title.isEmpty, "\(error) has empty title")
        }
    }

    // MARK: - Recovery Hint Properties

    func testEveryErrorTypeHasNonEmptyRecoveryHint() {
        let errors: [ContextualError] = [
            .microphoneError(message: ""),
            .transcriptionFailed(message: ""),
            .networkError(message: ""),
            .storageFull(message: ""),
            .permissionDenied(message: ""),
            .unknown(message: "")
        ]
        for error in errors {
            XCTAssertFalse(error.recoveryHint.isEmpty, "\(error) has empty recovery hint")
        }
    }

    // MARK: - Specific Values

    func testMicErrorIcon() {
        let error = ContextualError.microphoneError(message: "test")
        XCTAssertEqual(error.icon, "mic.slash.fill")
    }

    func testMicErrorTitle() {
        let error = ContextualError.microphoneError(message: "test")
        XCTAssertEqual(error.title, "Microphone Error")
    }

    func testUnknownErrorTitle() {
        let error = ContextualError.unknown(message: "test")
        XCTAssertEqual(error.title, "Error")
    }

    func testUnknownErrorRecoveryHint() {
        let error = ContextualError.unknown(message: "test")
        XCTAssertEqual(error.recoveryHint, "Try again")
    }

    // MARK: - Message Preservation

    func testOriginalMessagePreservedInError() {
        let msg = "Custom error message here"
        let error = ContextualError.from(message: msg)
        if case .unknown(let preserved) = error {
            XCTAssertEqual(preserved, msg)
        } else {
            XCTFail("Expected .unknown with preserved message")
        }
    }
}
