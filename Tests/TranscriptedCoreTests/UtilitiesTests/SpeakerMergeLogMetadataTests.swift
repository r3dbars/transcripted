import XCTest
@testable import TranscriptedCore

final class SpeakerMergeLogMetadataTests: XCTestCase {
    func testExplicitMergeMetadataAllowsOnlyCallCountThroughSanitizer() {
        for count in [0, 1, 47] {
            let metadata = SpeakerMergeLogMetadata.explicit(newCallCount: count)
            let expected = ["newCallCount": "\(count)"]
            XCTAssertEqual(metadata, expected)
            XCTAssertEqual(LogPrivacySanitizer.sanitizeMetadata(metadata), expected)
        }
    }

    func testDuplicateMergeMetadataAllowsOnlySimilarityThroughSanitizer() {
        for (similarity, formatted) in [(0.0, "0.000"), (0.91234, "0.912"), (1.0, "1.000")] {
            let metadata = SpeakerMergeLogMetadata.duplicate(similarity: similarity)
            let expected = ["similarity": formatted]
            XCTAssertEqual(metadata, expected)
            XCTAssertEqual(LogPrivacySanitizer.sanitizeMetadata(metadata), expected)
        }
    }

    func testMergePrivacyDoesNotRemoveOtherSafeDiagnostics() {
        let metadata = ["source": "microphone", "count": "7", "inputDeviceClass": "usb",
                        "speakerName": "Invented Person"]
        XCTAssertEqual(LogPrivacySanitizer.sanitizeMetadata(metadata),
                       ["source": "microphone", "count": "7", "inputDeviceClass": "usb",
                        "speakerName": "[redacted-sensitive-value]"])
    }
}
