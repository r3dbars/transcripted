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

    runSuite("Session-cap production completion uses the save-proof telemetry policy") {
        do {
            let source = try String(
                contentsOf: repoFixtureURL("Sources/UI/Overlay/DictationSessionController.swift"),
                encoding: .utf8
            )
            guard let capStart = source.range(of: "private func finalizeWithoutPaste("),
                  let capEnd = source.range(of: "func cancelDictation(", range: capStart.upperBound..<source.endIndex),
                  let snapshot = source.range(of: "DictationSessionCapCompletionTelemetryPolicy.snapshot(", range: capStart.upperBound..<capEnd.lowerBound),
                  let saveProof = source.range(of: "saveSucceeded: saveResult.saved != nil", range: snapshot.upperBound..<capEnd.lowerBound),
                  let delivery = source.range(of: "\"delivery\": completionTelemetry.delivery.rawValue", range: saveProof.upperBound..<capEnd.lowerBound),
                  let failure = source.range(of: "completionProperties[\"failure_kind\"] = failureKind", range: delivery.upperBound..<capEnd.lowerBound),
                  let track = source.range(of: "\"dictation_completed\"", range: failure.upperBound..<capEnd.lowerBound) else {
                assertTrue(false, "production session-cap completion must label delivery and failure after save proof")
                return
            }
            assertTrue(snapshot.lowerBound < saveProof.lowerBound && saveProof.lowerBound < delivery.lowerBound && delivery.lowerBound < failure.lowerBound && failure.lowerBound < track.lowerBound,
                "failure classification must reach the terminal completion event without claiming saved delivery")
        } catch {
            assertTrue(false, "production controller source should be readable: \(error)")
        }
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
