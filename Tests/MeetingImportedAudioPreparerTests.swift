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
                .modificationDate: sourceRecordingDate.addingTimeInterval(86_400)
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
