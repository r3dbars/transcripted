import Foundation

func testMeetingCaptureTerminalPolicy() {
    runSuite("Current-recording discard callbacks leave journal-recovery ownership alone") {
        assertTrue(MeetingCaptureTerminalPolicy.mayDiscardFinalizedAudio(finalizationOwner: .audioFinalizer))
        assertFalse(MeetingCaptureTerminalPolicy.mayDiscardFinalizedAudio(finalizationOwner: .recordingJournalRecovery))
    }
    runSuite("Post-await URL clears require the same explicit Stop generation") {
        assertTrue(MeetingCaptureTerminalPolicy.mayClearPublishedURLs(resultStopGeneration: 12, currentGeneration: 12))
        assertFalse(MeetingCaptureTerminalPolicy.mayClearPublishedURLs(resultStopGeneration: nil, currentGeneration: 12))
        assertFalse(MeetingCaptureTerminalPolicy.mayClearPublishedURLs(resultStopGeneration: 12, currentGeneration: 13))
        assertFalse(MeetingCaptureTerminalPolicy.mayClearPublishedURLs(resultStopGeneration: 13, currentGeneration: 12))
        assertTrue(MeetingCaptureTerminalPolicy.mayClearPublishedURLs(resultStopGeneration: 0, currentGeneration: 0))
    }
}
