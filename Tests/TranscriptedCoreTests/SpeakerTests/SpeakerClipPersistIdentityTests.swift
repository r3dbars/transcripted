import AVFoundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerClipPersistIdentityTests: XCTestCase {
    func testPersistDoesNotRestampASameSizeSameMtimeReplace() throws {
        let directory = temporaryIdentityClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let firstBytes = Data([1, 2, 3, 4])
        let firstTemp = try writeIdentityTempClip(named: "first.wav", in: directory, bytes: firstBytes)
        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: firstTemp,
                speakerId: speakerId,
                clipsDirectory: directory,
                sidecar: try stampedIdentitySidecar(
                    nextTo: firstTemp,
                    text: "Words from the first wav."
                )
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        XCTAssertEqual(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted)?.sampleText,
            "Words from the first wav."
        )

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: persisted.path)
        let originalMtime = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        XCTAssertEqual((originalAttributes[.size] as? NSNumber)?.intValue, firstBytes.count)
        _ = SpeakerClipSidecar.wavIdentity(of: persisted)

        let replacement = Data([9, 8, 7, 6])
        XCTAssertEqual(replacement.count, firstBytes.count)
        try replacement.write(to: persisted)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMtime],
            ofItemAtPath: persisted.path
        )
        let restored = try FileManager.default.attributesOfItem(atPath: persisted.path)
        XCTAssertEqual((restored[.size] as? NSNumber)?.intValue, firstBytes.count)
        let restoredMtime = try XCTUnwrap(restored[.modificationDate] as? Date)
        XCTAssertEqual(
            Int(restoredMtime.timeIntervalSince1970),
            Int(originalMtime.timeIntervalSince1970),
            "the replace must keep the original modification second so a size+mtime cache would still hit"
        )

        XCTAssertNil(
            SpeakerClipSidecar.acceptedIncoming(
                SpeakerClipSidecar.load(nextTo: persisted),
                matchingSourceAt: persisted
            ),
            "same size and mtime must not reuse a cached hash to accept the old quote"
        )

        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: persisted,
                speakerId: speakerId,
                clipsDirectory: directory
            )
        )
        XCTAssertEqual(try Data(contentsOf: persisted), replacement)
        XCTAssertNil(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted),
            "saving the replaced bytes must not recertify the previous clip's quote"
        )
    }

    func testPersistDropsAnUnboundSidecar() throws {
        let directory = temporaryIdentityClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let speakerId = UUID()
        let temp = try writeIdentityTempClip(named: "unbound.wav", in: directory, bytes: Data([2, 4, 6]))
        let unbound = SpeakerClipSidecar(
            channel: "system",
            diarizerSpeakerId: "1",
            segments: [.init(start: 1, end: 3, text: "No size or hash.")],
            sampleText: "No size or hash."
        )
        XCTAssertEqual(unbound.wavByteCount, 0)
        XCTAssertEqual(unbound.wavSHA256, "")
        XCTAssertNil(
            SpeakerClipSidecar.acceptedIncoming(unbound, matchingSourceAt: temp),
            "a sidecar with no size or hash is not this wav's quote"
        )

        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: temp,
                speakerId: speakerId,
                clipsDirectory: directory,
                sidecar: unbound
            )
        )
        let persisted = try XCTUnwrap(
            SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: directory)
        )
        XCTAssertEqual(try Data(contentsOf: persisted), Data([2, 4, 6]))
        XCTAssertNil(
            SpeakerClipSidecar.loadMatchingWav(nextTo: persisted),
            "an unbound sidecar must not be stamped onto the saved wav"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: SpeakerClipSidecar.url(nextTo: persisted).path)
        )
    }

    func testExtractClipsDropsTheQuoteWhenTheWriterReadsShort() throws {
        let directory = temporaryIdentityClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = SpeakerDatabase(path: directory.appendingPathComponent("speakers.sqlite").path)
        let profile = db.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil)
        let sourceURL = directory.appendingPathComponent("short-source.wav")
        try writeIdentitySilentWav(to: sourceURL, seconds: 0.5, sampleRate: 16_000)

        let results = try SpeakerClipExtractor.extractClips(
            sourceAudioURL: sourceURL,
            utterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 4,
                    channel: 1,
                    speakerId: 1,
                    persistentSpeakerId: profile.id,
                    matchSimilarity: nil,
                    transcript: "Full turn that was not fully written."
                )
            ],
            channel: .system,
            speakerDB: db,
            clipsDirectory: directory
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(
            results[0].sampleText,
            "",
            "the writer must drop the planned quote when it could not keep the whole turn"
        )
        let clip = results[0].clipURL
        XCTAssertEqual(
            SpeakerClipSidecar.loadMatchingWav(nextTo: clip)?.sampleText,
            "",
            "the sidecar next to the written wav must not keep the unread remainder's text"
        )
        XCTAssertFalse(
            (SpeakerClipSidecar.loadMatchingWav(nextTo: clip)?.sampleText ?? "")
                .contains("Full turn that was not fully written.")
        )
    }

    func testWavIdentityCacheMissesASameSizeSameMtimeReplace() throws {
        let directory = temporaryIdentityClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try writeIdentityTempClip(named: "display.wav", in: directory, bytes: Data([1, 1, 1, 1]))
        let first = try XCTUnwrap(SpeakerClipSidecar.wavIdentity(of: url))
        let originalMtime = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        )

        try Data([2, 2, 2, 2]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMtime],
            ofItemAtPath: url.path
        )
        let updated = try XCTUnwrap(SpeakerClipSidecar.wavIdentity(of: url))
        XCTAssertEqual(updated.byteCount, 4)
        XCTAssertNotEqual(
            updated.sha256,
            first.sha256,
            "display identity must not treat a same-size same-mtime replace as the old bytes"
        )
    }

    func testWavIdentityCacheDropsTheOldestEntries() throws {
        let directory = temporaryIdentityClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<80 {
            let url = try writeIdentityTempClip(
                named: "cached-\(index).wav",
                in: directory,
                bytes: Data([UInt8(index & 0xFF), 1, 2, 3])
            )
            XCTAssertNotNil(SpeakerClipSidecar.wavIdentity(of: url))
        }
        XCTAssertLessThanOrEqual(
            WavIdentityCache.cachedPathCount,
            64,
            "the display identity cache must stay bounded"
        )
    }

    func testTransferOnMergeChecksTargetClipUnderTheSameLock() throws {
        let directory = temporaryIdentityClipsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceId = UUID()
        let targetId = UUID()
        let sourceTemp = try writeIdentityTempClip(
            named: "source.wav",
            in: directory,
            bytes: Data([4, 5, 6])
        )
        XCTAssertTrue(
            SpeakerClipExtractor.persistClip(
                from: sourceTemp,
                speakerId: sourceId,
                clipsDirectory: directory,
                sidecar: try stampedIdentitySidecar(nextTo: sourceTemp, text: "Only copy.")
            )
        )

        let transferReachedLock = DispatchSemaphore(value: 0)
        let transferFinished = DispatchSemaphore(value: 0)
        let transferResult = TransferLockResult()
        var skipFirstAcquire = true
        SpeakerClipExtractor.persistLockWillAcquire = { id in
            guard id == targetId else { return }
            if skipFirstAcquire { return }
            transferReachedLock.signal()
        }
        defer { SpeakerClipExtractor.persistLockWillAcquire = nil }

        let targetClip = directory.appendingPathComponent("\(targetId.uuidString).wav")
        SpeakerClipExtractor.withPersistLock(for: targetId) {
            skipFirstAcquire = false
            DispatchQueue.global(qos: .userInitiated).async {
                let copied = SpeakerClipExtractor.transferOnMerge(
                    from: sourceId,
                    to: targetId,
                    clipsDirectory: directory
                )
                transferResult.set(copied)
                transferFinished.signal()
            }
            XCTAssertEqual(
                transferReachedLock.wait(timeout: .now() + 5),
                .success,
                "transfer must take the target profile lock before the has-clip check"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: targetClip.path))
            do {
                try Data([9, 9, 9]).write(to: targetClip)
            } catch {
                XCTFail("could not write the target clip while transfer waits: \(error)")
            }
        }
        XCTAssertEqual(transferFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(transferResult.get(), true)
        XCTAssertEqual(
            try Data(contentsOf: targetClip),
            Data([9, 9, 9]),
            "a target clip that appears under the lock must not be overwritten"
        )
    }
}

private final class TransferLockResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func temporaryIdentityClipsDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakerClipPersistIdentityTests-\(UUID().uuidString)", isDirectory: true)
}

private func writeIdentityTempClip(
    named name: String,
    in directory: URL,
    bytes: Data
) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
}

private func stampedIdentitySidecar(nextTo url: URL, text: String) throws -> SpeakerClipSidecar {
    let sidecar = SpeakerClipSidecar(
        channel: "system",
        diarizerSpeakerId: "1",
        segments: [.init(start: 1, end: 3, text: text)],
        sampleText: text
    )
    return try XCTUnwrap(sidecar.stamped(withWavAt: url))
}

private func writeIdentitySilentWav(to url: URL, seconds: Double, sampleRate: Double) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let format = try XCTUnwrap(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ))
    let frames = Int(seconds * sampleRate)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0, count: frames)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
