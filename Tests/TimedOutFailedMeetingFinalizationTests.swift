import Foundation

func testTimedOutFailedMeetingFinalization() {
    runSuite("Timed-out finalization buffers callback-first delivery until the row persists") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        let failedID = UUID()
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimedOutFinalization-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let deletedSegmentURL = testDirectory.appendingPathComponent("meeting-mic.wav")
        let finalizedMicURL = testDirectory.appendingPathComponent("meeting-mic_merged.wav")
        FileManager.default.createFile(atPath: finalizedMicURL.path, contents: Data("finalized".utf8))
        let result = CaptureStopResult(
            micURL: finalizedMicURL,
            systemURL: nil,
            didTimeOut: false
        )

        if case .buffered = handoff.receive(result, for: failedID, failedMeetingIsPersisted: false) {
            // Expected.
        } else {
            assertionFailure("a completion cannot promote audio before its durable failed row exists")
        }
        assertEqual(
            handoff.failedMeetingDidPersist(id: failedID)?.micURL,
            finalizedMicURL,
            "row persistence should receive the finalized merged path, not the deleted segment path"
        )
        assertFalse(
            handoff.failedMeetingDidPersist(id: failedID)?.micURL == deletedSegmentURL,
            "the provisional segment path must never replace a buffered finalized result"
        )
        let persistenceAudio = handoff.audioForPersistence(
            id: failedID,
            provisionalMicURL: nil,
            provisionalSystemURL: nil
        )
        assertEqual(
            persistenceAudio.micURL,
            finalizedMicURL,
            "callback-first finalization must supply the durable row when the timeout snapshot is empty"
        )
        let persistenceAudioWithDeletedSegment = handoff.audioForPersistence(
            id: failedID,
            provisionalMicURL: deletedSegmentURL,
            provisionalSystemURL: nil
        )
        assertEqual(
            persistenceAudioWithDeletedSegment.micURL,
            finalizedMicURL,
            "callback-first finalization must replace a deleted provisional segment with usable finalized audio"
        )

        handoff.markDeliverySucceeded(id: failedID)
        assertNil(
            handoff.failedMeetingDidPersist(id: failedID),
            "successful durable promotion should consume the buffered result exactly once"
        )
    }

    runSuite("Timed-out finalization delivers immediately when the failed row wins the race") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        let failedID = UUID()
        let finalizedMicURL = URL(fileURLWithPath: "/tmp/row-first-mic_merged.wav")
        let finalizedSystemURL = URL(fileURLWithPath: "/tmp/row-first-system.wav")
        let result = CaptureStopResult(
            micURL: finalizedMicURL,
            systemURL: finalizedSystemURL,
            didTimeOut: false
        )

        assertNil(
            handoff.failedMeetingDidPersist(id: failedID),
            "row-first persistence should not invent a completion"
        )
        let action = handoff.receive(
            result,
            for: failedID,
            failedMeetingIsPersisted: true
        )
        if case .promote(let deliverable) = action {
            assertEqual(deliverable.micURL, finalizedMicURL)
            assertEqual(deliverable.systemURL, finalizedSystemURL)
        } else {
            assertionFailure("row-first completion should promote immediately")
        }

        handoff.markDeliverySucceeded(id: failedID)
        assertNil(handoff.failedMeetingDidPersist(id: failedID))
    }

    runSuite("Timed-out finalization keeps a failed delivery available for recovery") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        let failedID = UUID()
        let result = CaptureStopResult(
            micURL: nil,
            systemURL: URL(fileURLWithPath: "/tmp/system-only.wav"),
            didTimeOut: false
        )

        if case .promote = handoff.receive(result, for: failedID, failedMeetingIsPersisted: true) {
            // Expected.
        } else {
            assertionFailure("persisted row should own immediate promotion")
        }
        assertEqual(
            handoff.failedMeetingDidPersist(id: failedID)?.systemURL,
            result.systemURL,
            "a failed promotion must retain the completion for the store's existing mic placeholder"
        )
        handoff.markPersistenceFailed(id: failedID)
        assertNil(
            handoff.failedMeetingDidPersist(id: failedID),
            "failed row persistence must release the buffer because the journal owns durable recovery"
        )
    }

    runSuite("Timed-out terminal ownership discards late audio after row removal") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        var registry = TimedOutStopCompletionRegistry()
        let failedID = UUID()
        let lateResult = CaptureStopResult(
            micURL: URL(fileURLWithPath: "/tmp/terminal-mic_merged.wav"),
            systemURL: nil,
            didTimeOut: false
        )

        assertNil(handoff.failedMeetingDidPersist(id: failedID))
        assertNil(handoff.markTerminalDiscard(id: failedID))
        registry.register(
            generation: 8,
            owner: .failedMeeting(failedID)
        ) { _ in
            assertionFailure("expiry must release the row-specific closure")
        }
        assertTrue(registry.expire(generation: 8))
        guard case .expired(.failedMeeting(let expiredID)) = registry.resolve(generation: 8) else {
            assertionFailure("expiry must retain closure-free failed-row identity")
            return
        }
        if case .discard(let discarded) = handoff.receive(
            lateResult,
            for: expiredID,
            failedMeetingIsPersisted: false
        ) {
            assertEqual(discarded.micURL, lateResult.micURL)
        } else {
            assertionFailure("a terminal delete or retry must own its late callback as cleanup-only")
        }
        assertEqual(handoff.terminalOwnershipCount, 0)
    }

    runSuite("Timed-out ownership detects a row removed by another Core completion seam") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        let failedID = UUID()
        assertNil(handoff.failedMeetingDidPersist(id: failedID))
        assertTrue(handoff.persistedOwnershipIDs.contains(failedID))

        let lateResult = CaptureStopResult(
            micURL: URL(fileURLWithPath: "/tmp/core-removed-mic_merged.wav"),
            systemURL: nil,
            didTimeOut: false
        )
        if case .discard = handoff.receive(
            lateResult,
            for: failedID,
            failedMeetingIsPersisted: false
        ) {
            // The persisted row disappeared before the callback reached Home.
        } else {
            assertionFailure("a Core-side row removal must make its late callback cleanup-only")
        }
        assertFalse(handoff.persistedOwnershipIDs.contains(failedID))
    }

    runSuite("Timed-out persistence failure leaves late audio to journal recovery") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        let failedID = UUID()
        assertNil(handoff.failedMeetingDidPersist(id: failedID))
        handoff.markPersistenceFailed(id: failedID)

        let action = handoff.receive(
            CaptureStopResult(micURL: nil, systemURL: nil, didTimeOut: false),
            for: failedID,
            failedMeetingIsPersisted: false
        )
        if case .journalOwned = action {
            // Expected: keep disk recovery artifacts, but retain no callback result.
        } else {
            assertionFailure("failed row persistence should leave the durable journal in charge")
        }
        assertEqual(handoff.terminalOwnershipCount, 0)
    }

    runSuite("Timed-out terminal and failed-promotion ownership stays bounded") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        let ids = (0..<6).map { _ in UUID() }
        for id in ids {
            assertNil(handoff.failedMeetingDidPersist(id: id))
            assertNil(handoff.markTerminalDiscard(id: id))
        }
        assertEqual(handoff.terminalOwnershipCount, 4)

        var evictedAwaitingHandoff = TimedOutFailedMeetingFinalizationHandoff()
        for id in ids {
            assertNil(evictedAwaitingHandoff.failedMeetingDidPersist(id: id))
        }
        assertFalse(evictedAwaitingHandoff.hasOwnership(of: ids[0]))
        assertNil(evictedAwaitingHandoff.markTerminalDiscard(id: ids[0]))
        assertEqual(
            ExpiredTimedOutCompletionFallback.action(hasMatchingJournal: false),
            .discardFinalizedAudio,
            "a deleted row evicted from the handoff must use durable fallback cleanup"
        )

        var failedPromotionHandoff = TimedOutFailedMeetingFinalizationHandoff()
        for id in ids {
            _ = failedPromotionHandoff.receive(
                CaptureStopResult(
                    micURL: URL(fileURLWithPath: "/tmp/bounded-\(id.uuidString).wav"),
                    systemURL: nil,
                    didTimeOut: false
                ),
                for: id,
                failedMeetingIsPersisted: true
            )
        }
        assertEqual(failedPromotionHandoff.bufferedResultCount, 4)
        assertNil(
            failedPromotionHandoff.failedMeetingDidPersist(id: ids[0]),
            "an older failed promotion should fall back to its journal instead of growing the in-memory buffer"
        )
    }

    runSuite("Timed-out completion ownership prunes never-completing older stops") {
        var registry = TimedOutStopCompletionRegistry()
        var deliveredGeneration: UInt64?

        let failedID = UUID()
        registry.register(
            generation: 12,
            owner: .failedMeeting(failedID)
        ) { _ in deliveredGeneration = 12 }
        registry.prune(olderThan: 12)
        assertTrue(registry.generations.contains(12), "the immediately preceding stop stays owned across the next start")
        assertEqual(registry.handlerCount, 1)

        registry.register(generation: 14) { _ in deliveredGeneration = 14 }
        registry.prune(olderThan: 14)
        assertFalse(registry.generations.contains(12), "an older never-completing stop must not retain its generation")
        assertEqual(registry.handlerCount, 1, "pruning must release the older stop's closure")
        guard case .expired(.failedMeeting(let prunedID)) = registry.resolve(generation: 12) else {
            assertionFailure("pruning must preserve value-only failed-row identity")
            return
        }
        assertEqual(prunedID, failedID)

        guard case .pending(let handler) = registry.resolve(generation: 14) else {
            assertionFailure("the current timed-out stop should retain its callback")
            return
        }
        handler?(CaptureStopResult(micURL: nil, systemURL: nil, didTimeOut: false))
        assertEqual(deliveredGeneration, 14)
        assertTrue(registry.generations.isEmpty)
        assertEqual(registry.handlerCount, 0)
    }

    runSuite("Timed-out completion ownership expires without a later recording") {
        var registry = TimedOutStopCompletionRegistry()
        registry.register(generation: 22, owner: .discard) { _ in
            assertionFailure("an expired per-stop closure must never be delivered")
        }

        assertTrue(registry.expire(generation: 22))
        assertTrue(registry.generations.isEmpty)
        assertEqual(registry.handlerCount, 0, "expiry must release the retained closure")
        guard case .expired(.discard) = registry.resolve(generation: 22) else {
            assertionFailure("expiry must retain explicit cleanup disposition without retaining a closure")
            return
        }
        assertFalse(registry.expire(generation: 22), "expiry must be idempotent")
    }

    runSuite("Timed-out completion owner tombstones stay bounded") {
        var registry = TimedOutStopCompletionRegistry()
        for generation in 1...6 {
            registry.register(generation: UInt64(generation), owner: .discard, handler: nil)
            assertTrue(registry.expire(generation: UInt64(generation)))
        }

        assertEqual(registry.handlerCount, 0)
        assertEqual(registry.expiredOwnerCount, 4)
        guard case .expired(nil) = registry.resolve(generation: 1) else {
            assertionFailure("an evicted value tombstone must keep the stable expired fallback")
            return
        }
        assertEqual(
            ExpiredTimedOutCompletionFallback.action(hasMatchingJournal: false),
            .discardFinalizedAudio,
            "an evicted terminal owner with no durable row or journal must discard its late files"
        )
        assertEqual(
            ExpiredTimedOutCompletionFallback.action(hasMatchingJournal: true),
            .recoverJournal,
            "an evicted callback-first owner must keep journal recovery intact"
        )
        guard case .expired(.discard) = registry.resolve(generation: 6) else {
            assertionFailure("the newest bounded tombstone must retain its terminal disposition")
            return
        }
    }
}
