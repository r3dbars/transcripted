import AVFoundation
import Foundation

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
