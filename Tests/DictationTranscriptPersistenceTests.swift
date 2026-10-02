import Foundation

@MainActor
private final class DictationCompletionTestState {
    var sessionID = UUID()
    var isDictating = true
    var publications = 0
}

func testDictationTranscriptPersistence() async {
    runSuite("Session-cap completion labels a failed Markdown save as failed delivery") {
        let saved = DictationSessionCapCompletionTelemetryPolicy.snapshot(saveSucceeded: true)
        assertEqual(saved.delivery.rawValue, "saved_without_paste", "durable session-cap Markdown may use saved-without-paste delivery")
        assertNil(saved.failureKind, "a successful save must not invent a failure")

        let failed = DictationSessionCapCompletionTelemetryPolicy.snapshot(saveSucceeded: false)
        assertEqual(failed.delivery.rawValue, "failed", "a failed save with no paste or copy must not claim saved delivery")
        assertEqual(failed.failureKind, "markdown_save_failed", "completion-volume telemetry needs a coarse failure classification")
        assertTrue(
            AnalyticsEventPolicy.policy(forEvent: "dictation_completed")?.allowedProperties.contains("failure_kind") == true,
            "the failure classification must survive privacy filtering"
        )
    }

    runSuite("Session-cap completion event takes its delivery from the save result") {
        let saved = DictationSessionCapCompletionTelemetryPolicy.completionProperties(
            saveSucceeded: true, durationBucket: "5m_plus", trigger: "physical_key", wordCountBucket: "500_plus"
        )
        assertEqual(saved["delivery"], "saved_without_paste", "a saved cap take reports saved-without-paste")
        assertNil(saved["failure_kind"], "a successful save carries no failure kind")
        assertEqual(saved["auto_send"], "disabled", "the cap never auto-sends")
        assertEqual(saved["trigger"], "physical_key", "the trigger is passed through")

        let failed = DictationSessionCapCompletionTelemetryPolicy.completionProperties(
            saveSucceeded: false, durationBucket: "5m_plus", trigger: "physical_key", wordCountBucket: "500_plus"
        )
        assertEqual(failed["delivery"], "failed", "a failed save never claims saved delivery")
        assertEqual(failed["failure_kind"], "markdown_save_failed", "and says why it failed")
        let allowed = AnalyticsEventPolicy.policy(forEvent: "dictation_completed")?.allowedProperties ?? []
        assertTrue(
            failed.keys.allSatisfy { allowed.contains($0) },
            "every cap completion key survives privacy filtering"
        )
    }
    runSuite("Dictation save timing excludes delayed publication and includes failures") {
        let saved = SavedDictationTranscript(url: URL(fileURLWithPath: "/tmp/synthetic-dictation.md"), title: "Synthetic")
        var clock = [10.0, 10.003].makeIterator()
        let result = DictationTranscriptPersistenceResult.measure(now: { clock.next()! }) { saved }
        assertEqual(result.startedAt, 10.0, "writer start comes from the writer's clock")
        assertEqual(result.finishedAt, 10.003, "writer finish is captured before publication")
        assertNil(result.failureMessage, "successful save has no failure message")
        enum SaveError: Error { case diskFull }
        var errorClock = [20.0, 20.002].makeIterator()
        let failure = DictationTranscriptPersistenceResult.measure(now: { errorClock.next()! }) { throw SaveError.diskFull }
        assertEqual(failure.finishedAt, 20.002, "failed writes also have actual completion timing")
        assertNil(failure.saved, "failed save must not claim an artifact")
        assertTrue(failure.failureMessage != nil, "failed save retains actionable error copy")
    }

    await runSuite("Delayed old save survives cancel and cannot publish over a new session") { @MainActor in
        let state = DictationCompletionTestState()
        let oldID = state.sessionID
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let oldRecovery = try DictationStoppedAudioRecoveryStore.persist(samples16k: [0.1], sessionID: oldID, directory: folder)
            let newID = UUID()
            let newRecovery = try DictationStoppedAudioRecoveryStore.persist(samples16k: [0.2], sessionID: newID, directory: folder)
            let output = folder.appendingPathComponent("synthetic.md")
            let task = Task { @MainActor in
                let result: DictationStopFinalizationResult<Bool, DictationTranscriptPersistenceResult> = await DictationStopFinalizer.finalize(
                    order: .saveBeforeAutoEnter,
                    startSaving: {
                        Task.detached {
                            started.continuation.yield(())
                            for await _ in release.stream { break }
                            let result = DictationTranscriptPersistenceResult.measure {
                                try "Synthetic retained text".write(to: output, atomically: true, encoding: .utf8)
                                return SavedDictationTranscript(url: output, title: "Synthetic")
                            }
                            _ = DictationStoppedAudioRecoveryStore.cleanup(oldRecovery, transcriptPersisted: result.saved != nil)
                            return result
                        }
                    },
                    finishSaving: { await $0.value },
                    saveSynchronously: { fatalError("Wrong finalization order") },
                    performAutoEnter: { false }
                )
                if DictationSessionCompletionPolicy.canPublish(
                    sessionID: oldID, currentSessionID: state.sessionID,
                    isDictating: state.isDictating, cancelled: Task.isCancelled
                ) {
                    state.publications += 1
                    state.isDictating = false
                }
                return result.saveResult
            }
            for await _ in started.stream { break }
            task.cancel()
            state.sessionID = newID
            state.isDictating = true
            release.continuation.yield(())
            let result = await task.value
            assertTrue(result.saved != nil && FileManager.default.fileExists(atPath: output.path), "canceling UI cannot cancel a durable save already in progress")
            assertEqual(state.publications, 0, "old completion must not publish over new session")
            assertTrue(state.isDictating, "new session stays active")
            assertEqual(state.sessionID, newID, "new session retains ownership")
            assertFalse(FileManager.default.fileExists(atPath: oldRecovery!.url.path), "successful old save cleans its own checkpoint")
            assertTrue(FileManager.default.fileExists(atPath: newRecovery!.url.path), "old save cannot delete new checkpoint")
            assertFalse(DictationSessionCompletionPolicy.canPublish(sessionID: oldID, currentSessionID: newID, isDictating: true, cancelled: false), "identity alone fences uncanceled stale callbacks")
            assertFalse(DictationSessionCompletionPolicy.canPublish(sessionID: newID, currentSessionID: newID, isDictating: true, cancelled: true), "cancellation fences current session callbacks")
        } catch {
            assertTrue(false, "synthetic persistence setup failed: \(error)")
        }
    }
}
