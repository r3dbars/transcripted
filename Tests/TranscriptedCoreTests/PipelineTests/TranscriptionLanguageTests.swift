import XCTest
@testable import TranscriptedCore

final class TranscriptionLanguageTests: XCTestCase {
    func testSelectionValidatesKnownCodesAndCodableRoundTrips() throws {
        XCTAssertEqual(TranscriptionLanguageSelection(rawValue: " FI "), .explicit(code: "fi"))
        XCTAssertEqual(TranscriptionLanguageSelection(rawValue: "auto"), .automatic)
        XCTAssertNil(TranscriptionLanguageSelection(rawValue: "xyz"))
        XCTAssertNil(TranscriptionLanguageSelection(rawValue: "fi\nother: true"))
        for selection in [TranscriptionLanguageSelection.automatic, .explicit(code: "fi")] {
            XCTAssertEqual(try JSONDecoder().decode(TranscriptionLanguageSelection.self, from: JSONEncoder().encode(selection)), selection)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptionLanguageSelection.self, from: Data("\"xyz\"".utf8)))
    }

    func testFailedRecordPreservesSelectionAndLegacyDefaultsToAutomatic() throws {
        let failed = FailedTranscription(micAudioURL: URL(fileURLWithPath: "/tmp/synthetic.wav"), systemAudioURL: nil, errorMessage: "synthetic", languageSelection: .explicit(code: "fi"))
        let data = try JSONEncoder().encode(failed)
        XCTAssertEqual(try JSONDecoder().decode(FailedTranscription.self, from: data).languageSelection, .explicit(code: "fi"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "languageSelection")
        XCTAssertEqual(try JSONDecoder().decode(FailedTranscription.self, from: JSONSerialization.data(withJSONObject: legacy)).languageSelection, .automatic)
    }

    @available(macOS 14.0, *)
    func testSavedMetadataDistinguishesSelectedResolvedAndUncertain() {
        let contexts: [TranscriptionLanguageContext] = [
            .init(selection: .explicit(code: "fi"), languageCode: "fi", resolution: .explicit),
            .init(selection: .automatic, languageCode: "fi", resolution: .detected),
            .init(selection: .automatic, languageCode: nil, resolution: .multilingual)
        ]
        for context in contexts {
            let result = TranscriptionResult(micUtterances: [], systemUtterances: [], duration: 1, processingTime: 1, languageContext: context)
            let text = TranscriptSaver.formatTranscriptMarkdown(result: result, transcriptId: UUID(), date: Date(timeIntervalSince1970: 0))
            let values = TranscriptFrontmatter.values(in: text) ?? [:]
            XCTAssertEqual(values["transcription_language"], context.selection.rawValue)
            XCTAssertEqual(values["transcription_language_resolution"], context.resolution.rawValue)
            XCTAssertEqual(values["transcription_language_resolved"], context.languageCode)
        }
    }
}
