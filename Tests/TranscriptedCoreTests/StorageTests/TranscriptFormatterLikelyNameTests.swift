import XCTest
@testable import TranscriptedCore

/// Promise: a likely name is written as plain "Name (likely)" and is never a
/// confirmed identity, so Obsidian cannot create a wiki-link, person page, or
/// `speaker/` tag from it.
@available(macOS 14.0, *)
final class TranscriptFormatterLikelyNameTests: XCTestCase {
    func testLikelyNameIsNeverConfirmedInTheTranscript() {
        let utterance = TranscriptionUtterance(
            start: 0, end: 4, channel: 1, speakerId: 0,
            persistentSpeakerId: nil, matchSimilarity: nil,
            transcript: "Hello from the other side."
        )
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [utterance],
            duration: 4,
            processingTime: 1,
            microphoneAudioOutcome: .notProvided
        )
        let likelyName = "Fixture Speaker" + SpeakerMapping.likelyNameSuffix
        let mapping = SpeakerMapping(
            speakerId: "0",
            identifiedName: likelyName,
            confidence: .medium,
            isConfirmedIdentity: false
        )
        XCTAssertEqual(mapping.displayName, likelyName)
        XCTAssertFalse(mapping.isConfirmedIdentity)

        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-00000000A010")!,
            speakerMappings: ["system_0": mapping],
            speakerSources: ["system_0": "db_pending"],
            date: Date(timeIntervalSince1970: 1_775_000_000),
            formatOptions: TranscriptFormatOptions(
                audioSources: [.systemAudio],
                includeObsidianMetadata: true
            )
        )

        XCTAssertTrue(markdown.contains("[System/\(likelyName)]"), markdown)
        XCTAssertFalse(markdown.contains("[[\(likelyName)]]"), markdown)
        XCTAssertFalse(markdown.contains("speaker/fixture-speaker-(likely)"), markdown)
        XCTAssertFalse(markdown.contains("**Participants:**"), markdown)
        XCTAssertTrue(markdown.contains("source: db_pending"), markdown)
    }
}
