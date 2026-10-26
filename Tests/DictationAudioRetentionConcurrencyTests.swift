import Foundation

private final class DictationArchiveInterleavingFileManager: FileManager, @unchecked Sendable {
    var beforePublish: (() -> Void)?
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent.contains(".keep-") {
            let action = beforePublish
            beforePublish = nil
            action?()
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class DictationCommitMarkerFailureFileManager: FileManager, @unchecked Sendable {
    var failNextMetadataRead = false
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if failNextMetadataRead, path.hasSuffix(".json") {
            failNextMetadataRead = false
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
    }
}

/// Written on the checkpoint and holder threads, read after both signal.
private final class CheckpointOutcome: @unchecked Sendable {
    var finishedWhileHeld = false
    var recovery: DictationStoppedAudioRecovery?
}

func testDictationAudioRetentionConcurrency() async {
    let fm = FileManager.default
    runSuite("Failed or absent text commit keeps the original recovery through retry Off expiry and restart") {
        for attemptSave in [false, true] {
            let root = fm.temporaryDirectory.appendingPathComponent("DictationUncommittedRetention-\(UUID())")
            defer { try? fm.removeItem(at: root) }
            let directory = root.appendingPathComponent("recovery")
            let dictations = root.appendingPathComponent("dictations")
            let created = Date(timeIntervalSince1970: 1_790_000_000)
            guard let recovery = try? DictationStoppedAudioRecoveryStore.persist(
                samples16k: attemptSave ? [0.1] : Array(repeating: 0.1, count: 31 * 16_000),
                sessionID: UUID(), createdAt: created,
                retentionRequested: true, directory: directory
            ) else { return assertTrue(false, "checkpoint saved") }
            if attemptSave {
                let result = DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
                    recovery: recovery, keepWindow: .forever, dictationsFolder: dictations,
                    compressKeptAudio: { _ in assertTrue(false, "unsaved text must not archive") }
                ) { _ in throw CocoaError(.fileWriteOutOfSpace) }
                assertNil(result.saved)
                assertNotNil(result.failureError)
                assertNil(result.pendingAudioRetention, "failed text remains a transcription recovery, not saved-audio repair")
            }
            for window in [DictationAudioKeepWindow.forever, .off, .sevenDays] {
                assertEqual(DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(
                    directory: directory, window: window, now: created.addingTimeInterval(8 * 86_400),
                    compressKeptAudio: { _ in assertTrue(false, "uncommitted recovery must not compress") }
                ), 0)
                assertTrue(fm.fileExists(atPath: recovery.url.path), "retention does not erase the only unsaved recording")
                assertEqual(DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory), [recovery])
            }
            assertEqual(DictationStoppedAudioRecoveryStore.purgeLeftovers(
                createdBefore: Date().addingTimeInterval(60), directory: directory
            ), 0, "restart does not purge requested retention before text commits")
            let path = DictationAudioArchive.relativePath(for: recovery.sessionID)
            assertNil(DictationAudioArchive.resolveURL(relativePath: path, dictationsFolder: dictations, recoveryDirectory: directory))
            assertEqual(DictationAudioArchive.deleteKeptAudio(relativePath: path, dictationsFolder: dictations,
                                                            recoveryDirectory: directory), 0,
                        "a guessed saved-entry path does not delete unsaved recovery")
            assertTrue(fm.fileExists(atPath: recovery.url.path))
            assertTrue(DictationStoppedAudioRecoveryStore.cleanup(recovery, explicitDiscard: true),
                       "explicit discard still owns the unsaved recording")
        }
    }
    runSuite("Interruption after Markdown before commit receipt keeps recoverable audio without guessing saved text") {
        let root = fm.temporaryDirectory.appendingPathComponent("DictationCommitGap-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("recovery")
        let dictations = root.appendingPathComponent("dictations")
        guard let recovery = try? DictationStoppedAudioRecoveryStore.persist(
            samples16k: [0.1], sessionID: UUID(), retentionRequested: true, directory: directory
        ) else { return assertTrue(false, "checkpoint saved") }
        try? fm.createDirectory(at: dictations, withIntermediateDirectories: true)
        try? Data("blocked".utf8).write(to: dictations.appendingPathComponent("audio"))
        let result = DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
            recovery: recovery, keepWindow: .forever, dictationsFolder: dictations, compressKeptAudio: { _ in }
        ) { path in
            try DictationTranscriptWriter.save(text: "synthetic committed words", sourceAppName: "Synthetic", sourceBundleID: nil,
                                              delivery: .pasted, directory: dictations, audioRelativePath: path)
        }
        assertNotNil(result.saved)
        let receipt = recovery.url.deletingPathExtension().appendingPathExtension("json")
        // Restore the real serialized write-ahead state at the interruption
        // boundary. No production API infers commitment from a UUID alone.
        if let data = try? Data(contentsOf: receipt),
           var metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var intent = metadata["archiveIntent"] as? [String: Any] {
            intent.removeValue(forKey: "transcriptCommitted")
            metadata["archiveIntent"] = intent
            try? JSONSerialization.data(withJSONObject: metadata).write(to: receipt, options: .atomic)
        } else { assertTrue(false, "real write-ahead receipt decoded") }
        try? fm.removeItem(at: dictations.appendingPathComponent("audio"))
        assertEqual(DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(
            directory: directory, window: .forever, compressKeptAudio: { _ in assertTrue(false, "no unproven archive") }
        ), 0)
        assertEqual(DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(directory: directory, window: .off,
                                                                               compressKeptAudio: { _ in }), 0)
        assertEqual(DictationStoppedAudioRecoveryStore.purgeLeftovers(createdBefore: Date().addingTimeInterval(60), directory: directory), 0)
        assertTrue(fm.fileExists(atPath: recovery.url.path))
        assertEqual(DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory), [recovery])
        assertTrue(result.saved.map { fm.fileExists(atPath: $0.url.path) } ?? false, "Markdown remains saved")
    }
    runSuite("Successful text with failed commit marker retries only that take's audio exactly once") {
        let root = fm.temporaryDirectory.appendingPathComponent("DictationCommitMarkerFailure-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("recovery")
        let dictations = root.appendingPathComponent("dictations")
        guard let recovery = try? DictationStoppedAudioRecoveryStore.persist(
            samples16k: [0.1], sessionID: UUID(), retentionRequested: true, directory: directory
        ) else { return assertTrue(false, "checkpoint saved") }
        let injected = DictationCommitMarkerFailureFileManager()
        var writes = 0
        let result = DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
            recovery: recovery, keepWindow: .forever, dictationsFolder: dictations, fileManager: injected,
            compressKeptAudio: { _ in assertTrue(false, "commit marker failed before archive") }
        ) { path in
            writes += 1
            let saved = try DictationTranscriptWriter.save(text: "synthetic marker failure", sourceAppName: "Synthetic", sourceBundleID: nil,
                                                         delivery: .pasted, directory: dictations, audioRelativePath: path)
            injected.failNextMetadataRead = true
            return saved
        }
        assertNotNil(result.saved)
        assertNotNil(result.pendingAudioRetention)
        assertTrue(fm.fileExists(atPath: recovery.url.path))
        assertEqual(DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(directory: directory, window: .off,
                                                                               compressKeptAudio: { _ in }), 0,
                    "generic maintenance cannot infer the successful in-process save")
        let before = result.saved.flatMap { try? Data(contentsOf: $0.url) }
        var compressed = 0
        assertTrue(DictationStoppedAudioRecoveryStore.retryRetainedAudio(
            recovery: recovery, afterSaving: result, window: .forever, compressKeptAudio: { _ in compressed += 1 }
        ))
        assertFalse(DictationStoppedAudioRecoveryStore.retryRetainedAudio(
            recovery: recovery, afterSaving: result, window: .forever, compressKeptAudio: { _ in compressed += 1 }
        ))
        assertEqual(writes, 1)
        assertEqual(compressed, 1)
        assertEqual(result.saved.flatMap { try? Data(contentsOf: $0.url) }, before, "retry never appends saved words again")
        assertFalse(fm.fileExists(atPath: recovery.url.path))
        assertEqual(DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory).count, 0)
    }
    runSuite("Queued save reads the current Off preference after gaining storage ownership") {
        let root = fm.temporaryDirectory.appendingPathComponent("DictationQueuedRetention-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        guard let recovery = try? DictationStoppedAudioRecoveryStore.persist(
            samples16k: [0.1], sessionID: UUID(), retentionRequested: true, directory: root.appendingPathComponent("recovery")
        ) else { return assertTrue(false, "checkpoint saved") }
        var recordedPath: String?
        let result = DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
            recovery: recovery, keepWindow: .thirtyDays, currentKeepWindow: { .off },
            dictationsFolder: root.appendingPathComponent("dictations"), compressKeptAudio: { _ in assertTrue(false, "Off never archives") }
        ) { path in recordedPath = path; return SavedDictationTranscript(url: root.appendingPathComponent("day.md"), title: "Synthetic") }
        assertNotNil(result.saved)
        assertNil(recordedPath, "an old queued Thirty Days value cannot override current Off")
        assertFalse(fm.fileExists(atPath: recovery.url.path))
        assertFalse(fm.fileExists(atPath: DictationAudioArchive.audioFolder(in: root.appendingPathComponent("dictations")).path))
    }
    runSuite("Queued pending retry reads current Off instead of its captured Forever value") {
        let root = fm.temporaryDirectory.appendingPathComponent("DictationQueuedRetry-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("recovery")
        let dictations = root.appendingPathComponent("dictations")
        guard let recovery = try? DictationStoppedAudioRecoveryStore.persist(
            samples16k: [0.1], sessionID: UUID(), retentionRequested: true, directory: directory
        ) else { return assertTrue(false, "checkpoint saved") }
        try? fm.createDirectory(at: dictations, withIntermediateDirectories: true)
        try? Data("blocked".utf8).write(to: dictations.appendingPathComponent("audio"))
        let result = DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
            recovery: recovery, keepWindow: .forever, dictationsFolder: dictations, compressKeptAudio: { _ in }
        ) { _ in SavedDictationTranscript(url: root.appendingPathComponent("day.md"), title: "Synthetic") }
        assertNotNil(result.pendingAudioRetention)
        try? fm.removeItem(at: dictations.appendingPathComponent("audio"))
        assertEqual(DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(
            directory: directory, window: .forever, currentKeepWindow: { .off },
            compressKeptAudio: { _ in assertTrue(false, "Off never archives") }
        ), 1)
        assertFalse(fm.fileExists(atPath: recovery.url.path))
        assertFalse(fm.fileExists(atPath: recovery.url.deletingPathExtension().appendingPathExtension("json").path))
        assertFalse(fm.fileExists(atPath: DictationAudioArchive.audioFolder(in: dictations).path))
    }
    runSuite("Delete and Off during pending archive publication cannot resurrect retained audio") {
        for turnOff in [false, true] {
            let root = fm.temporaryDirectory.appendingPathComponent("DictationArchiveInterleaving-\(UUID())")
            defer { try? fm.removeItem(at: root) }
            let directory = root.appendingPathComponent("recovery")
            let dictations = root.appendingPathComponent("dictations")
            guard let recovery = try? DictationStoppedAudioRecoveryStore.persist(
                samples16k: [0.1, -0.1], sessionID: UUID(), retentionRequested: true, directory: directory
            ) else { return assertTrue(false, "checkpoint saved") }
            try? fm.createDirectory(at: dictations, withIntermediateDirectories: true)
            try? Data("blocked".utf8).write(to: dictations.appendingPathComponent("audio"))
            _ = DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
                recovery: recovery, keepWindow: .forever, dictationsFolder: dictations, compressKeptAudio: { _ in }
            ) { _ in SavedDictationTranscript(url: root.appendingPathComponent("day.md"), title: "Synthetic") }
            try? fm.removeItem(at: dictations.appendingPathComponent("audio"))
            let injected = DictationArchiveInterleavingFileManager()
            let path = DictationAudioArchive.relativePath(for: recovery.sessionID)
            injected.beforePublish = {
                if turnOff {
                    _ = DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(directory: directory, window: .off,
                                                                                      compressKeptAudio: { _ in })
                    _ = DictationAudioArchive.prune(window: .off, dictationsFolder: dictations)
                } else {
                    _ = DictationAudioArchive.deleteKeptAudio(relativePath: path, dictationsFolder: dictations, recoveryDirectory: directory)
                }
            }
            _ = DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(
                directory: directory, window: .forever, fileManager: injected,
                compressKeptAudio: { _ in assertTrue(false, "discarded take must not compress") }
            )
            assertFalse(fm.fileExists(atPath: recovery.url.path))
            assertNil(DictationAudioArchive.resolveURL(relativePath: path, dictationsFolder: dictations, recoveryDirectory: directory))
            assertEqual(DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(directory: directory, window: .forever,
                                                                                     compressKeptAudio: { _ in }), 0)
        }
    }

    await runSuite("Delete while compression awaits prevents converted audio from reappearing") {
        let root = fm.temporaryDirectory.appendingPathComponent("DictationCompressionInterleaving-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let audio = DictationAudioArchive.audioFolder(in: root)
        let stem = UUID().uuidString.lowercased()
        let wav = audio.appendingPathComponent("\(stem).wav")
        try? fm.createDirectory(at: audio, withIntermediateDirectories: true)
        try? Data("synthetic WAV".utf8).write(to: wav)
        let compressed = await DictationAudioArchive.compress(wav, convert: { _, temp in
            // The converter is suspended work: deletion may retire its source.
            _ = DictationAudioArchive.deleteKeptAudio(relativePath: "audio/\(stem).m4a", dictationsFolder: root)
            try Data("synthetic converted audio".utf8).write(to: temp)
        }, isUsable: { _, _ in true })
        assertFalse(compressed, "a deliberately removed source is not published")
        assertFalse(fm.fileExists(atPath: wav.path))
        assertFalse(fm.fileExists(atPath: audio.appendingPathComponent("\(stem).m4a").path))
        assertEqual((try? fm.contentsOfDirectory(atPath: audio.path)) ?? [], [], "no staging copy survives")
    }

    runSuite("A stop checkpoint doesn't wait behind another take's archive work") {
        let root = fm.temporaryDirectory.appendingPathComponent("DictationCheckpointLock-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("recovery")
        let checkpointed = DispatchSemaphore(value: 0)
        let holderDone = DispatchSemaphore(value: 0)
        let outcome = CheckpointOutcome()
        // Stands in for the previous take's save, a slow library copy or a
        // background compression publish: all hold the storage lock.
        Thread {
            DictationAudioArchive.lockStorageMutation()
            DispatchQueue.global().async {
                outcome.recovery = try? DictationStoppedAudioRecoveryStore.persist(
                    samples16k: Array(repeating: 0.1, count: 16_000),
                    sessionID: UUID(), directory: directory
                )
                checkpointed.signal()
            }
            // Hang guard only: a checkpoint stuck on the lock never signals.
            outcome.finishedWhileHeld = checkpointed.wait(timeout: .now() + 30) == .success
            DictationAudioArchive.unlockStorageMutation()
            if !outcome.finishedWhileHeld { checkpointed.wait() }
            holderDone.signal()
        }.start()
        holderDone.wait()
        assertTrue(outcome.finishedWhileHeld, "the checkpoint finished while the archive lock was held")
        assertNotNil(outcome.recovery)
        if let recovery = outcome.recovery {
            assertTrue(fm.fileExists(atPath: recovery.url.path))
            assertEqual(DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory), [recovery])
        }
    }
}
