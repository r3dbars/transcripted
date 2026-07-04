import AVFoundation
import Foundation
import UniformTypeIdentifiers

func testMeetingImportedAudioPreparer() async {
    await runSuite("MeetingImportedAudioPreparer gives a stable missing-file error") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("missing.m4a")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)

        await assertImportedAudioPreparationError(
            .fileMissing,
            sourceURL: sourceURL,
            scratchURL: scratchURL
        )
    }

    await runSuite("MeetingImportedAudioPreparer rejects folders with import-specific copy") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("folder.wav", isDirectory: true)
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        try! FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        await assertImportedAudioPreparationError(
            .notRegularFile,
            sourceURL: sourceURL,
            scratchURL: scratchURL
        )
    }

    await runSuite("MeetingImportedAudioPreparer rejects non-audio files before copying") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("notes.txt")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! "not audio".write(to: sourceURL, atomically: true, encoding: .utf8)

        await assertImportedAudioPreparationError(
            .unsupportedAudioType,
            sourceURL: sourceURL,
            scratchURL: scratchURL
        )
    }

    await runSuite("MeetingImportedAudioPreparer copies audio-looking files into scratch") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("Customer_Call-1.wav")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        let sourceRecordingDate = Date(timeIntervalSince1970: 1_704_067_200)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data([0, 1, 2, 3]))
        try! FileManager.default.setAttributes(
            [
                .creationDate: sourceRecordingDate,
                .modificationDate: sourceRecordingDate.addingTimeInterval(86_400),
                .posixPermissions: 0o644
            ],
            ofItemAtPath: sourceURL.path
        )

        let prepared = try! await MeetingImportedAudioPreparer.prepareImportedAudio(
            from: sourceURL,
            scratchDirectory: scratchURL
        )

        assertTrue(
            FileManager.default.fileExists(atPath: prepared.copiedAudioURL.path),
            "audio import should copy the selected file into app-owned scratch"
        )
        assertEqual(prepared.copiedAudioURL.deletingPathExtension().lastPathComponent.hasPrefix("imported-"), true, "scratch filenames should be app-owned")
        assertEqual(prepared.suggestedTitle, "Customer Call 1", "import title should come from the selected filename")
        assertTrue(
            abs(prepared.recordingDate.timeIntervalSince(sourceRecordingDate)) < 1,
            "import metadata should use the source file creation date instead of the scratch-copy date"
        )
        assertEqual(
            importedAudioFilePermissions(of: prepared.copiedAudioURL),
            NSNumber(value: 0o600),
            "scratch copy should be restricted to the owner"
        )
        assertEqual(
            importedAudioFilePermissions(of: sourceURL),
            NSNumber(value: 0o644),
            "preparing imported audio should not mutate the user's source file permissions"
        )
    }

    runSuite("MeetingImportedAudioPreparer accepts common movie recording types") {
        assertEqual(
            try! MeetingImportedAudioPreparer.importMediaKind(for: .mpeg4Movie),
            .audiovisual,
            "MP4 movie recordings should be eligible for audio extraction"
        )
        assertEqual(
            try! MeetingImportedAudioPreparer.importMediaKind(for: .quickTimeMovie),
            .audiovisual,
            "MOV movie recordings should be eligible for audio extraction"
        )
        assertEqual(
            try! MeetingImportedAudioPreparer.importMediaKind(for: .mpeg4Audio),
            .audio,
            "M4A audio imports should keep the normal copy path"
        )
    }

    await runSuite("MeetingImportedAudioPreparer extracts audio-bearing movie containers into scratch") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("Zoom_Local_Recording.mp4")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        let sourceRecordingDate = Date(timeIntervalSince1970: 1_704_153_600)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! writeSilentMPEG4AudioFixture(toMovieURL: sourceURL)
        try! FileManager.default.setAttributes(
            [
                .creationDate: sourceRecordingDate,
                .modificationDate: sourceRecordingDate,
                .posixPermissions: 0o644
            ],
            ofItemAtPath: sourceURL.path
        )

        let prepared = try! await MeetingImportedAudioPreparer.prepareImportedAudio(
            from: sourceURL,
            scratchDirectory: scratchURL
        )

        assertTrue(
            FileManager.default.fileExists(atPath: prepared.copiedAudioURL.path),
            "movie import should write an extracted audio file into app-owned scratch"
        )
        assertEqual(prepared.copiedAudioURL.pathExtension.lowercased(), "m4a", "movie imports should transcode to m4a for transcription")
        assertEqual(prepared.suggestedTitle, "Zoom Local Recording", "import title should still come from the selected movie filename")
        assertEqual(
            importedAudioFilePermissions(of: prepared.copiedAudioURL),
            NSNumber(value: 0o600),
            "extracted movie audio should be restricted to the owner"
        )
        assertEqual(
            importedAudioFilePermissions(of: sourceURL),
            NSNumber(value: 0o644),
            "preparing movie imports should not mutate the user's source file permissions"
        )

        let extractedAsset = AVURLAsset(url: prepared.copiedAudioURL)
        let extractedTracks = try! await extractedAsset.loadTracks(withMediaType: .audio)
        assertFalse(extractedTracks.isEmpty, "extracted scratch audio should have a readable audio track")
    }

    await runSuite("MeetingImportedAudioPreparer rejects movie containers without audio") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("screen_share_only.mov")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data())

        await assertImportedAudioPreparationError(
            .unsupportedAudioType,
            sourceURL: sourceURL,
            scratchURL: scratchURL
        )

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratchURL.path)) ?? []
        assertTrue(
            leftovers.filter { $0.hasPrefix("imported-") }.isEmpty,
            "unsupported movie imports must not leave scratch audio behind"
        )
    }

    runSuite("MeetingImportedAudioPreparer keeps timezone-less metadata on the local calendar day") {
        let localTimeZone = TimeZone(secondsFromGMT: -6 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localTimeZone

        let dateOnly = MeetingImportedAudioPreparer.parseMetadataDate(
            "2025-02-03",
            defaultTimeZone: localTimeZone
        )!
        assertEqual(calendar.component(.year, from: dateOnly), 2025, "date-only metadata should keep the local year")
        assertEqual(calendar.component(.month, from: dateOnly), 2, "date-only metadata should keep the local month")
        assertEqual(calendar.component(.day, from: dateOnly), 3, "date-only metadata should not shift to the previous local day")

        let localDateTime = MeetingImportedAudioPreparer.parseMetadataDate(
            "2025-02-03 09:15:00",
            defaultTimeZone: localTimeZone
        )!
        assertEqual(calendar.component(.day, from: localDateTime), 3, "timezone-less datetime should keep the local day")
        assertEqual(calendar.component(.hour, from: localDateTime), 9, "timezone-less datetime should keep the local hour")
        assertEqual(calendar.component(.minute, from: localDateTime), 15, "timezone-less datetime should keep the local minute")
    }

    await runSuite("MeetingImportedAudioPreparer prefers string metadata before AVFoundation dateValue") {
        let localTimeZone = TimeZone(secondsFromGMT: -6 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localTimeZone
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierCreationDate
        item.value = "2025-02-03" as NSString

        let parsed = await MeetingImportedAudioPreparer.metadataDate(
            item,
            defaultTimeZone: localTimeZone
        )!

        assertEqual(calendar.component(.year, from: parsed), 2025, "string metadata should not use AVFoundation's bogus dateValue")
        assertEqual(calendar.component(.month, from: parsed), 2, "string metadata should preserve the month")
        assertEqual(calendar.component(.day, from: parsed), 3, "string metadata should preserve the local day")
    }

    runSuite("MeetingImportedAudioPreparer parses ISO8601 metadata with fractional seconds and Z suffix") {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let parsed = MeetingImportedAudioPreparer.parseMetadataDate(
            "2025-02-03T09:15:00.500Z",
            defaultTimeZone: utc
        )!

        assertEqual(calendar.component(.year, from: parsed), 2025, "fractional ISO date should parse the year")
        assertEqual(calendar.component(.month, from: parsed), 2, "fractional ISO date should parse the month")
        assertEqual(calendar.component(.day, from: parsed), 3, "fractional ISO date should parse the day")
        assertEqual(calendar.component(.hour, from: parsed), 9, "fractional ISO date should parse the UTC hour")
        assertEqual(calendar.component(.minute, from: parsed), 15, "fractional ISO date should parse the minute")
    }

    runSuite("MeetingImportedAudioPreparer honors explicit ISO8601 timezone offsets") {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        // 2025-02-03 09:15:00 at -05:00 is 2025-02-03 14:15:00 UTC.
        let parsed = MeetingImportedAudioPreparer.parseMetadataDate(
            "2025-02-03T09:15:00-0500",
            defaultTimeZone: utc
        )!

        assertEqual(calendar.component(.day, from: parsed), 3, "explicit-offset ISO date should keep the calendar day in UTC")
        assertEqual(calendar.component(.hour, from: parsed), 14, "explicit-offset ISO date should resolve into UTC, not the default timezone")
    }

    runSuite("MeetingImportedAudioPreparer rejects empty and unparseable metadata strings") {
        let utc = TimeZone(secondsFromGMT: 0)!

        assertNil(
            MeetingImportedAudioPreparer.parseMetadataDate("", defaultTimeZone: utc),
            "empty metadata strings should not produce a date"
        )
        assertNil(
            MeetingImportedAudioPreparer.parseMetadataDate("   \n\t  ", defaultTimeZone: utc),
            "whitespace-only metadata should not produce a date"
        )
        assertNil(
            MeetingImportedAudioPreparer.parseMetadataDate("banana", defaultTimeZone: utc),
            "unrecognized tokens should not produce a date so the resolver falls back to the file system"
        )
    }

    runSuite("MeetingImportedAudioPreparer treats only genuine recording tags as recording dates") {
        assertTrue(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "comn/creationdate"),
            "the common creation-date tag is a recording date"
        )
        assertTrue(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "id3/tdrc recordingtime"),
            "the ID3 recording-time frame is a recording date"
        )
        assertTrue(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "quicktimemetadatacreationdate"),
            "the QuickTime creation-date tag is a recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "itsk/purchasedate"),
            "an iTunes purchase date must never be treated as the recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "id3/tenc encodingtime"),
            "an encode time must never be treated as the recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "id3/tdtg taggingtime"),
            "a tagging time must never be treated as the recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "id3/tdrl releasetime"),
            "a release date must never be treated as the recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "albumreleasedate"),
            "an album release date must never be treated as the recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "modificationdate"),
            "a modification date is not a recording date for matching purposes"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isRecordingDateMetadata(keyString: "title"),
            "non-date metadata is not a recording date"
        )
    }

    runSuite("MeetingImportedAudioPreparer ranks explicit creation tags above looser recording tags") {
        assertEqual(
            MeetingImportedAudioPreparer.recordingDatePriority(forKeyString: "comn/creationdate"),
            0,
            "explicit creation tags rank highest"
        )
        assertEqual(
            MeetingImportedAudioPreparer.recordingDatePriority(forKeyString: "id3/tdrc recordingtime"),
            1,
            "recording-time tags rank below explicit creation tags"
        )
        assertEqual(
            MeetingImportedAudioPreparer.recordingDatePriority(forKeyString: "somethingelse"),
            2,
            "anything else ranks last"
        )
    }

    runSuite("MeetingImportedAudioPreparer uses the earliest reliable file-system timestamp") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recordedDay = now.addingTimeInterval(-90 * 86_400)
        let laterEdit = recordedDay.addingTimeInterval(3_600)
        let dummy = URL(fileURLWithPath: "/dev/null")

        let resolved = MeetingImportedAudioPreparer.reliableFilesystemDate(
            from: dummy,
            sourceAttributes: [.creationDate: recordedDay, .modificationDate: laterEdit],
            now: now
        )
        assertNotNil(resolved, "an old creation date is reliable")
        assertTrue(
            abs(resolved!.timeIntervalSince(recordedDay)) < 1,
            "the earliest reliable timestamp should win"
        )
    }

    runSuite("MeetingImportedAudioPreparer ignores a copy-time creation date but keeps a preserved mtime") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let copyTime = now.addingTimeInterval(-5)
        let originalRecording = now.addingTimeInterval(-30 * 86_400)
        let dummy = URL(fileURLWithPath: "/dev/null")

        let resolved = MeetingImportedAudioPreparer.reliableFilesystemDate(
            from: dummy,
            sourceAttributes: [.creationDate: copyTime, .modificationDate: originalRecording],
            now: now
        )
        assertNotNil(resolved, "a preserved modification date is still usable")
        assertTrue(
            abs(resolved!.timeIntervalSince(originalRecording)) < 1,
            "a copy-time creation date must not win over the preserved recording time"
        )
    }

    runSuite("MeetingImportedAudioPreparer reports no reliable date when every timestamp is the import act") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dummy = URL(fileURLWithPath: "/dev/null")

        let resolved = MeetingImportedAudioPreparer.reliableFilesystemDate(
            from: dummy,
            sourceAttributes: [
                .creationDate: now.addingTimeInterval(-3),
                .modificationDate: now.addingTimeInterval(-1)
            ],
            now: now
        )
        assertNil(
            resolved,
            "a freshly downloaded file has no reliable source date, so the caller falls back to the import date"
        )
    }

    runSuite("MeetingImportedAudioPreparer rejects implausible embedded dates") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        assertTrue(
            MeetingImportedAudioPreparer.isPlausibleEmbeddedDate(now.addingTimeInterval(-30 * 86_400), now: now),
            "a recent embedded recording date is plausible"
        )
        assertTrue(
            MeetingImportedAudioPreparer.isPlausibleEmbeddedDate(now.addingTimeInterval(30), now: now),
            "minor forward clock skew should still be accepted"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isPlausibleEmbeddedDate(Date(timeIntervalSince1970: 0), now: now),
            "the 1970 Unix epoch is a sentinel, not a recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isPlausibleEmbeddedDate(Date(timeIntervalSince1970: -2_082_844_800), now: now),
            "the 1904 QuickTime epoch is a sentinel, not a recording date"
        )
        assertFalse(
            MeetingImportedAudioPreparer.isPlausibleEmbeddedDate(now.addingTimeInterval(3_600), now: now),
            "a date an hour in the future is never a real recording time"
        )
    }

    await runSuite("MeetingImportedAudioPreparer prefers a preserved recording time over the copy date end-to-end") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("Downloaded_Call.wav")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        let originalRecording = Date().addingTimeInterval(-45 * 86_400)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data([0, 1, 2, 3]))
        try! FileManager.default.setAttributes(
            [
                .creationDate: Date(),
                .modificationDate: originalRecording,
                .posixPermissions: 0o644
            ],
            ofItemAtPath: sourceURL.path
        )

        let prepared = try! await MeetingImportedAudioPreparer.prepareImportedAudio(
            from: sourceURL,
            scratchDirectory: scratchURL
        )

        assertTrue(
            abs(prepared.recordingDate.timeIntervalSince(originalRecording)) < 2,
            "imported audio should use the preserved recording time, not the copy/download date"
        )
    }

    await runSuite("MeetingImportedAudioPreparer cancels an in-flight import and leaves no scratch artifact") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("Long_Call.wav")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A few MB so the chunked copy has real work to interrupt.
        FileManager.default.createFile(
            atPath: sourceURL.path,
            contents: Data(repeating: 7, count: 4 * (1 << 20))
        )

        // Cancelling synchronously before the detached task starts running means
        // the preparer observes cancellation before it copies anything.
        let task = Task.detached {
            try await MeetingImportedAudioPreparer.prepareImportedAudio(
                from: sourceURL,
                scratchDirectory: scratchURL
            )
        }
        task.cancel()

        var threwCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {
            assertTrue(false, "a cancelled import should throw CancellationError, got \(error)")
        }
        assertTrue(threwCancellation, "cancelling an in-flight import should stop the work")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratchURL.path)) ?? []
        let importedLeftovers = leftovers.filter { $0.hasPrefix("imported-") }
        assertTrue(
            importedLeftovers.isEmpty,
            "a cancelled import must not leave a partial scratch copy behind, found \(importedLeftovers)"
        )
    }

    await runSuite("MeetingImportedAudioPreparer copy removes the partial destination when cancelled") {
        let root = temporaryImportAudioPreparerRoot()
        let sourceURL = root.appendingPathComponent("source.wav")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        let destinationURL = scratchURL.appendingPathComponent("imported-partial.wav")
        try! FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sourceURL.path,
            contents: Data(repeating: 3, count: 4 * (1 << 20))
        )

        let task = Task.detached {
            try MeetingImportedAudioPreparer.copyInterruptibly(
                from: sourceURL,
                to: destinationURL,
                fileManager: FileManager.default,
                chunkSize: 4096
            )
        }
        task.cancel()

        var threwCancellation = false
        do {
            try await task.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {
            assertTrue(false, "a cancelled copy should throw CancellationError, got \(error)")
        }
        assertTrue(threwCancellation, "cancelling the copy should interrupt it")
        assertFalse(
            FileManager.default.fileExists(atPath: destinationURL.path),
            "a cancelled copy must remove the partial destination file"
        )
    }
}

