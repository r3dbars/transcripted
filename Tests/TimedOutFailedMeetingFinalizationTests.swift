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

        assertNil(
            handoff.receive(result, for: failedID, failedMeetingIsPersisted: false),
            "a completion cannot promote audio before its durable failed row exists"
        )
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
        let deliverable = handoff.receive(
            result,
            for: failedID,
            failedMeetingIsPersisted: true
        )
        assertEqual(deliverable?.micURL, finalizedMicURL)
        assertEqual(deliverable?.systemURL, finalizedSystemURL)

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

        assertNotNil(handoff.receive(result, for: failedID, failedMeetingIsPersisted: true))
        assertEqual(
            handoff.failedMeetingDidPersist(id: failedID)?.systemURL,
            result.systemURL,
            "a failed promotion must retain the completion for the store's existing mic placeholder"
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
