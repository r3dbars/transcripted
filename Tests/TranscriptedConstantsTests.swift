import Foundation

func testTranscriptedConstants() async {
    runSuite("TranscriptedConstants exposes the Parakeet minimum audio threshold") {
        assertEqual(TranscriptedConstants.parakeetMinimumInferenceSamples, 16_000, "Parakeet minimum sample count should match one second at 16kHz")
        assertFalse(TranscriptedConstants.hasMinimumParakeetAudioSamples(15_999), "sub-second audio should be rejected before transcription")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(16_000), "one second of audio should be accepted")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(20_000), "longer audio should still be accepted")
    }

    runSuite("TranscriptedConstants restores consumed borrowed clipboard before auto-enter") {
        assertTrue(
            TranscriptedConstants.clipboardRestoreDelay < TranscriptedConstants.dictationAutoEnterDelay,
            "clipboard restore should happen before follow-up keypresses and before users can easily paste stale dictation text"
        )
        assertTrue(
            TranscriptedConstants.clipboardRestoreFallbackDelay > TranscriptedConstants.clipboardRestoreDelay,
            "fallback restore should give slow paste consumers longer to read the borrowed dictation text"
        )
        assertTrue(
            TranscriptedConstants.clipboardRestoreFallbackDelay >= 2_000_000_000,
            "fallback restore should cover slower apps that consume Cmd+V after the old sub-second window"
        )
        assertTrue(
            TranscriptedConstants.clipboardRestoreFallbackDelay <= 3_000_000_000,
            "fallback restore should still return the user's clipboard promptly when no paste consumer reads it"
        )
        assertTrue(
            TranscriptedConstants.dictationAutoEnterDelay <= 60_000_000,
            "Auto Enter follows a proven paste, so its settle stays short"
        )
        assertTrue(
            TranscriptedConstants.clipboardRestoreDelay >= 20_000_000,
            "a proven paste still gets a margin before the user's clipboard comes back"
        )
        assertTrue(
            TranscriptedConstants.dictationAutoEnterDelay <= 150_000_000,
            "auto-enter should stay tuned for a fast opt-in stop path"
        )
    }

    runSuite("TranscriptedConstants keeps no-speech recovery copy readable") {
        assertTrue(
            TranscriptedConstants.noSpeechDismissDelay >= 2_000_000_000,
            "no-speech overlay should stay visible long enough to read the physical-key recovery hint"
        )
        assertTrue(
            TranscriptedConstants.noSpeechDismissDelay < TranscriptedConstants.errorDismissDelay,
            "no-speech recovery should still dismiss faster than regular error states"
        )
    }

    runSuite("TranscriptedConstants stretches overlay messages for reading time") {
        let base = TranscriptedConstants.errorDismissDelay
        assertEqual(
            TranscriptedConstants.messageDismissDelay(base: base, characterCount: 20),
            base,
            "a short line keeps the flat base delay"
        )
        assertEqual(
            TranscriptedConstants.messageDismissDelay(base: base, characterCount: 100),
            100 * TranscriptedConstants.messageDwellPerCharacter,
            "a two-line message gets reading time instead of vanishing after 2.5 seconds"
        )
        assertEqual(
            TranscriptedConstants.messageDismissDelay(base: base, characterCount: 10_000),
            TranscriptedConstants.messageDwellMaximum,
            "a very long message still goes away on its own"
        )
        assertEqual(
            TranscriptedConstants.messageDismissDelay(base: TranscriptedConstants.clipboardNoticeDismissDelay, characterCount: 0),
            TranscriptedConstants.clipboardNoticeDismissDelay,
            "the longer clipboard-notice base is never shortened"
        )
    }

    runSuite("TranscriptedConstants gives meeting quit preservation enough time") {
        let meetingStopTimeoutSeconds = TimeInterval(TranscriptedConstants.meetingStopTimeout) / 1_000_000_000
        assertTrue(
            TranscriptedConstants.meetingTerminationFinishWaitTimeout > meetingStopTimeoutSeconds,
            "termination wait should outlast meeting stop timeout so retained audio can be queued before quit"
        )
        let maximumStopTimeoutSeconds = TimeInterval(TranscriptedConstants.meetingMaximumStopTimeout) / 1_000_000_000
        assertTrue(
            TranscriptedConstants.meetingTerminationFinishWaitTimeout > maximumStopTimeoutSeconds,
            "termination wait should outlast the longest scaled stop timeout"
        )
        let permissionRequestTimeoutSeconds =
            TimeInterval(TranscriptedConstants.systemAudioPermissionRequestTimeout) / 1_000_000_000
        assertTrue(
            TranscriptedConstants.meetingTerminationFinishWaitTimeout > permissionRequestTimeoutSeconds,
            "termination wait should outlast a first-run System Audio permission prompt"
        )
    }

    runSuite("TranscriptedConstants lets ScreenCaptureKit finish before the meeting start deadline") {
        let screenCaptureKitStartTimeout: UInt64 = 8_000_000_000
        assertEqual(
            TranscriptedConstants.meetingStartTimeout,
            12_000_000_000,
            "meeting start should use the same 12-second budget as the live capture smoke"
        )
        assertTrue(
            TranscriptedConstants.meetingStartTimeout > screenCaptureKitStartTimeout,
            "the outer meeting deadline must outlast ScreenCaptureKit's 8-second callback timeout"
        )
        assertEqual(
            TranscriptedConstants.systemAudioPermissionRequestTimeout,
            120_000_000_000,
            "the System Audio permission probe must outlast the first-run macOS dialog"
        )
        assertTrue(
            TranscriptedConstants.systemAudioPermissionRequestTimeout
                > TranscriptedConstants.meetingStartTimeout,
            "first-run permission wait must be longer than the post-grant streaming deadline"
        )
    }

    runSuite("TranscriptedConstants scales meeting stop timeout for long recordings") {
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 10 * 60),
            TranscriptedConstants.meetingStopTimeout,
            "short meetings should keep the fast base stop timeout"
        )
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 119 * 60),
            TranscriptedConstants.meetingStopTimeout + (2 * TranscriptedConstants.meetingStopTimeoutGrowthStep),
            "meetings close to two hours should get the two-hour stop budget"
        )
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 2 * 60 * 60),
            TranscriptedConstants.meetingStopTimeout + (2 * TranscriptedConstants.meetingStopTimeoutGrowthStep),
            "two-hour meetings should get extra time to flush and merge audio"
        )
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 12 * 60 * 60),
            TranscriptedConstants.meetingMaximumStopTimeout,
            "very long meetings should cap the stop wait"
        )
    }

    runSuite("TranscriptedConstants sizes the dictation audio buffer to the session cap") {
        assertTrue(
            Double(TranscriptedConstants.audioBufferCapacitySeconds) > TranscriptedConstants.dictationSessionMaxDuration,
            "buffer capacity should cover the full session cap plus stop-path headroom"
        )
        assertTrue(
            Double(TranscriptedConstants.audioBufferCapacitySeconds) <= TranscriptedConstants.dictationSessionMaxDuration + 120,
            "buffer capacity should stay near the session cap instead of reserving a half-hour worst case for the process lifetime"
        )
        assertEqual(
            TranscriptedConstants.dictationSessionMaxDuration,
            5 * 60,
            "the dictation session cap should stay at 5 minutes"
        )
    }

    runSuite("TranscriptedConstants keeps the model load wait budget aligned with the poll parameters") {
        assertEqual(
            TranscriptedConstants.modelLoadWaitBudget,
            Double(TranscriptedConstants.modelLoadMaxIterations)
                * Double(TranscriptedConstants.modelLoadPollInterval) / 1_000_000_000,
            "joined model-load waits should keep the same overall ceiling as the legacy poll loop"
        )
        assertEqual(
            TranscriptedConstants.modelLoadWaitBudget,
            120,
            "model load waits should keep the 120s ceiling users already rely on"
        )
    }

    runSuite("TranscriptedConstants keeps failed meeting audio cleanup conservative") {
        assertTrue(
            TranscriptedConstants.failedMeetingAudioRetentionDays >= 30,
            "failed meeting audio should stay recoverable long enough for users to retry or delete it intentionally"
        )
        assertTrue(
            TranscriptedConstants.failedMeetingAudioRetentionCapDays > TranscriptedConstants.failedMeetingAudioRetentionDays,
            "the Never-delete-audio cap must be longer than the floor, or the retention choice changes nothing for failed meetings"
        )
        assertTrue(
            TranscriptedConstants.failedMeetingAudioRetentionCapDays <= 365,
            "the failed queue must stay bounded even when the user keeps audio forever"
        )
    }

    await runSuite("TranscriptedConstants.withTimeout — returns completed work before deadline") {
        let result = try? await TranscriptedConstants.withTimeout(seconds: 1) {
            "ok"
        }

        assertEqual(result, "ok", "completed async work should return its value")
    }

    await runSuite("TranscriptedConstants.withTimeout — cancels work after deadline") {
        let cancellationObserved = DetachedTimeoutWorkFlag()
        do {
            _ = try await TranscriptedConstants.withTimeout(seconds: 0.01) {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    if error is CancellationError { cancellationObserved.set() }
                    throw error
                }
                return "late"
            }
            assertTrue(false, "deadline must throw instead of returning late work")
        } catch is CancellationError {
            assertTrue(cancellationObserved.isSet, "structured timeout must cancel and join cooperative work")
        } catch {
            assertTrue(false, "deadline must throw CancellationError, got \(error)")
        }
    }

    await runSuite("TranscriptedConstants.withDetachedTimeout — returns completed work before deadline") {
        let result = try? await TranscriptedConstants.withDetachedTimeout(seconds: 1) {
            "ok"
        }

        assertEqual(result, "ok", "detached timeout should return completed async work")
    }

    await runSuite("TranscriptedConstants.withDetachedTimeout — returns even when work ignores cancellation") {
        let releaseWork = ParakeetAsyncInterleavingGate()
        let workFinished = ParakeetAsyncInterleavingGate()
        let cancellationObserved = DetachedTimeoutWorkFlag()
        let cleanupNeeded = DetachedTimeoutWorkFlag()
        // A harness escape hatch prevents a broken timeout from leaving a
        // suspended task forever. Correctness is the event order, not elapsed
        // time: work must remain held when the deadline returns.
        let cleanup = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            cleanupNeeded.set()
            await releaseWork.open()
            // Also bound the drain if a regression never invokes the operation.
            await workFinished.open()
        }
        defer { cleanup.cancel() }

        do {
            _ = try await TranscriptedConstants.withDetachedTimeout(seconds: 0.01) {
                // A continuation gate remains held even after cancellation;
                // try? Task.sleep would instead finish immediately when cancelled.
                await releaseWork.wait()
                if Task.isCancelled { cancellationObserved.set() }
                await workFinished.open()
                return "late"
            }
            assertTrue(false, "deadline must throw instead of returning late work")
        } catch is CancellationError {
            let finishedBeforeRelease = await workFinished.opened()
            assertFalse(finishedBeforeRelease, "deadline must return before non-cooperative work is released")
        } catch {
            assertTrue(false, "deadline must throw CancellationError, got \(error)")
        }

        await releaseWork.open()
        await workFinished.wait()
        assertFalse(cleanupNeeded.isSet, "the operation must unwind without the harness escape hatch")
        assertTrue(cancellationObserved.isSet, "timed-out work must receive cancellation even when it unwinds later")
    }

    for detached in [false, true] {
        await runSuite("TranscriptedConstants timeout preserves operation errors (detached=\(detached))") {
            let operation: @Sendable () async throws -> String = {
                throw TimeoutTestFailure.operation
            }
            do {
                if detached {
                    _ = try await TranscriptedConstants.withDetachedTimeout(seconds: 30, operation: operation)
                } else {
                    _ = try await TranscriptedConstants.withTimeout(seconds: 30, operation: operation)
                }
                assertTrue(false, "a failed operation must not return a value")
            } catch TimeoutTestFailure.operation {
                assertTrue(true, "operation failure must reach the caller unchanged")
            } catch {
                assertTrue(false, "operation failure must not become a timeout or another error, got \(error)")
            }
        }
    }
}

private enum TimeoutTestFailure: Error { case operation }

/// Records cancellation observed by the real operation passed to the timeout.
private final class DetachedTimeoutWorkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