private func assertImportedAudioPreparationError(
    _ expected: MeetingImportedAudioPreparationError,
    sourceURL: URL,
    scratchURL: URL
) async {
    do {
        _ = try await MeetingImportedAudioPreparer.prepareImportedAudio(
            from: sourceURL,
            scratchDirectory: scratchURL
        )
        assertTrue(false, "expected imported-audio preparation to fail")
    } catch let error as MeetingImportedAudioPreparationError {
        assertEqual(error, expected, "import prep should preserve a typed error")
        assertEqual(
            error.diagnosticKind,
            expected.diagnosticKind,
            "typed import errors should expose a stable privacy-safe diagnostic kind"
        )
        assertNotNil(error.errorDescription, "typed import errors should have user-facing copy")
    } catch {
        assertTrue(false, "expected MeetingImportedAudioPreparationError, got \(error)")
    }
}

private func temporaryImportAudioPreparerRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "MeetingImportedAudioPreparerTests-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func importedAudioFilePermissions(of url: URL) -> NSNumber? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.posixPermissions] as? NSNumber
}

private func writeSilentMPEG4AudioFixture(toMovieURL movieURL: URL) throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/imported-movie-audio-track.mp4.base64")
    let encoded = try String(contentsOf: fixtureURL, encoding: .utf8)
    let compactEncoded = encoded.replacingOccurrences(
        of: "\\s",
        with: "",
        options: .regularExpression
    )
    guard let data = Data(base64Encoded: compactEncoded) else {
        throw NSError(
            domain: "MeetingImportedAudioPreparerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid MPEG-4 audio fixture"]
        )
    }
    try data.write(to: movieURL, options: .atomic)
}
