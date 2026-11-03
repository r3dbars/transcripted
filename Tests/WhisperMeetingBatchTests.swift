import Foundation

// Promise: a Whisper meeting batch decodes one segment at a time.
//
// WhisperKit's batch API runs its workers as parallel `transcribe` calls on
// one shared WhisperKit instance, and those calls write the instance's
// shared progress and decoder state without a lock. Crash APPLE-MACOS-45
// (objc_release at an autorelease-pool pop, Whisper meeting users only)
// started in the release that turned on 4 workers.
// Synthetic: this checks the worker count handed to WhisperKit, not a real
// model run; the crash itself is a race that a unit test can't reproduce.

func testWhisperMeetingBatch() {
    runSuite("A Whisper meeting batch decodes one segment at a time") {
        for segmentCount in [1, 2, 4, 8, 500] {
            assertEqual(
                WhisperMeetingBatchPolicy.simultaneousDecodes(segmentCount: segmentCount),
                1,
                "\(segmentCount) segments must never decode side by side on one WhisperKit instance"
            )
        }
    }

    runSuite("An empty Whisper meeting batch decodes nothing") {
        assertEqual(WhisperMeetingBatchPolicy.simultaneousDecodes(segmentCount: 0), 0, "no segments, no decodes")
    }
}
