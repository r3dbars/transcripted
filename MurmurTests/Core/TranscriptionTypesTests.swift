import XCTest
@testable import Transcripted

final class TranscriptionTypesTests: XCTestCase {

    // MARK: - Empty result

    func testEmptyResultHasNoUtterances() {
        let result = TranscriptionResult.mock()
        XCTAssertTrue(result.allUtterances.isEmpty)
        XCTAssertEqual(result.micWordCount, 0)
        XCTAssertEqual(result.systemWordCount, 0)
    }

    // MARK: - allUtterances merging and sorting

    func testAllUtterancesMergesMicAndSystem() {
        let mic = [TranscriptionUtterance.mock(start: 0.0, end: 2.0, channel: 0, transcript: "Hello")]
        let sys = [TranscriptionUtterance.mock(start: 1.0, end: 3.0, channel: 1, transcript: "World")]
        let result = TranscriptionResult.mock(micUtterances: mic, systemUtterances: sys)

        XCTAssertEqual(result.allUtterances.count, 2)
    }

    func testAllUtterancesSortedByStartTime() {
        let mic = [TranscriptionUtterance.mock(start: 5.0, end: 7.0, channel: 0, transcript: "Later")]
        let sys = [TranscriptionUtterance.mock(start: 1.0, end: 3.0, channel: 1, transcript: "Earlier")]
        let result = TranscriptionResult.mock(micUtterances: mic, systemUtterances: sys)

        let sorted = result.allUtterances
        XCTAssertEqual(sorted[0].transcript, "Earlier")
        XCTAssertEqual(sorted[1].transcript, "Later")
    }

    // MARK: - Word counts

    func testMicWordCount() {
        let mic = [
            TranscriptionUtterance.mock(channel: 0, transcript: "Hello world"),
            TranscriptionUtterance.mock(channel: 0, transcript: "One two three")
        ]
        let result = TranscriptionResult.mock(micUtterances: mic)
        XCTAssertEqual(result.micWordCount, 5)
    }

    func testSystemWordCount() {
        let sys = [
            TranscriptionUtterance.mock(channel: 1, transcript: "Testing one two")
        ]
        let result = TranscriptionResult.mock(systemUtterances: sys)
        XCTAssertEqual(result.systemWordCount, 3)
    }

    // MARK: - Speaker counts

    func testMicSpeakerCount() {
        let mic = [
            TranscriptionUtterance.mock(speakerId: 0, transcript: "A"),
            TranscriptionUtterance.mock(speakerId: 0, transcript: "B"),
            TranscriptionUtterance.mock(speakerId: 1, transcript: "C")
        ]
        let result = TranscriptionResult.mock(micUtterances: mic)
        XCTAssertEqual(result.micSpeakerCount, 2)
    }

    func testSystemSpeakerIds() {
        let sys = [
            TranscriptionUtterance.mock(channel: 1, speakerId: 0, transcript: "A"),
            TranscriptionUtterance.mock(channel: 1, speakerId: 1, transcript: "B"),
            TranscriptionUtterance.mock(channel: 1, speakerId: 0, transcript: "C")
        ]
        let result = TranscriptionResult.mock(systemUtterances: sys)
        XCTAssertEqual(result.systemSpeakerIds, Set(["0", "1"]))
    }

    func testSystemSpeakerCount() {
        let sys = [
            TranscriptionUtterance.mock(channel: 1, speakerId: 2, transcript: "A"),
            TranscriptionUtterance.mock(channel: 1, speakerId: 3, transcript: "B"),
            TranscriptionUtterance.mock(channel: 1, speakerId: 2, transcript: "C")
        ]
        let result = TranscriptionResult.mock(systemUtterances: sys)
        XCTAssertEqual(result.systemSpeakerCount, 2)
    }
}
