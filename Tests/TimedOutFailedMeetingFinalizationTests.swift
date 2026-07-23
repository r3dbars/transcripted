import Foundation

func testTimedOutFailedMeetingFinalization() {
    runSuite("Timed-out finalization buffers callback-first delivery until the row persists") {
        var handoff = TimedOutFailedMeetingFinalizationHandoff()
        let failedID = UUID()
        let deletedSegmentURL = URL(fileURLWithPath: "/tmp/meeting-mic.wav")
        let finalizedMicURL = URL(fileURLWithPath: "/tmp/meeting-mic_merged.wav")
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
        let failedID = UUID()
        let lateResult = CaptureStopResult(
            micURL: URL(fileURLWithPath: "/tmp/terminal-mic_merged.wav"),
            systemURL: nil,
            didTimeOut: false
        )

        assertNil(handoff.failedMeetingDidPersist(id: failedID))
        assertNil(handoff.markTerminalDiscard(id: failedID))
        if case .discard(let discarded) = handoff.receive(
            lateResult,
            for: failedID,
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

        registry.register(generation: 12) { _ in deliveredGeneration = 12 }
        registry.prune(olderThan: 12)
        assertTrue(registry.generations.contains(12), "the immediately preceding stop stays owned across the next start")
        assertEqual(registry.handlerCount, 1)

        registry.register(generation: 14) { _ in deliveredGeneration = 14 }
        registry.prune(olderThan: 14)
        assertFalse(registry.generations.contains(12), "an older never-completing stop must not retain its generation")
        assertEqual(registry.handlerCount, 1, "pruning must release the older stop's closure")

        let handler = registry.takeHandler(for: 14)
        handler?(CaptureStopResult(micURL: nil, systemURL: nil, didTimeOut: false))
        assertEqual(deliveredGeneration, 14)
        assertTrue(registry.generations.isEmpty)
        assertEqual(registry.handlerCount, 0)
    }
}
