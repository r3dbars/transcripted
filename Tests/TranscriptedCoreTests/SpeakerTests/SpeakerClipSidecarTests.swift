import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerClipSidecarTests: XCTestCase {
    func testClipSegmentsPreferDurationOverCharacterCount() {
        let slow = utterance(
            start: 5,
            end: 15,
            text: "Okay. Um. Let's see here."
        )
        let fast = utterance(
            start: 40,
            end: 46,
            text: "We should finish the pricing memo before Friday and send it to legal."
        )

        let selected = SpeakerClipSamplePolicy.selectClipSegments(utterances: [slow, fast])

        XCTAssertEqual(selected.map(\.start), [5])
        XCTAssertEqual(selected.map(\.transcript), [slow.transcript])
        XCTAssertEqual(
            SpeakerClipSamplePolicy.sampleText(from: selected),
            slow.transcript,
            "the clip quote is the text of the duration-winning turn, not the longer sentence"
        )
        XCTAssertNotEqual(slow.transcript.count, fast.transcript.count)
        XCTAssertGreaterThan(fast.transcript.count, slow.transcript.count)
        XCTAssertGreaterThan(slow.end - slow.start, fast.end - fast.start)
    }

    func testJoinedShortTurnsKeepEveryChosenUtteranceInTheSidecar() {
        let first = utterance(start: 1.2, end: 2.0, text: "Hi.")
        let second = utterance(start: 3.4, end: 4.5, text: "Quick check.")
        let third = utterance(start: 8.0, end: 9.1, text: "And done.")

        let selected = SpeakerClipSamplePolicy.selectClipSegments(utterances: [first, second, third])
        XCTAssertEqual(selected.map(\.start), [1.2, 3.4, 8.0])

        let sidecar = SpeakerClipSamplePolicy.sidecar(
            channel: "system",
            diarizerSpeakerId: "1",
            segments: selected,
            transcriptId: UUID()
        )
        XCTAssertEqual(sidecar.segments.map(\.start), [1.2, 3.4, 8.0])
        XCTAssertEqual(sidecar.segments.map(\.text), [first.transcript, second.transcript, third.transcript])
        XCTAssertEqual(sidecar.sampleText, "Quick check.")
    }

    func testSidecarSegmentEndMatchesTheEightSecondWriteCap() {
        let long = utterance(
            start: 5.25,
            end: 18.0,
            text: "Okay. Um. Let's see here."
        )
        let sidecar = SpeakerClipSamplePolicy.sidecar(
            channel: "system",
            diarizerSpeakerId: "1",
            segments: [long]
        )
        XCTAssertEqual(sidecar.segments.count, 1)
        XCTAssertEqual(sidecar.segments[0].start, 5.25)
        XCTAssertEqual(sidecar.segments[0].end, 13.25)
        XCTAssertEqual(sidecar.sampleText, long.transcript)
    }

    func testPersistClipWritesAndReplacesTheSidecar() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let firstTemp = try writeTempClip(named: "first.wav", in: directory)
        let firstSidecar = SpeakerClipSidecar(
            transcriptId: UUID(),
            channel: "system",
            diarizerSpeakerId: "1",
            segments: [.init(start: 5.0, end: 13.0, text: "Okay. Um. Let's see here.")],
            sampleText: "Okay. Um. Let's see here."
        )
        SpeakerClipExtractor.persistClip(
            from: firstTemp,
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: firstSidecar
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        XCTAssertEqual(
            SpeakerClipSidecar.load(nextTo: persisted)?.sampleText,
            "Okay. Um. Let's see here."
        )

        let secondTemp = try writeTempClip(named: "second.wav", in: directory)
        let secondSidecar = SpeakerClipSidecar(
            channel: "mic",
            diarizerSpeakerId: "2",
            segments: [.init(start: 1.5, end: 4.0, text: "A later sample.")],
            sampleText: "A later sample."
        )
        SpeakerClipExtractor.persistClip(
            from: secondTemp,
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: secondSidecar
        )
        XCTAssertEqual(
            SpeakerClipSidecar.load(nextTo: persisted)?.sampleText,
            "A later sample.",
            "saving a new clip must overwrite the sidecar with that clip's own text"
        )
        XCTAssertEqual(SpeakerClipSidecar.load(nextTo: persisted)?.channel, "mic")
    }

    func testPersistClipCopiesASourceSidecarOnPromote() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceId = UUID()
        let targetId = UUID()
        let sourceTemp = try writeTempClip(named: "source.wav", in: directory)
        SpeakerClipExtractor.persistClip(
            from: sourceTemp,
            speakerId: sourceId,
            clipsDirectory: directory,
            sidecar: SpeakerClipSidecar(
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [.init(start: 5.0, end: 15.0, text: "Okay. Um. Let's see here.")],
                sampleText: "Okay. Um. Let's see here."
            )
        )
        let sourceClip = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: sourceId, clipsDirectory: directory)
        )

        SpeakerClipExtractor.persistClip(
            from: sourceClip,
            speakerId: targetId,
            clipsDirectory: directory
        )
        let promoted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: targetId, clipsDirectory: directory)
        )
        XCTAssertEqual(
            SpeakerClipSidecar.load(nextTo: promoted)?.sampleText,
            "Okay. Um. Let's see here.",
            "the kept profile must inherit the merged-away clip's own quote"
        )
    }

    func testDeletePersistedClipRemovesTheSidecar() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let temp = try writeTempClip(named: "doomed.wav", in: directory)
        SpeakerClipExtractor.persistClip(
            from: temp,
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: SpeakerClipSidecar(
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [],
                sampleText: "Gone with the clip."
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        let sidecarURL = SpeakerClipSidecar.url(nextTo: persisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: persisted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    func testOldClipWithoutSidecarHasNoQuote() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let temp = try writeTempClip(named: "legacy.wav", in: directory)
        SpeakerClipExtractor.persistClip(
            from: temp,
            speakerId: speakerId,
            clipsDirectory: directory
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        XCTAssertNil(
            SpeakerClipSidecar.load(nextTo: persisted),
            "a wav saved before sidecars existed must not invent quote metadata"
        )
    }
}

private func utterance(start: Double, end: Double, text: String) -> TranscriptionUtterance {
    TranscriptionUtterance(
        start: start,
        end: end,
        channel: 1,
        speakerId: 1,
        persistentSpeakerId: nil,
        matchSimilarity: nil,
        transcript: text
    )
}

private func temporaryClipsDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakerClipSidecarTests-\(UUID().uuidString)", isDirectory: true)
}

private func writeTempClip(named name: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data([1, 2, 3]).write(to: url)
    return url
}
