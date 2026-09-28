import XCTest
@testable import TranscriptedCore

/// Promises for listing silently recognized voices after a meeting: the
/// review always shows who was on the call, and only a correction changes
/// what the pipeline already saved.
@available(macOS 14.0, *)
final class SpeakerRecognizedReviewPolicyTests: XCTestCase {

    private func entry(_ diarizerId: String, name: String?, channel: UtteranceChannel = .system) -> SpeakerNamingEntry {
        SpeakerNamingEntry(
            id: UUID(),
            diarizerSpeakerId: diarizerId,
            channel: channel,
            clipURL: URL(fileURLWithPath: "/nonexistent/clip-\(diarizerId).wav"),
            sampleText: "",
            currentName: name,
            matchSimilarity: nil,
            needsNaming: name == nil,
            needsConfirmation: false
        )
    }

    func testAReviewIsQueuedWhenEveryoneWasRecognized() {
        XCTAssertTrue(SpeakerNamingPolicy.shouldQueueSpeakerReview(askedVoices: 0, recognizedVoices: 2), "everyone recognized still shows who was on the call")
        XCTAssertTrue(SpeakerNamingPolicy.shouldQueueSpeakerReview(askedVoices: 1, recognizedVoices: 0))
        XCTAssertFalse(SpeakerNamingPolicy.shouldQueueSpeakerReview(askedVoices: 0, recognizedVoices: 0), "nobody to show, nothing to ask")
    }

    func testUncorrectedRecognizedVoicesAreNotSavedAgain() {
        let asked = [entry("0", name: nil)]
        let taylor = entry("1", name: "Taylor Wolf")
        let maya = entry("2", name: "Maya Chen")
        let reviewed = SpeakerNamingPolicy.reviewEntriesToFinalize(asked: asked, recognized: [taylor, maya], updates: [])
        XCTAssertEqual(reviewed.finalize.map(\.diarizerSpeakerId), ["0"], "asked voices always go to the save; untouched recognized ones don't")
        XCTAssertEqual(reviewed.discardClips.map(\.diarizerSpeakerId), ["1", "2"], "their clips are thrown away")
    }

    func testOnlyTheCorrectedRecognizedVoiceJoinsTheSave() {
        let taylor = entry("1", name: "Taylor Wolf")
        let maya = entry("2", name: "Maya Chen")
        let correction = SpeakerNameUpdate(
            persistentSpeakerId: taylor.id,
            diarizerSpeakerId: "1",
            newName: "Jordan Lee",
            previousName: "Taylor Wolf",
            action: .corrected
        )
        let reviewed = SpeakerNamingPolicy.reviewEntriesToFinalize(asked: [], recognized: [taylor, maya], updates: [correction])
        XCTAssertEqual(reviewed.finalize.map(\.diarizerSpeakerId), ["1"])
        XCTAssertEqual(reviewed.discardClips.map(\.diarizerSpeakerId), ["2"])
    }

    func testAnUpdateOnAnotherChannelDoesNotPullInARecognizedVoice() {
        let taylor = entry("1", name: "Taylor Wolf")
        let micUpdate = SpeakerNameUpdate(persistentSpeakerId: UUID(), diarizerSpeakerId: "1", channel: .mic, newName: "Me", action: .named)
        let reviewed = SpeakerNamingPolicy.reviewEntriesToFinalize(asked: [], recognized: [taylor], updates: [micUpdate])
        XCTAssertTrue(reviewed.finalize.isEmpty, "mic_1 is not system_1")
    }

    func testCorrectingARecognizedVoiceIsACorrectionNotAConfirmation() {
        let taylor = SpeakerNamingEntry(
            id: UUID(),
            diarizerSpeakerId: "1",
            clipURL: URL(fileURLWithPath: "/nonexistent/clip.wav"),
            sampleText: "",
            currentName: "Taylor Wolf",
            matchSimilarity: 0.92,
            needsNaming: false,
            needsConfirmation: false
        )
        let update = SpeakerNamingPolicy.typedNameUpdate(entry: taylor, typedName: "Jordan Lee", optionsByLabel: [:])
        guard case .corrected? = update?.action else {
            return XCTFail("a new name on a recognized voice must be a correction")
        }
        XCTAssertEqual(update?.previousName, "Taylor Wolf")
    }
}
