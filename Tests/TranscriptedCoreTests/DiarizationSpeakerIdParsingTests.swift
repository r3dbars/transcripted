import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class DiarizationSpeakerIdParsingTests: XCTestCase {

    // speakerIdFromString is nonisolated, but it lives on the @MainActor
    // DiarizationService class. Constructing the service on the main actor and
    // calling the nonisolated helper keeps this test free of model loading.
    private func makeService() -> DiarizationService {
        DiarizationService(bundleProvider: { _ in nil })
    }

    func testParsesSortformerUnderscoreForm() {
        let service = makeService()
        XCTAssertEqual(service.speakerIdFromString("speaker_0"), 0)
        XCTAssertEqual(service.speakerIdFromString("speaker_3"), 3)
        XCTAssertEqual(service.speakerIdFromString("speaker_12"), 12)
    }

    func testParsesPyAnnoteSPrefixForm() {
        let service = makeService()
        XCTAssertEqual(service.speakerIdFromString("S0"), 0)
        XCTAssertEqual(service.speakerIdFromString("S1"), 1)
        XCTAssertEqual(service.speakerIdFromString("S42"), 42)
    }

    func testParsesBareIntegerForm() {
        let service = makeService()
        XCTAssertEqual(service.speakerIdFromString("0"), 0)
        XCTAssertEqual(service.speakerIdFromString("7"), 7)
    }

    func testUnderscoreFormTakesPrecedenceOverTrailingDigits() {
        // lastIndex(of: "_") finds the final underscore, so the digits after it win.
        let service = makeService()
        XCTAssertEqual(service.speakerIdFromString("speaker_label_5"), 5)
    }

    func testGarbageFallsBackToZero() {
        let service = makeService()
        XCTAssertEqual(service.speakerIdFromString("unknown"), 0)
        XCTAssertEqual(service.speakerIdFromString(""), 0)
        XCTAssertEqual(service.speakerIdFromString("speaker_"), 0)   // no digits after underscore
        XCTAssertEqual(service.speakerIdFromString("Sabc"), 0)       // S prefix but non-numeric
    }
}
