import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerClipSidecarTests: XCTestCase {
    func testClipSegmentsPreferACompleteTurnThatFitsTheWriteCap() {
        let cropped = utterance(
            start: 5,
            end: 15,
            text: "Okay. Um. Let's see here."
        )
        let complete = utterance(
            start: 40,
            end: 46,
            text: "We should finish the pricing memo before Friday and send it to legal."
        )

        let selected = SpeakerClipSamplePolicy.selectClipSegments(utterances: [cropped, complete])

        XCTAssertEqual(selected.map(\.start), [40])
        XCTAssertEqual(selected.map(\.transcript), [complete.transcript])
        XCTAssertEqual(
            SpeakerClipSamplePolicy.sampleText(
                from: SpeakerClipSamplePolicy.writtenSegments(from: selected)
            ),
            complete.transcript,
            "an 8s cap must prefer a turn that fits so the whole quote can play"
        )
        XCTAssertGreaterThan(cropped.end - cropped.start, SpeakerClipSamplePolicy.maxClipDuration)
        XCTAssertLessThanOrEqual(complete.end - complete.start, SpeakerClipSamplePolicy.maxClipDuration)
        XCTAssertGreaterThan(complete.transcript.count, cropped.transcript.count)
    }

    func testJoinedShortTurnsKeepEveryWrittenUtteranceInTheQuote() {
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
        XCTAssertEqual(
            sidecar.sampleText,
            "Hi. Quick check. And done.",
            "a glued clip under 3s must quote every written turn, in order"
        )
    }

    func testCroppedTurnStoresTheWrittenWindowAndNoQuote() {
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
        XCTAssertEqual(
            sidecar.segments[0].text,
            "",
            "a cropped window has no word times, so it must not keep the full turn's text"
        )
        XCTAssertEqual(
            sidecar.sampleText,
            "",
            "if no turn fits the 8s cap, the sidecar stores no quote"
        )
    }

    func testSidecarOmitsTurnsTheWriterWouldSkip() {
        let skipped = utterance(start: .nan, end: 4.0, text: "Never written.")
        let kept = utterance(start: 1.0, end: 2.5, text: "This is in the wav.")
        let reversed = utterance(start: 9.0, end: 8.0, text: "Also skipped.")
        let sidecar = SpeakerClipSamplePolicy.sidecar(
            channel: "mic",
            diarizerSpeakerId: "2",
            segments: [skipped, kept, reversed]
        )
        XCTAssertEqual(sidecar.segments.map(\.text), [kept.transcript])
        XCTAssertEqual(sidecar.sampleText, kept.transcript)
        XCTAssertFalse(sidecar.sampleText.contains("Never written."))
        XCTAssertFalse(sidecar.sampleText.contains("Also skipped."))
    }

    func testSidecarOmitsTurnsPastTheSourceAudio() {
        let inFile = utterance(start: 0.5, end: 2.0, text: "In the file.")
        let pastEnd = utterance(start: 12.0, end: 13.0, text: "Past the wav.")
        let sidecar = SpeakerClipSamplePolicy.sidecar(
            channel: "system",
            diarizerSpeakerId: "1",
            segments: [inFile, pastEnd],
            sourceDuration: 3.0
        )
        XCTAssertEqual(sidecar.segments.map(\.text), [inFile.transcript])
        XCTAssertEqual(sidecar.sampleText, inFile.transcript)
    }

    func testPersistClipWritesAndReplacesTheSidecar() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let firstTemp = try writeTempClip(named: "first.wav", in: directory, bytes: Data([1, 2, 3]))
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
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted)?.sampleText,
            "Okay. Um. Let's see here."
        )

        let secondTemp = try writeTempClip(named: "second.wav", in: directory, bytes: Data([4, 5, 6, 7]))
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
        let matching = try XCTUnwrap(SpeakerClipSidecar.loadMatchingWav(nextTo: persisted))
        XCTAssertEqual(
            matching.sampleText,
            "A later sample.",
            "saving a new clip must overwrite the sidecar with that clip's own text"
        )
        XCTAssertEqual(matching.channel, "mic")
        XCTAssertEqual(matching.formatVersion, SpeakerClipSidecar.currentFormatVersion)
        XCTAssertEqual(matching.wavByteCount, 4)
        XCTAssertFalse(matching.wavSHA256.isEmpty)
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
                segments: [.init(start: 5.0, end: 13.0, text: "Okay. Um. Let's see here.")],
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
            SpeakerClipSidecar.loadMatchingWav(nextTo: promoted)?.sampleText,
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
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted),
            "a wav saved before sidecars existed must not invent quote metadata"
        )
    }

    func testFailedCopyLeavesThePreviousClipAndSidecar() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let firstTemp = try writeTempClip(named: "keep.wav", in: directory, bytes: Data([9, 8, 7, 6]))
        SpeakerClipExtractor.persistClip(
            from: firstTemp,
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: SpeakerClipSidecar(
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [.init(start: 1, end: 4, text: "Keep this clip.")],
                sampleText: "Keep this clip."
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        let originalBytes = try Data(contentsOf: persisted)

        SpeakerClipExtractor.persistClip(
            from: directory.appendingPathComponent("missing-source.wav"),
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: SpeakerClipSidecar(
                channel: "mic",
                diarizerSpeakerId: "9",
                segments: [.init(start: 2, end: 3, text: "Must not replace.")],
                sampleText: "Must not replace."
            )
        )

        XCTAssertEqual(try Data(contentsOf: persisted), originalBytes)
        XCTAssertEqual(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted)?.sampleText,
            "Keep this clip.",
            "a failed copy must leave the previous wav and its matching sidecar"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: persisted.appendingPathExtension("part").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: SpeakerClipSidecar.url(nextTo: persisted).appendingPathExtension("part").path
            )
        )
    }

    func testLoadMatchingWavRejectsAMismatchedOrStaleSidecar() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let temp = try writeTempClip(named: "voice.wav", in: directory, bytes: Data([1, 2, 3, 4, 5]))
        SpeakerClipExtractor.persistClip(
            from: temp,
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: SpeakerClipSidecar(
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [.init(start: 1, end: 3, text: "Original words.")],
                sampleText: "Original words."
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        XCTAssertEqual(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted)?.sampleText,
            "Original words."
        )

        try Data([9, 9, 9, 9, 9]).write(to: persisted)
        XCTAssertNil(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted),
            "the same-path wav with different bytes is a stale pair — show no quote"
        )

        var stale = try XCTUnwrap(SpeakerClipSidecar.load(nextTo: persisted))
        stale.formatVersion = 0
        stale.wavByteCount = 5
        stale.wavSHA256 = "deadbeef"
        try stale.write(nextTo: persisted)
        try Data([1, 2, 3, 4, 5]).write(to: persisted)
        XCTAssertNil(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted),
            "an old sidecar version must not quote whatever wav is now at that path"
        )
    }

    func testMeetingDeletionLeavesThePersonsVoiceSample() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let meetingURL = directory.appendingPathComponent("Deleted_Call.md")
        try "deleted meeting".write(to: meetingURL, atomically: true, encoding: .utf8)
        let temp = try writeTempClip(named: "person.wav", in: directory, bytes: Data([3, 1, 4]))
        SpeakerClipExtractor.persistClip(
            from: temp,
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: SpeakerClipSidecar(
                transcriptId: UUID(),
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [.init(start: 2, end: 6, text: "This voice sample stays.")],
                sampleText: "This voice sample stays."
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )

        try FileManager.default.removeItem(at: meetingURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted.path))
        XCTAssertEqual(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted)?.sampleText,
            "This voice sample stays.",
            "the clip is the person's voice sample, not meeting-owned media, so deleting a meeting keeps it"
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

private func writeTempClip(named name: String, in directory: URL, bytes: Data = Data([1, 2, 3])) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
}
