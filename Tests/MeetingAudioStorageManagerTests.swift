import Foundation

func testMeetingAudioStorageManager() async {
    await runSuite("MeetingAudioStorageManager converts WAVs to M4A before deleting originals") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Customer Call", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("system_audio.wav")
        try! Data("wav".utf8).write(to: wavURL)

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 1, "one WAV file should be converted")
        assertFalse(FileManager.default.fileExists(atPath: wavURL.path), "original WAV should be removed after conversion")
        assertTrue(
            FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent("system_audio.m4a").path),
            "compressed M4A should exist"
        )
    }

    await runSuite("MeetingAudioStorageManager keeps WAVs when conversion fails") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Risky Call", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("microphone.wav")
        try! Data("wav".utf8).write(to: wavURL)

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(shouldFail: true),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 0, "failed conversion should not count as converted")
        assertTrue(FileManager.default.fileExists(atPath: wavURL.path), "WAV should remain when conversion fails")
        assertFalse(
            FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent("microphone.m4a").path),
            "failed conversion should not leave a final M4A"
        )
    }

    await runSuite("MeetingAudioStorageManager does not trust unusable existing M4A files") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Invalid Existing Audio", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("recording.wav")
        let m4aURL = audioDirectory.appendingPathComponent("recording.m4a")
        try! Data("wav".utf8).write(to: wavURL)
        try! Data("not audio".utf8).write(to: m4aURL)

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 1, "invalid existing M4A should be replaced by a fresh conversion")
        assertFalse(FileManager.default.fileExists(atPath: wavURL.path), "WAV should be removed only after replacement succeeds")
        assertEqual(try? Data(contentsOf: m4aURL), Data("m4a".utf8), "existing invalid M4A should be replaced")
    }

    await runSuite("MeetingAudioStorageManager keeps WAVs when converted M4A is unusable") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Bad Conversion", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("recording.wav")
        try! Data("wav".utf8).write(to: wavURL)

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(output: Data("bad".utf8)),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 0, "unusable converted audio should not count as converted")
        assertTrue(FileManager.default.fileExists(atPath: wavURL.path), "WAV should remain when validation fails")
        assertFalse(
            FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent("recording.m4a").path),
            "bad temp output should not be promoted to final M4A"
        )
    }

    await runSuite("MeetingAudioStorageManager removes WAV when existing M4A is already usable") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Already Converted", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("recording.wav")
        try! Data("wav".utf8).write(to: wavURL)
        try! Data("m4a".utf8).write(to: audioDirectory.appendingPathComponent("recording.m4a"))

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(shouldFail: true),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 0, "already converted audio should not run conversion again")
        assertFalse(FileManager.default.fileExists(atPath: wavURL.path), "duplicate WAV should be removed when M4A is usable")
    }

    runSuite("MeetingAudioStorageManager prunes retained audio by transcript age") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldTranscript = try! makeTranscript(named: "Old Call", in: directory, ageDays: 8)
        let newTranscript = try! makeTranscript(named: "New Call", in: directory, ageDays: 2)
        let oldAudio = makeAudioDirectory(for: oldTranscript)
        let newAudio = makeAudioDirectory(for: newTranscript)
        try! Data("m4a".utf8).write(to: oldAudio.appendingPathComponent("recording.m4a"))
        try! Data("m4a".utf8).write(to: newAudio.appendingPathComponent("recording.m4a"))

        let removed = MeetingAudioStorageManager.pruneRetainedAudio(
            in: directory,
            retentionWindow: .sevenDays,
            now: Date()
        )

        assertEqual(removed, 1, "only old retained audio should be deleted")
        assertFalse(FileManager.default.fileExists(atPath: oldAudio.path), "old audio directory should be removed")
        assertTrue(FileManager.default.fileExists(atPath: oldTranscript.path), "old transcript should stay")
        assertTrue(FileManager.default.fileExists(atPath: newAudio.path), "new audio directory should stay")
    }

    runSuite("MeetingAudioStorageManager never window does not prune") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Archive Call", in: directory, ageDays: 90)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        try! Data("m4a".utf8).write(to: audioDirectory.appendingPathComponent("recording.m4a"))

        let removed = MeetingAudioStorageManager.pruneRetainedAudio(
            in: directory,
            retentionWindow: .never,
            now: Date()
        )

        assertEqual(removed, 0, "never should not delete retained audio")
        assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "audio directory should remain")
    }

    await runSuite("MeetingAudioStorageManager backfills existing transcript audio") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Existing Call", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("recording.wav")
        try! Data("wav".utf8).write(to: wavURL)

        let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
            in: directory,
            retentionWindow: .never,
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(
            result,
            MeetingAudioStorageMaintenanceResult(scannedDirectories: 1, convertedFiles: 1, prunedDirectories: 0),
            "existing transcript audio should be scanned and compressed"
        )
        assertFalse(FileManager.default.fileExists(atPath: wavURL.path), "old WAV should be removed after backfill conversion")
        assertTrue(
            FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent("recording.m4a").path),
            "backfill should leave compressed audio"
        )
    }

    await runSuite("MeetingAudioStorageManager skips failed audio without a transcript") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let failedAudioDirectory = directory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("Failed_2026-05-04_audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: failedAudioDirectory, withIntermediateDirectories: true)
        let wavURL = failedAudioDirectory.appendingPathComponent("recording.wav")
        try! Data("wav".utf8).write(to: wavURL)

        let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
            in: directory,
            retentionWindow: .sevenDays,
            now: Date(),
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(
            result,
            MeetingAudioStorageMaintenanceResult(scannedDirectories: 0, convertedFiles: 0, prunedDirectories: 0),
            "failed or orphaned audio should not be managed by transcript retention"
        )
        assertTrue(FileManager.default.fileExists(atPath: wavURL.path), "failed WAV should remain for the retry/delete flow")
    }

    await runSuite("MeetingAudioStorageManager prunes old WAVs before backfill conversion") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Old WAV Call", in: directory, ageDays: 31)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("recording.wav")
        try! Data("wav".utf8).write(to: wavURL)

        let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
            in: directory,
            retentionWindow: .thirtyDays,
            now: Date(),
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(
            result,
            MeetingAudioStorageMaintenanceResult(scannedDirectories: 0, convertedFiles: 0, prunedDirectories: 1),
            "old retained WAV audio should be deleted directly instead of compressed first"
        )
        assertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "old audio directory should be removed")
        assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "old transcript should stay")
    }
}

private struct FakeMeetingAudioConverter: MeetingAudioFileConverting {
    var shouldFail = false
    var output = Data("m4a".utf8)

    func convertWAVToM4A(sourceURL: URL, destinationURL: URL) async throws {
        if shouldFail {
            throw MeetingAudioStorageError.conversionFailed
        }
        try output.write(to: destinationURL)
    }
}

private struct FakeMeetingAudioValidator: MeetingAudioFileValidating {
    func isUsableAudioFile(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return (try? Data(contentsOf: url)) == Data("m4a".utf8)
    }
}

private func makeMeetingAudioStorageTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingAudioStorageManagerTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeTranscript(named name: String, in directory: URL, ageDays: Int) throws -> URL {
    let url = directory.appendingPathComponent(name).appendingPathExtension("md")
    try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
    let date = Calendar.current.date(byAdding: .day, value: -ageDays, to: Date())!
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}

private func makeAudioDirectory(for transcriptURL: URL) -> URL {
    let directory = transcriptURL
        .deletingLastPathComponent()
        .appendingPathComponent("audio", isDirectory: true)
        .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
