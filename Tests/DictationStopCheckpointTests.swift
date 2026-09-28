import Foundation

// Behavior tests for the first stage of stopping a dictation
// (Sources/Dictation/DictationStopCheckpoint.swift): stop the mic, play the stop
// click, then save the take to a private WAV checkpoint before anything waits on
// the model. These replace source-text pins that read the order of those lines
// out of DictationSessionController.swift.

@MainActor
func testDictationStopCheckpoint() async {
    await runSuite("Stop click plays once, after the mic stops and before the snapshot") {
        let fake = StopCheckpointFake()
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(fake.events.all, ["stop mic", "stop click", "snapshot", "write checkpoint"],
                    "the mic stops first (so speakers can't leak the click into the take), then the click, then the snapshot")
        assertEqual(fake.events.all.filter { $0 == "stop click" }.count, 1, "the stop click plays exactly once")
        assertEqual(describe(result.outcome), "checkpointed(snapshot, checkpoint)", "a normal stop keeps the snapshot and its checkpoint")
    }

    await runSuite("The mic stop runs first, whatever the session state") {
        // An admitted stop must always reach the engine: nothing in this stage
        // checks recording state first, so a brief recovery-idle state can't
        // skip the stop and leave the mic to come back on.
        let fake = StopCheckpointFake()
        fake.sessionAlreadyEnded = true
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(fake.events.all.first, "stop mic", "the mic stop is the first thing that happens")
        assertEqual(describe(result.outcome), "abandoned", "then a stale session stops there")
    }

    await runSuite("The checkpoint is written off the main actor, before anything waits on the model") {
        let fake = StopCheckpointFake()
        _ = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(fake.checkpointWrittenOnMainThread.value, false, "writing the WAV must not block the main actor")
        assertEqual(fake.events.all.last, "write checkpoint", "the stage ends with the checkpoint written; the model wait comes after")
    }

    await runSuite("A session that ends right after the mic stops takes no snapshot") {
        let fake = StopCheckpointFake()
        fake.sessionEndsAfter = "stop click"
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "abandoned", "a stale stop does nothing more")
        assertEqual(fake.events.all, ["stop mic", "stop click"], "no snapshot or checkpoint for a session that is gone")
    }

    await runSuite("A session that ends during the snapshot writes no checkpoint") {
        let fake = StopCheckpointFake()
        fake.sessionEndsAfter = "snapshot"
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "abandoned", "a stale stop does nothing more")
        assertFalse(fake.events.all.contains("write checkpoint"), "no checkpoint for a session that is gone")
    }

    await runSuite("A session that ends while the checkpoint is written deletes it, off the main actor") {
        let fake = StopCheckpointFake()
        fake.sessionEndsAfter = "write checkpoint"
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "abandoned", "a stale stop does nothing more")
        assertEqual(fake.events.all.last, "discard checkpoint", "an orphaned checkpoint is deleted")
        assertEqual(fake.discardRanOnMainThread.value, false, "deleting the WAV must not block the main actor")
    }

    await runSuite("An orphaned checkpoint that another path claimed is kept") {
        let fake = StopCheckpointFake()
        fake.sessionEndsAfter = "write checkpoint"
        fake.anotherPathKeepsCheckpoint = true
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "abandoned", "a stale stop does nothing more")
        assertFalse(fake.events.all.contains("discard checkpoint"), "a checkpoint Quit is preserving must survive")
    }

    await runSuite("No snapshot while native audio is still in memory stops before transcribing") {
        let fake = StopCheckpointFake()
        fake.snapshotAvailable = false
        fake.audioStillInMemory = true
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "checkpointUnavailable",
                    "transcribing would consume the last copy of the audio with no checkpoint on disk")
        assertFalse(fake.events.all.contains("write checkpoint"), "there is no snapshot to write")
    }

    await runSuite("No snapshot and nothing left in memory carries on without a prepared recording") {
        let fake = StopCheckpointFake()
        fake.snapshotAvailable = false
        fake.audioStillInMemory = false
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "noSnapshot", "nothing can be lost, so transcription may go ahead")
    }

    await runSuite("A failed checkpoint write is reported") {
        let fake = StopCheckpointFake()
        fake.checkpointWriteFails = true
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "checkpointFailed", "the caller must show the recovery error instead of transcribing")
    }

    await runSuite("A failed checkpoint write for a session that ended is silent") {
        let fake = StopCheckpointFake()
        fake.checkpointWriteFails = true
        fake.sessionEndsAfter = "write checkpoint"
        let result = await DictationStopCheckpoint.run(fake.steps())

        assertEqual(describe(result.outcome), "abandoned", "no error for a stop whose session is already gone")
    }

    await runSuite("Stop timing marks are taken in order") {
        let fake = StopCheckpointFake()
        let marks = await DictationStopCheckpoint.run(fake.steps()).marks
        let ordered = [marks.micStoppedAt, marks.snapshotStartedAt, marks.snapshotFinishedAt,
                       marks.checkpointStartedAt, marks.checkpointFinishedAt]

        assertTrue(ordered.allSatisfy { $0 != nil }, "a full stop records every mark")
        assertEqual(ordered.compactMap { $0 }, ordered.compactMap { $0 }.sorted(), "mic stop, snapshot, then checkpoint")

        let noSnapshot = StopCheckpointFake()
        noSnapshot.snapshotAvailable = false
        let partial = await DictationStopCheckpoint.run(noSnapshot.steps()).marks
        assertNotNil(partial.snapshotFinishedAt, "a missing snapshot still records when the attempt finished")
        assertNil(partial.checkpointStartedAt, "no checkpoint mark without a snapshot")
    }
}

