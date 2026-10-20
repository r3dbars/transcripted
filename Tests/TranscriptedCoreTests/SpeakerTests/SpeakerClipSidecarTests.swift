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
        let firstSidecar = try XCTUnwrap(
            SpeakerClipSidecar(
                transcriptId: UUID(),
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [.init(start: 5.0, end: 13.0, text: "Okay. Um. Let's see here.")],
                sampleText: "Okay. Um. Let's see here."
            ).stamped(withWavAt: firstTemp)
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
        let secondSidecar = try XCTUnwrap(
            SpeakerClipSidecar(
                channel: "mic",
                diarizerSpeakerId: "2",
                segments: [.init(start: 1.5, end: 4.0, text: "A later sample.")],
                sampleText: "A later sample."
            ).stamped(withWavAt: secondTemp)
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
            sidecar: try XCTUnwrap(
                SpeakerClipSidecar(
                    channel: "system",
                    diarizerSpeakerId: "1",
                    segments: [.init(start: 5.0, end: 13.0, text: "Okay. Um. Let's see here.")],
                    sampleText: "Okay. Um. Let's see here."
                ).stamped(withWavAt: sourceTemp)
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
            sidecar: try XCTUnwrap(
                SpeakerClipSidecar(
                    channel: "system",
                    diarizerSpeakerId: "1",
                    segments: [],
                    sampleText: "Gone with the clip."
                ).stamped(withWavAt: temp)
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

    func testPersistWithoutSidecarDropsThePreviousQuote() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let firstTemp = try writeTempClip(named: "quoted.wav", in: directory, bytes: Data([1, 2, 3]))
        SpeakerClipExtractor.persistClip(
            from: firstTemp,
            speakerId: speakerId,
            clipsDirectory: directory,
            sidecar: try XCTUnwrap(
                SpeakerClipSidecar(
                    channel: "system",
                    diarizerSpeakerId: "1",
                    segments: [.init(start: 1, end: 3, text: "Old words.")],
                    sampleText: "Old words."
                ).stamped(withWavAt: firstTemp)
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        XCTAssertEqual(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted)?.sampleText,
            "Old words."
        )

        let secondTemp = try writeTempClip(named: "bare.wav", in: directory, bytes: Data([9, 8, 7, 6]))
        SpeakerClipExtractor.persistClip(
            from: secondTemp,
            speakerId: speakerId,
            clipsDirectory: directory
        )

        XCTAssertEqual(try Data(contentsOf: persisted), Data([9, 8, 7, 6]))
        XCTAssertNil(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted),
            "a new wav with no sidecar must not keep the previous clip's quote"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: SpeakerClipSidecar.url(nextTo: persisted).path)
        )
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
            sidecar: try XCTUnwrap(
                SpeakerClipSidecar(
                    channel: "system",
                    diarizerSpeakerId: "1",
                    segments: [.init(start: 1, end: 4, text: "Keep this clip.")],
                    sampleText: "Keep this clip."
                ).stamped(withWavAt: firstTemp)
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
            sidecar: try XCTUnwrap(
                SpeakerClipSidecar(
                    channel: "system",
                    diarizerSpeakerId: "1",
                    segments: [.init(start: 1, end: 3, text: "Original words.")],
                    sampleText: "Original words."
                ).stamped(withWavAt: temp)
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

    func testPersistDropsASidecarThatDoesNotMatchItsSourceWav() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceId = UUID()
        let targetId = UUID()
        let sourceTemp = try writeTempClip(named: "source.wav", in: directory, bytes: Data([1, 2, 3, 4]))
        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: sourceTemp,
                speakerId: sourceId,
                clipsDirectory: directory,
                sidecar: try XCTUnwrap(
                    SpeakerClipSidecar(
                        channel: "system",
                        diarizerSpeakerId: "1",
                        segments: [.init(start: 1, end: 3, text: "Words from this wav.")],
                        sampleText: "Words from this wav."
                    ).stamped(withWavAt: sourceTemp)
                )
            )
        )
        let sourceClip = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: sourceId, clipsDirectory: directory)
        )

        let otherWav = try writeTempClip(named: "other.wav", in: directory, bytes: Data([9, 9, 9, 9]))
        var hijacked = SpeakerClipSidecar(
            channel: "system",
            diarizerSpeakerId: "1",
            segments: [.init(start: 5, end: 8, text: "Quote from a wav that never landed.")],
            sampleText: "Quote from a wav that never landed."
        )
        hijacked = try XCTUnwrap(hijacked.stamped(withWavAt: otherWav))
        try hijacked.write(nextTo: sourceClip)
        XCTAssertNil(
            SpeakerClipSidecar.loadMatchingWav(nextTo: sourceClip),
            "the crash-window pair is already mismatched on disk"
        )

        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: sourceClip,
                speakerId: targetId,
                clipsDirectory: directory
            ),
            "the wav itself still copies"
        )
        let promoted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: targetId, clipsDirectory: directory)
        )
        XCTAssertEqual(try Data(contentsOf: promoted), Data([1, 2, 3, 4]))
        XCTAssertNil(
            SpeakerClipSidecar.loadMatchingWav(nextTo: promoted),
            "a sidecar that did not match the source wav must not be restamped onto the copy"
        )
    }

    func testRecordedFramesCropTheQuoteWhenTheWriterReadsShort() {
        let planned = SpeakerClipSamplePolicy.WrittenSegment(
            start: 1.0,
            end: 4.0,
            text: "Full turn that was not fully written.",
            wasCropped: false
        )
        let recorded = try? XCTUnwrap(
            SpeakerClipSamplePolicy.recordedSegment(
                from: planned,
                framesWritten: 8_000,
                sampleRate: 16_000
            )
        )
        XCTAssertEqual(recorded?.start, 1.0)
        XCTAssertEqual(recorded?.end, 1.5)
        XCTAssertEqual(recorded?.wasCropped, true)
        XCTAssertEqual(
            SpeakerClipSamplePolicy.sampleText(from: recorded.map { [$0] } ?? []),
            "",
            "a short read must not keep the planned turn's full text"
        )

        let complete = SpeakerClipSamplePolicy.recordedSegment(
            from: planned,
            framesWritten: 48_000,
            sampleRate: 16_000
        )
        XCTAssertEqual(complete?.end, 4.0)
        XCTAssertEqual(complete?.wasCropped, false)
        XCTAssertEqual(
            SpeakerClipSamplePolicy.sampleText(from: complete.map { [$0] } ?? []),
            planned.text
        )
    }

    func testDeleteUsesTheSameProfileLockAsSave() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let temp = try writeTempClip(named: "locked.wav", in: directory, bytes: Data([2, 2, 2]))
        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: temp,
                speakerId: speakerId,
                clipsDirectory: directory,
                sidecar: try XCTUnwrap(
                    SpeakerClipSidecar(
                        channel: "system",
                        diarizerSpeakerId: "1",
                        segments: [.init(start: 1, end: 2, text: "Hold this.")],
                        sampleText: "Hold this."
                    ).stamped(withWavAt: temp)
                )
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )

        let deleteReachedLock = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        var skipFirstAcquire = true
        SpeakerClipExtractor.persistLockWillAcquire = { id in
            guard id == speakerId else { return }
            if skipFirstAcquire { return }
            deleteReachedLock.signal()
        }
        defer { SpeakerClipExtractor.persistLockWillAcquire = nil }

        SpeakerClipExtractor.withPersistLock(for: speakerId) {
            skipFirstAcquire = false
            DispatchQueue.global(qos: .userInitiated).async {
                SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: directory)
                deleteFinished.signal()
            }
            XCTAssertEqual(
                deleteReachedLock.wait(timeout: .now() + 5),
                .success,
                "delete must take the same per-profile lock as save"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: persisted.path),
                "delete must not remove the clip while save holds the profile lock"
            )
            releaseLock.signal()
        }
        _ = releaseLock.wait(timeout: .now() + 5)
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persisted.path))
    }

    func testFailedMergeTransferLeavesTheSourceClip() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceId = UUID()
        let targetId = UUID()
        let sourceTemp = try writeTempClip(named: "keep-source.wav", in: directory, bytes: Data([4, 5, 6]))
        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: sourceTemp,
                speakerId: sourceId,
                clipsDirectory: directory,
                sidecar: try XCTUnwrap(
                    SpeakerClipSidecar(
                        channel: "system",
                        diarizerSpeakerId: "1",
                        segments: [.init(start: 1, end: 2, text: "Only copy.")],
                        sampleText: "Only copy."
                    ).stamped(withWavAt: sourceTemp)
                )
            )
        )
        let sourceClip = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: sourceId, clipsDirectory: directory)
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
        }
        XCTAssertEqual(
            SpeakerClipExtractor.transferOnMerge(
                from: sourceId,
                to: targetId,
                clipsDirectory: directory
            ),
            .failed,
            "a silent persist failure must not report success"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceClip.path))
        XCTAssertEqual(
            SpeakerClipSidecar.loadMatchingWav(nextTo: sourceClip)?.sampleText,
            "Only copy.",
            "merge must not delete the source clip after a failed copy"
        )
        XCTAssertNil(
            SpeakerClipExtractor.persistentClipURL(for: targetId, clipsDirectory: directory)
        )
    }

    func testWavIdentityCacheFollowsSizeAndMtime() throws {
        let directory = temporaryClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeTempClip(named: "cached.wav", in: directory, bytes: Data([1, 1, 1, 1]))

        let first = try XCTUnwrap(SpeakerClipSidecar.wavIdentity(of: url))
        let again = try XCTUnwrap(SpeakerClipSidecar.wavIdentity(of: url))
        XCTAssertEqual(first.sha256, again.sha256)

        try Data([2, 2, 2, 2, 2]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: url.path
        )
        let updated = try XCTUnwrap(SpeakerClipSidecar.wavIdentity(of: url))
        XCTAssertNotEqual(updated.sha256, first.sha256)
        XCTAssertEqual(updated.byteCount, 5)
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
