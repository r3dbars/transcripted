import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class LogPrivacySanitizerTests: XCTestCase {

    // MARK: - sanitizeText

    func testSanitizeTextReturnsEmptyForEmptyInput() {
        XCTAssertEqual(LogPrivacySanitizer.sanitizeText(""), "")
    }

    func testSanitizeTextReturnsEmptyForWhitespaceOnlyInput() {
        XCTAssertEqual(LogPrivacySanitizer.sanitizeText("   \n\t  "), "")
    }

    func testSanitizeTextTrimsAndPassesThroughPlainTextUnchanged() {
        let text = " Meeting started successfully and transcription completed without errors. "
        XCTAssertEqual(
            LogPrivacySanitizer.sanitizeText(text),
            "Meeting started successfully and transcription completed without errors."
        )
    }

    func testSanitizeTextRedactsFullFilePath() {
        XCTAssertEqual(
            LogPrivacySanitizer.sanitizeText("/Users/jane/output.txt"),
            "[redacted-path]"
        )
    }

    func testSanitizeTextRedactsFilePathEmbeddedInSentence() {
        let text = "Failed to write to /Users/jane/output.txt: no permission"
        XCTAssertEqual(
            LogPrivacySanitizer.sanitizeText(text),
            "Failed to write to [redacted-path]: no permission"
        )
    }

    func testSanitizeTextRedactsEmailAddress() {
        let text = "Contact jane@example.com for details"
        XCTAssertEqual(
            LogPrivacySanitizer.sanitizeText(text),
            "Contact [redacted-email] for details"
        )
    }

    func testSanitizeTextRedactsRawURL() {
        let text = "See https://example.com/path?x=1 for more"
        XCTAssertEqual(
            LogPrivacySanitizer.sanitizeText(text),
            "See [redacted-url] for more"
        )
    }

    func testSanitizeTextRedactsJSONSpeakerNameAssignment() {
        let text = #"{"speaker_name":"Jane Doe"}"#
        XCTAssertEqual(
            LogPrivacySanitizer.sanitizeText(text),
            #"{"speaker_name":"[redacted-sensitive-value]"}"#
        )
    }

    func testSanitizeTextRedactsInlineMeetingTitleAssignment() {
        let text = "meeting_title=Weekly Sync"
        XCTAssertEqual(
            LogPrivacySanitizer.sanitizeText(text),
            "meeting_title=[redacted-sensitive-value]"
        )
    }

    // MARK: - sanitizeMetadata

    func testSanitizeMetadataNilInputReturnsNil() {
        XCTAssertNil(LogPrivacySanitizer.sanitizeMetadata(nil))
    }

    func testSanitizeMetadataPassesThroughAllowedDeviceClassKeys() {
        let metadata = [
            "inputDeviceClass": "usb",
            "outputDeviceClass": "builtin",
            "systemOutputDeviceClass": "builtin"
        ]

        let sanitized = LogPrivacySanitizer.sanitizeMetadata(metadata)

        XCTAssertEqual(sanitized?["inputDeviceClass"], "usb")
        XCTAssertEqual(sanitized?["outputDeviceClass"], "builtin")
        XCTAssertEqual(sanitized?["systemOutputDeviceClass"], "builtin")
    }

    func testSanitizeMetadataRedactsFilePathKey() {
        let metadata = ["filePath": "/Users/jane/output.txt"]
        let sanitized = LogPrivacySanitizer.sanitizeMetadata(metadata)
        XCTAssertEqual(sanitized?["filePath"], "[redacted-sensitive-value]")
    }

    func testSanitizeMetadataRedactsSpeakerNameKey() {
        let metadata = ["speakerName": "Jane Doe"]
        let sanitized = LogPrivacySanitizer.sanitizeMetadata(metadata)
        XCTAssertEqual(sanitized?["speakerName"], "[redacted-sensitive-value]")
    }

    func testSanitizeMetadataRedactsAudioPathKey() {
        let metadata = ["audioPath": "/Users/jane/rec.wav"]
        let sanitized = LogPrivacySanitizer.sanitizeMetadata(metadata)
        XCTAssertEqual(sanitized?["audioPath"], "[redacted-sensitive-value]")
    }

    func testSanitizeMetadataRedactsTranscriptTextKey() {
        let metadata = ["transcriptText": "hello world"]
        let sanitized = LogPrivacySanitizer.sanitizeMetadata(metadata)
        XCTAssertEqual(sanitized?["transcriptText"], "[redacted-sensitive-value]")
    }

    func testSanitizeMetadataSanitizesEmailInNonSensitiveKeyValue() {
        let metadata = ["note": "contact me at jane@example.com"]
        let sanitized = LogPrivacySanitizer.sanitizeMetadata(metadata)
        XCTAssertEqual(sanitized?["note"], "contact me at [redacted-email]")
    }

    func testSanitizeMetadataDropsKeyWhenSanitizedValueBecomesEmpty() {
        let metadata = [
            "inputDeviceClass": "usb",
            "note": "   "
        ]

        let sanitized = LogPrivacySanitizer.sanitizeMetadata(metadata)

        XCTAssertEqual(sanitized?["inputDeviceClass"], "usb")
        XCTAssertNil(sanitized?["note"])
    }

    func testSanitizeMetadataReturnsNilWhenAllValuesDropOut() {
        let metadata = ["note": "   "]
        XCTAssertNil(LogPrivacySanitizer.sanitizeMetadata(metadata))
    }
}
