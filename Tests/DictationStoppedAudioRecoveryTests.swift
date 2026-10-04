import Foundation

// Every suite here runs real code: the DictationStoppedAudioRecovery types (registry
// retain/remove, WAV persistence/cleanup, the commit policy) against real temp directories,
// and the prepared Stop snapshot and external-engine lease through their compiled seams
// (PreparedRecordingConsumer, ExternalEngineTranscription) with fakes. Imported restart
// checkpoints retire through MeetingStoppedAudioCheckpointPolicy. That launch runs the leftover
// cleanup is tested in AppLaunchStepsTests; what it deletes is tested here.

func testDictationStoppedAudioRecoveryRetryRegistry() {
    runSuite("stopped dictation recovery survives a failed retry until success") {
        let recovery = DictationStoppedAudioRecovery(
            url: URL(fileURLWithPath: "/tmp/stopped-dictation.wav"),
            sessionID: UUID(),
            createdAt: Date()
        )
        let failedMeetingID = UUID()
        var registry = DictationStoppedAudioRecoveryRetryRegistry()

        registry.retain(recovery, for: failedMeetingID)
        assertEqual(
            registry.recovery(for: failedMeetingID),
            recovery,
            "a failed transcription keeps its stopped-audio recovery for retry"
        )
        assertEqual(
            registry.recovery(for: failedMeetingID),
            recovery,
            "a retry failure does not consume the recovery"
        )
        assertEqual(
            registry.remove(for: failedMeetingID),
            recovery,
            "a successful retry consumes the recovery for cleanup"
        )
        assertTrue(
            registry.recovery(for: failedMeetingID) == nil,
            "a successful retry does not leave registry state behind"
        )
    }
}

