import Foundation

func testMeetingAudioStorageManager() async {
    await runSuite("MeetingAudioStorageManager converts WAVs to M4A before deleting originals") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Customer Call", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let wavURL = audioDirectory.appendingPathComponent("system_audio.wav")
        let m4aURL = audioDirectory.appendingPathComponent("system_audio.m4a")
        try! Data("wav".utf8).write(to: wavURL)

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 1, "one WAV file should be converted")
        assertFalse(FileManager.default.fileExists(atPath: wavURL.path), "original WAV should be removed after conversion")
        assertTrue(
            FileManager.default.fileExists(atPath: m4aURL.path),
            "compressed M4A should exist"
        )
        assertEqual(posixPermissions(at: m4aURL), 0o600, "converted audio should be restricted to the owner")
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
        let m4aURL = audioDirectory.appendingPathComponent("recording.m4a")
        try! Data("wav".utf8).write(to: wavURL)
        try! Data("m4a".utf8).write(to: m4aURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: m4aURL.path)

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(shouldFail: true),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 0, "already converted audio should not run conversion again")
        assertFalse(FileManager.default.fileExists(atPath: wavURL.path), "duplicate WAV should be removed when M4A is usable")
        assertEqual(posixPermissions(at: m4aURL), 0o600, "existing retained M4A should be tightened before deleting WAV")
    }

    await runSuite("MeetingAudioStorageManager tightens M4A-only retained audio") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "M4A Only", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let m4aURL = audioDirectory.appendingPathComponent("recording.m4a")
        try! Data("m4a".utf8).write(to: m4aURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: m4aURL.path)

        let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
            in: directory,
            retentionWindow: .never,
            converter: FakeMeetingAudioConverter(shouldFail: true),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(
            result,
            MeetingAudioStorageMaintenanceResult(scannedDirectories: 1, convertedFiles: 0, prunedDirectories: 0),
            "M4A-only archives should still be scanned for permission hardening"
        )
        assertEqual(posixPermissions(at: m4aURL), 0o600, "existing retained M4A should be owner-only")
    }

    await runSuite("MeetingAudioStorageManager ignores unrelated WAV files") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Mixed Audio", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let unrelatedWAV = audioDirectory.appendingPathComponent("voice-memo.wav")
        try! Data("wav".utf8).write(to: unrelatedWAV)

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 0, "unrelated WAVs should not be treated as app-owned retained audio")
        assertTrue(FileManager.default.fileExists(atPath: unrelatedWAV.path), "unrelated WAV should stay in place")
        assertFalse(
            FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent("voice-memo.m4a").path),
            "unrelated WAV should not be converted"
        )
    }

    await runSuite("MeetingAudioStorageManager removes only old Transcripted temp M4A files") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let transcriptURL = try! makeTranscript(named: "Temp Cleanup", in: directory, ageDays: 1)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let finalM4A = audioDirectory.appendingPathComponent("recording.m4a")
        let oldTemp = audioDirectory.appendingPathComponent(".recording-092B8B54-B598-4796-9573-00E0D9FC9EE1.m4a")
        let longRunningTemp = audioDirectory.appendingPathComponent(".recording-3F5531EE-C352-429F-A10F-EC978BBC2927.m4a")
        let unrelatedHiddenFile = audioDirectory.appendingPathComponent(".user-note.m4a")
        try! Data("m4a".utf8).write(to: finalM4A)
        try! Data("old".utf8).write(to: oldTemp)
        try! Data("active".utf8).write(to: longRunningTemp)
        try! Data("user".utf8).write(to: unrelatedHiddenFile)
        try! FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7 * 60 * 60)],
            ofItemAtPath: oldTemp.path
        )
        try! FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 60 * 60)],
            ofItemAtPath: longRunningTemp.path
        )
        try! FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7 * 60 * 60)],
            ofItemAtPath: unrelatedHiddenFile.path
        )

        let converted = await MeetingAudioStorageManager.compressWAVAudio(
            in: audioDirectory,
            now: now,
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(converted, 0, "temp cleanup should not count as a WAV conversion")
        assertFalse(FileManager.default.fileExists(atPath: oldTemp.path), "old app-owned temp file should be removed")
        assertTrue(FileManager.default.fileExists(atPath: longRunningTemp.path), "long-running conversion temp files should not be removed too early")
        assertTrue(FileManager.default.fileExists(atPath: unrelatedHiddenFile.path), "unrelated hidden M4A should not be removed")
        assertTrue(FileManager.default.fileExists(atPath: finalM4A.path), "final M4A should stay")
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

    runSuite("MeetingAudioStorageManager prunes by transcript frontmatter date") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldTranscript = try! makeTranscript(named: "Edited Old Call", in: directory, ageDays: 31)
        let oldAudio = makeAudioDirectory(for: oldTranscript)
        try! Data("m4a".utf8).write(to: oldAudio.appendingPathComponent("recording.m4a"))
        try! FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: oldTranscript.path)

        let removed = MeetingAudioStorageManager.pruneRetainedAudio(
            in: directory,
            retentionWindow: .thirtyDays,
            now: Date()
        )

        assertEqual(removed, 1, "frontmatter date should drive retention even when markdown mtime is fresh")
        assertFalse(FileManager.default.fileExists(atPath: oldAudio.path), "old frontmatter date should prune audio")
        assertTrue(FileManager.default.fileExists(atPath: oldTranscript.path), "transcript should stay")
    }

    runSuite("MeetingAudioStorageManager leaves non-Transcripted markdown audio alone") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let noteURL = directory.appendingPathComponent("Notes").appendingPathExtension("md")
        try! "# Notes\n\nPlain user markdown.".write(to: noteURL, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.modificationDate: Calendar.current.date(byAdding: .day, value: -31, to: Date())!],
            ofItemAtPath: noteURL.path
        )
        let audioDirectory = makeAudioDirectory(for: noteURL)
        let userAudio = audioDirectory.appendingPathComponent("recording.wav")
        try! Data("wav".utf8).write(to: userAudio)

        let removed = MeetingAudioStorageManager.pruneRetainedAudio(
            in: directory,
            retentionWindow: .sevenDays,
            now: Date()
        )

        assertEqual(removed, 0, "plain markdown should not qualify a folder for retention cleanup")
        assertTrue(FileManager.default.fileExists(atPath: userAudio.path), "user audio should stay")
    }

    await runSuite("MeetingAudioStorageManager ignores forged meeting-like markdown") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        let dateText = transcriptDateFormatter.string(from: date)
        let timeText = transcriptTimeFormatter.string(from: date)
        let noteURL = directory.appendingPathComponent("Forged Meeting").appendingPathExtension("md")
        try! """
        ---
        capture_type: meeting
        date: "\(dateText)"
        time: "\(timeText)"
        duration: "1:00"
        total_word_count: "4"
        ---

        ## Full Transcript

        User-owned transcript-shaped note.
        """.write(to: noteURL, atomically: true, encoding: .utf8)
        let audioDirectory = makeAudioDirectory(for: noteURL)
        let userAudio = audioDirectory.appendingPathComponent("recording.wav")
        try! Data("wav".utf8).write(to: userAudio)

        let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
            in: directory,
            retentionWindow: .thirtyDays,
            now: Date(),
            converter: FakeMeetingAudioConverter(),
            validator: FakeMeetingAudioValidator()
        )

        assertEqual(
            result,
            MeetingAudioStorageMaintenanceResult(scannedDirectories: 0, convertedFiles: 0, prunedDirectories: 0),
            "markdown needs Transcripted meeting IDs before storage maintenance owns its audio"
        )
        assertTrue(FileManager.default.fileExists(atPath: userAudio.path), "user audio should stay")
        assertFalse(
            FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent("recording.m4a").path),
            "forged meeting-like markdown should not trigger backfill conversion"
        )
    }

    runSuite("MeetingAudioStorageManager ignores symlinked audio directories") {
        let directory = makeMeetingAudioStorageTestDirectory()
        let externalDirectory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { try? FileManager.default.removeItem(at: externalDirectory) }

        let transcriptURL = try! makeTranscript(named: "Symlink Call", in: directory, ageDays: 31)
        let audioRoot = transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
        try! FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let externalAudioDirectory = externalDirectory.appendingPathComponent("Symlink Call_audio", isDirectory: true)
        try! FileManager.default.createDirectory(at: externalAudioDirectory, withIntermediateDirectories: true)
        let externalAudio = externalAudioDirectory.appendingPathComponent("recording.m4a")
        try! Data("m4a".utf8).write(to: externalAudio)
        let symlinkURL = audioRoot.appendingPathComponent("Symlink Call_audio", isDirectory: true)
        try! FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: externalAudioDirectory)

        let removed = MeetingAudioStorageManager.pruneRetainedAudio(
            in: directory,
            retentionWindow: .thirtyDays,
            now: Date()
        )

        assertEqual(removed, 0, "symlinked audio directories should never be pruned")
        assertTrue(FileManager.default.fileExists(atPath: externalAudio.path), "external symlink target should stay untouched")
        assertTrue(FileManager.default.fileExists(atPath: symlinkURL.path), "symlink should stay untouched")
    }

    runSuite("MeetingAudioStorageManager prunes only managed files from mixed directories") {
        let directory = makeMeetingAudioStorageTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = try! makeTranscript(named: "Mixed Retention", in: directory, ageDays: 31)
        let audioDirectory = makeAudioDirectory(for: transcriptURL)
        let managedAudio = audioDirectory.appendingPathComponent("recording.m4a")
        let unrelatedAudio = audioDirectory.appendingPathComponent("voice-memo.wav")
        try! Data("m4a".utf8).write(to: managedAudio)
        try! Data("wav".utf8).write(to: unrelatedAudio)

        let removed = MeetingAudioStorageManager.pruneRetainedAudio(
            in: directory,
            retentionWindow: .thirtyDays,
            now: Date()
        )

        assertEqual(removed, 1, "managed audio should be pruned")
        assertFalse(FileManager.default.fileExists(atPath: managedAudio.path), "managed audio should be removed")
        assertTrue(FileManager.default.fileExists(atPath: unrelatedAudio.path), "unrelated audio should stay")
        assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "mixed directory should stay for unrelated files")
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
    let date = Calendar.current.date(byAdding: .day, value: -ageDays, to: Date())!
    let dateText = transcriptDateFormatter.string(from: date)
    let timeText = transcriptTimeFormatter.string(from: date)
    try """
    ---
    capture_id: "\(UUID().uuidString)"
    capture_type: meeting
    transcript_id: "\(UUID().uuidString)"
    date: "\(dateText)"
    time: "\(timeText)"
    duration: "1:00"
    total_word_count: "4"
    mic_utterances: "1"
    system_utterances: "0"
    ---

    ## Full Transcript

    **[00:00] [Mic/You]**
    Test transcript body.
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}

private func posixPermissions(at url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

private let transcriptDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let transcriptTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func makeAudioDirectory(for transcriptURL: URL) -> URL {
    let directory = transcriptURL
        .deletingLastPathComponent()
        .appendingPathComponent("audio", isDirectory: true)
        .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