// MARK: - Fake

@MainActor
private final class StopCheckpointFake {
    let events = StopCheckpointEvents()
    let checkpointWrittenOnMainThread = StopCheckpointFlag()
    let discardRanOnMainThread = StopCheckpointFlag()
    var sessionEndsAfter: String?
    var sessionAlreadyEnded = false
    var snapshotAvailable = true
    var audioStillInMemory = false
    var checkpointWriteFails = false
    var anotherPathKeepsCheckpoint = false
    private var clock: CFAbsoluteTime = 1_000

    func steps() -> DictationStopCheckpoint.Steps<String, String> {
        let events = events
        let writtenOnMain = checkpointWrittenOnMainThread
        let discardOnMain = discardRanOnMainThread
        let writeFails = checkpointWriteFails
        return DictationStopCheckpoint.Steps(
            isCurrent: { [unowned self] in
                if self.sessionAlreadyEnded { return false }
                guard let ending = self.sessionEndsAfter else { return true }
                return !events.all.contains(ending)
            },
            stopMicrophone: { events.append("stop mic") },
            playStopCue: { events.append("stop click") },
            snapshot: { [unowned self] in
                events.append("snapshot")
                return self.snapshotAvailable ? "snapshot" : nil
            },
            checkpointWork: { _ in
                {
                    writtenOnMain.set(Thread.isMainThread)
                    events.append("write checkpoint")
                    if writeFails { throw StopCheckpointWriteError() }
                    return "checkpoint"
                }
            },
            discardWork: { _ in
                {
                    discardOnMain.set(Thread.isMainThread)
                    events.append("discard checkpoint")
                }
            },
            keepAbandonedCheckpoint: { [unowned self] in self.anotherPathKeepsCheckpoint },
            hasRecoverableRecording: { [unowned self] in self.audioStillInMemory },
            now: { [unowned self] in
                self.clock += 1
                return self.clock
            }
        )
    }
}

private struct StopCheckpointWriteError: Error {}

private final class StopCheckpointEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var all: [String] { lock.withLock { events } }

    func append(_ event: String) { lock.withLock { events.append(event) } }
}

private final class StopCheckpointFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? { lock.withLock { stored } }

    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}

private func describe(_ outcome: DictationStopCheckpoint.Outcome<String, String>) -> String {
    switch outcome {
    case .abandoned: return "abandoned"
    case .checkpointed(let snapshot, let recovery): return "checkpointed(\(snapshot), \(recovery))"
    case .noSnapshot: return "noSnapshot"
    case .checkpointUnavailable: return "checkpointUnavailable"
    case .checkpointFailed: return "checkpointFailed"
    }
}