@MainActor
func testDictationStoppedAudioRecovery() async {
    runSuite("Dictation stopped audio recovery writes a valid private WAV") {
        let directory = makeRecoveryTestDirectory("wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

        do {
            let recovery = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: [-1, -0.5, 0, 0.5, 1],
                sessionID: sessionID,
                directory: directory
            )
            assertNotNil(recovery, "non-empty stopped audio should be checkpointed")
            guard let recovery else { return }
            let data = try Data(contentsOf: recovery.url)
            assertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF", "recovery audio should use a WAV container")
            assertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE", "recovery audio should identify the WAV format")
            assertEqual(readUInt32LE(data, offset: 24), 16_000, "recovery audio should be stored at the inference sample rate")
            assertEqual(readUInt16LE(data, offset: 34), 16, "recovery audio should use 16-bit PCM")
            assertEqual(readUInt32LE(data, offset: 40), 10, "WAV data length should match the sample count")
            let attributes = try FileManager.default.attributesOfItem(atPath: recovery.url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            assertEqual(permissions, 0o600, "recovery audio should be owner-only")
            let discovered = DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: 1, directory: directory)
            assertEqual(discovered, [recovery], "durable metadata lets the importer find the recording by its file")
        } catch {
            assertTrue(false, "recovery WAV should persist: \(error)")
        }
    }

    runSuite("Dictation stopped audio recovery survives failed transcript persistence") {
        let directory = makeRecoveryTestDirectory("retain")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let recovery = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: [0.25, -0.25],
                sessionID: UUID(),
                directory: directory
            )
            let cleaned = DictationStoppedAudioRecoveryStore.cleanup(
                recovery,
                transcriptPersisted: false,
                explicitDiscard: false
            )
            assertFalse(cleaned, "failed transcript persistence must not clean recovery audio")
            assertTrue(FileManager.default.fileExists(atPath: recovery!.url.path), "recovery audio must remain durable")
        } catch {
            assertTrue(false, "recovery audio should persist: \(error)")
        }
    }

    runSuite("Dictation stopped audio recovery cleans up only after success or explicit discard") {
        for transcriptPersisted in [true, false] {
            let directory = makeRecoveryTestDirectory(transcriptPersisted ? "saved" : "discarded")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let recovery = try DictationStoppedAudioRecoveryStore.persist(
                    samples16k: [0.1],
                    sessionID: UUID(),
                    directory: directory
                )
                let cleaned = DictationStoppedAudioRecoveryStore.cleanup(
                    recovery,
                    transcriptPersisted: transcriptPersisted,
                    explicitDiscard: !transcriptPersisted
                )
                assertTrue(cleaned, "successful save or explicit discard should clean recovery audio")
                assertFalse(FileManager.default.fileExists(atPath: recovery!.url.path), "cleaned recovery audio should be deleted")
                assertTrue(
                    DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory).isEmpty,
                    "cleanup should remove the recording's metadata too"
                )
            } catch {
                assertTrue(false, "recovery cleanup should succeed: \(error)")
            }
        }
    }

    runSuite("Launch cleanup deletes recordings from an earlier run and keeps this run's") {
        let directory = makeRecoveryTestDirectory("purge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        do {
            let earlier = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: [0.1, -0.1], sessionID: UUID(),
                createdAt: Date(timeIntervalSinceReferenceDate: 500), directory: directory
            )!
            let thisRun = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: [0.2, -0.2], sessionID: UUID(),
                createdAt: Date(timeIntervalSinceReferenceDate: 2_000), directory: directory
            )!

            let removed = DictationStoppedAudioRecoveryStore.purgeLeftovers(createdBefore: launchedAt, directory: directory)

            assertEqual(removed, 1, "only the earlier run's recording is removed")
            assertFalse(FileManager.default.fileExists(atPath: earlier.url.path), "the earlier run's WAV is deleted")
            assertFalse(
                FileManager.default.fileExists(atPath: earlier.url.deletingPathExtension().appendingPathExtension("json").path),
                "and its metadata"
            )
            assertTrue(FileManager.default.fileExists(atPath: thisRun.url.path), "a take saved after launch is never touched")
            assertEqual(
                DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory),
                [thisRun],
                "this run's recording is still findable by the importer"
            )
            assertEqual(
                DictationStoppedAudioRecoveryStore.purgeLeftovers(createdBefore: launchedAt, directory: directory),
                0,
                "a second launch cleanup has nothing left to remove"
            )
        } catch {
            assertTrue(false, "recovery audio should persist: \(error)")
        }
    }

    runSuite("Launch cleanup removes half-written leftovers and nothing outside its own files") {
        let parent = makeRecoveryTestDirectory("purge-scope")
        let directory = parent.appendingPathComponent("dictation-audio-recovery", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let fileManager = FileManager.default
        let earlier = Date(timeIntervalSinceReferenceDate: 500)
        let later = Date(timeIntervalSinceReferenceDate: 2_000)
        let launchedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        func write(_ name: String, in folder: URL, modified: Date, contents: String = "x") throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // A WAV whose metadata was never written: crash between the two writes.
            let orphanEarlier = try write("dictation_orphan-old.wav", in: directory, modified: earlier)
            // The same, but written after launch: this run's take mid-save.
            let orphanThisRun = try write("dictation_orphan-new.wav", in: directory, modified: later)
            // Unreadable metadata from an earlier run, with its WAV.
            let brokenMetadata = try write("dictation_broken.json", in: directory, modified: earlier, contents: "{")
            let brokenAudio = try write("dictation_broken.wav", in: directory, modified: earlier)
            // Metadata that names a file outside the folder.
            let outside = try write("dictation_outside.wav", in: parent, modified: earlier)
            let escaping = try write(
                "dictation_escaping.json",
                in: directory,
                modified: earlier,
                contents: #"{"version":1,"sessionID":"00000000-0000-0000-0000-000000000009","createdAt":500,"audioFilename":"../dictation_outside.wav"}"#
            )
            // Not the store's files.
            let unrelated = try write("notes.wav", in: directory, modified: earlier)
            let nestedFolder = directory.appendingPathComponent("dictation_folder.wav", isDirectory: true)
            try fileManager.createDirectory(at: nestedFolder, withIntermediateDirectories: true)

            let removed = DictationStoppedAudioRecoveryStore.purgeLeftovers(createdBefore: launchedAt, directory: directory)

            assertEqual(removed, 3, "the orphan WAV, the broken pair, and the escaping metadata each count once")
            assertFalse(fileManager.fileExists(atPath: orphanEarlier.path), "an earlier run's WAV without metadata is deleted")
            assertTrue(fileManager.fileExists(atPath: orphanThisRun.path), "a WAV written after launch is kept even without metadata")
            assertFalse(fileManager.fileExists(atPath: brokenMetadata.path), "unreadable earlier metadata is deleted")
            assertFalse(fileManager.fileExists(atPath: brokenAudio.path), "with the WAV of the same name")
            assertFalse(fileManager.fileExists(atPath: escaping.path), "metadata pointing outside the folder is itself removed")
            assertTrue(fileManager.fileExists(atPath: outside.path), "but the file it names outside the folder is never deleted")
            assertTrue(fileManager.fileExists(atPath: unrelated.path), "files without the dictation_ prefix are left alone")
            assertTrue(fileManager.fileExists(atPath: nestedFolder.path), "folders are never deleted")
        } catch {
            assertTrue(false, "purge scope fixtures should be written: \(error)")
        }
    }

    runSuite("Launch cleanup with no recovery folder does nothing") {
        let missing = makeRecoveryTestDirectory("purge-missing")
        assertEqual(
            DictationStoppedAudioRecoveryStore.purgeLeftovers(createdBefore: Date(timeIntervalSinceReferenceDate: 1_000), directory: missing),
            0,
            "a Mac that never saved a dictation WAV has nothing to clean"
        )
        assertFalse(FileManager.default.fileExists(atPath: missing.path), "the cleanup never creates the folder")
    }

    runSuite("Dictation stopped audio recovery limits after newest-first ordering") {
        let oldSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let middleSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let newSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let recoveries = [
            DictationStoppedAudioRecovery(url: URL(fileURLWithPath: "/old.wav"), sessionID: oldSessionID, createdAt: Date(timeIntervalSince1970: 1)),
            DictationStoppedAudioRecovery(url: URL(fileURLWithPath: "/new.wav"), sessionID: newSessionID, createdAt: Date(timeIntervalSince1970: 3)),
            DictationStoppedAudioRecovery(url: URL(fileURLWithPath: "/middle.wav"), sessionID: middleSessionID, createdAt: Date(timeIntervalSince1970: 2))
        ]

        let limited = DictationStoppedAudioRecoveryStore.mostRecent(recoveries, limit: 2)

        assertEqual(
            limited.map(\.sessionID),
            [newSessionID, middleSessionID],
            "the limit must select the newest recoveries regardless of enumeration order"
        )
    }

    runSuite("Stopped audio persistence rejects cancelled and superseded sessions") {
        let activeSessionID = UUID()
        assertTrue(
            DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                taskCancelled: false,
                isDictating: true,
                taskSessionID: activeSessionID,
                currentSessionID: activeSessionID
            ),
            "the current live stop task should persist its recovery checkpoint"
        )
        assertFalse(
            DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                taskCancelled: true,
                isDictating: true,
                taskSessionID: activeSessionID,
                currentSessionID: activeSessionID
            ),
            "a cancelled stop task must not persist after detached resampling returns"
        )
        assertFalse(
            DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                taskCancelled: false,
                isDictating: true,
                taskSessionID: activeSessionID,
                currentSessionID: UUID()
            ),
            "an old stop task must not mutate a successor session"
        )

        assertTrue(
            DictationStoppedAudioRecoveryCommitPolicy.shouldRetainPersistedRecovery(
                taskSessionID: activeSessionID,
                preservationSessionID: activeSessionID
            ),
            "termination cancellation must retain a checkpoint already written for that session"
        )
        assertFalse(
            DictationStoppedAudioRecoveryCommitPolicy.shouldRetainPersistedRecovery(
                taskSessionID: activeSessionID,
                preservationSessionID: UUID()
            ),
            "a successor session must not retain an old task's checkpoint"
        )
    }

    // The controller's stop path (persist before the model wait, the
    // stop task's session check, transcribing the checkpointed snapshot, the
    // empty-take branches, the saved-recording action, and Quit's
    // mark/wait/cancel order) runs through DictationSessionPipeline.swift and
    // is a behavior test in DictationSessionPipelineTests.swift.
    runSuite("A take's WAV is retired only once its transcript is saved") {
        for saved in [true, false] {
            let directory = makeRecoveryTestDirectory(saved ? "retire-saved" : "retire-failed")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let recovery = try DictationStoppedAudioRecoveryStore.persist(
                    samples16k: [0.1],
                    sessionID: UUID(),
                    directory: directory
                )
                let result = DictationTranscriptPersistenceResult.measure {
                    guard saved else { throw StoppedAudioRetireTestError() }
                    return SavedDictationTranscript(url: directory.appendingPathComponent("day.md"), title: "Synthetic")
                }
                let retired = DictationStoppedAudioRecoveryStore.retire(recovery, afterSaving: result)
                assertEqual(retired, saved)
                assertEqual(
                    FileManager.default.fileExists(atPath: recovery!.url.path),
                    !saved,
                    saved ? "a saved transcript retires its WAV" : "a failed save keeps the WAV (the next launch's cleanup removes it)"
                )
            } catch {
                assertTrue(false, "recovery audio should persist: \(error)")
            }
        }
    }

    runSuite("A restart checkpoint imported as a meeting is retired once its transcript is saved") {
        let ends: [MeetingStoppedAudioCheckpointPolicy.JobEnd] = [.transcriptSaved, .failed, .discardedAccidentalStart]
        for end in ends {
            let directory = makeRecoveryTestDirectory("meeting-import-\(end)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let recovery = try DictationStoppedAudioRecoveryStore.persist(
                    samples16k: [0.1],
                    sessionID: UUID(),
                    directory: directory
                )
                let retired = MeetingStoppedAudioCheckpointPolicy.finish(recovery, after: end)
                let saved = end == .transcriptSaved
                assertEqual(retired, saved, "only a saved transcript retires the checkpoint (\(end))")
                assertEqual(
                    FileManager.default.fileExists(atPath: recovery!.url.path),
                    !saved,
                    saved ? "a saved meeting transcript retires the WAV" : "an unsaved meeting leaves the WAV alone"
                )
                assertEqual(
                    DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory).count,
                    saved ? 0 : 1,
                    "the importer no longer finds a retired checkpoint (\(end))"
                )
            } catch {
                assertTrue(false, "recovery audio should persist: \(error)")
            }
        }
    }

    runSuite("An old Stop's prepared snapshot can't clear a newer recording") {
        let oldRecording = UUID()
        let timeline = FakePreparedRecordingTimeline(recordingIdentity: oldRecording, revision: 4)
        let staleClaim = ParakeetRecordedSamplesClaim(recordingIdentity: oldRecording, revision: 4)

        // A newer recording began while the old Stop was resampling.
        timeline.recordingIdentity = UUID()
        assertFalse(
            PreparedRecordingConsumer.consume(claim: staleClaim, cancelled: false, timeline: timeline),
            "a stale snapshot is not consumed"
        )
        assertEqual(timeline.clears, [], "an old Stop snapshot cannot clear a successor recording's native samples")

        // Same recording, but its timeline changed after the snapshot.
        let revised = FakePreparedRecordingTimeline(recordingIdentity: oldRecording, revision: 5)
        assertFalse(PreparedRecordingConsumer.consume(claim: staleClaim, cancelled: false, timeline: revised))
        assertEqual(revised.clears, [], "a snapshot from before the timeline changed leaves it alone")

        let current = FakePreparedRecordingTimeline(recordingIdentity: oldRecording, revision: 4)
        assertFalse(PreparedRecordingConsumer.consume(claim: staleClaim, cancelled: true, timeline: current))
        assertEqual(current.clears, [], "a cancelled consume leaves the native samples")

        assertTrue(
            PreparedRecordingConsumer.consume(claim: staleClaim, cancelled: false, timeline: current),
            "the current recording's snapshot is consumed"
        )
        assertEqual(current.clears, [true], "consuming the current snapshot clears its native samples once, keeping capacity")
        // Dropped: the pin on `consumeRecordedSamples(preparedRecording: preparedRecording)`.
        // It named a call site that skips a second resample, which is a speed choice with
        // no observable result here; the safety half of it is checked above.
    }

    await runSuite("External dictation classifies a model error before releasing its lease") {
        struct ModelBroke: Error {}
        var released: [String] = []
        var leaseHeldWhenClassified: Bool?
        var classified: Error?
        let thrown = await ExternalEngineTranscription.run(
            lease: "take-1",
            release: { released.append($0) },
            model: { throw ModelBroke() },
            accept: { _ in
                assertTrue(false, "a thrown model error never reaches accept")
                return nil
            },
            classify: { error in
                leaseHeldWhenClassified = released.isEmpty
                classified = error
            }
        )
        assertNil(thrown, "a model error returns no text")
        assertTrue(classified is ModelBroke, "the thrown error is the one classified")
        assertEqual(leaseHeldWhenClassified, true, "function-scope cleanup must not release the lease before a thrown model error is classified")
        assertEqual(released, ["take-1"], "the lease is released once after classification")

        var acceptedReleased: [String] = []
        var leaseHeldWhenAccepted: Bool?
        let text = await ExternalEngineTranscription.run(
            lease: "take-2",
            release: { acceptedReleased.append($0) },
            model: { "hello" },
            accept: { text in
                leaseHeldWhenAccepted = acceptedReleased.isEmpty
                return text.uppercased()
            },
            classify: { _ in assertTrue(false, "a returned transcript is never classified as a failure") }
        )
        assertEqual(text, "HELLO", "accept decides what a returned transcript becomes")
        assertEqual(leaseHeldWhenAccepted, true, "a returned transcript is judged while the lease is held")
        assertEqual(acceptedReleased, ["take-2"], "the lease is released once after a result too")
    }

    runSuite("External dictation classifies what came back") {
        let usable = [Float](repeating: 0.10, count: 16_000)
        let silent = [Float](repeating: 0, count: 16_000)
        assertNil(
            DictationEmptyInferencePolicy.externalEngineEmptyReason(text: " hello ", samples16k: silent),
            "words are a result, whatever the audio looked like"
        )
        assertEqual(
            DictationEmptyInferencePolicy.externalEngineEmptyReason(text: "  \n", samples16k: usable),
            .audioNeedsRecovery,
            "blank text over usable audio keeps the WAV"
        )
        assertEqual(
            DictationEmptyInferencePolicy.externalEngineEmptyReason(text: "", samples16k: silent),
            .noSpeech,
            "blank text over silence is ordinary no-speech"
        )
        struct ModelBroke: Error {}
        let failure = DictationEmptyInferencePolicy.externalEngineFailureReason(for: ModelBroke(), taskCancelled: false)
        assertEqual(failure, .modelFailure, "a thrown model error is a model failure, not no speech")
        assertFalse(failure?.shouldDiscardStoppedAudioRecovery ?? true, "a model failure keeps the stopped audio")
        assertNil(DictationEmptyInferencePolicy.externalEngineFailureReason(for: CancellationError(), taskCancelled: false))
        assertNil(
            DictationEmptyInferencePolicy.externalEngineFailureReason(for: ModelBroke(), taskCancelled: true),
            "a cancelled take reports nothing"
        )
    }

    runSuite("A conversion that hands back nothing keeps native audio for recovery") {
        assertEqual(
            DictationEmptyInferencePolicy.reasonAfterEmptyConversion(current: nil, retainsNativeAudio: true),
            .audioNeedsRecovery,
            "stale same-session conversion with native audio left must not fall into no-speech cleanup"
        )
        assertNil(DictationEmptyInferencePolicy.reasonAfterEmptyConversion(current: nil, retainsNativeAudio: false))
        assertEqual(
            DictationEmptyInferencePolicy.reasonAfterEmptyConversion(current: .modelFailure, retainsNativeAudio: true),
            .modelFailure,
            "a reason the conversion already gave stands"
        )
        assertFalse(DictationEmptyTranscriptionReason.audioNeedsRecovery.shouldDiscardStoppedAudioRecovery)
    }
}

private struct StoppedAudioRetireTestError: Error {}

/// Stands in for ParakeetEngine's recorded timeline: which recording it
/// holds, and each clear it was asked for (the keepingCapacity flag).
@MainActor
private final class FakePreparedRecordingTimeline: PreparedRecordingTimeline {
    var recordingIdentity: UUID
    var recordedSamplesRevision: UInt64
    private(set) var clears: [Bool] = []

    init(recordingIdentity: UUID, revision: UInt64) {
        self.recordingIdentity = recordingIdentity
        self.recordedSamplesRevision = revision
    }

    func clearRecoveredRecordingTimeline(keepingCapacity: Bool) {
        clears.append(keepingCapacity)
    }
}

private func makeRecoveryTestDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationStoppedAudioRecoveryTests-\(suffix)-\(UUID().uuidString)", isDirectory: true)
}

private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}
