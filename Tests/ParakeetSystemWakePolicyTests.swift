import Foundation

func testParakeetSystemWakePolicy() {
    runSuite("ParakeetSystemWakePolicy.decision — shared meeting mic recording skips teardown") {
        assertEqual(
            ParakeetSystemWakePolicy.decision(sharedMeetingMicRecording: true),
            .skipSharedMeetingMic,
            "wake must not tear down the dormant dictation AVAudioEngine while meeting capture owns the live audio graph"
        )
    }

    runSuite("ParakeetSystemWakePolicy.decision — regular dictation recovers its own audio graph") {
        assertEqual(
            ParakeetSystemWakePolicy.decision(sharedMeetingMicRecording: false),
            .tearDownAudioGraph,
            "wake should still reset dictation's own audio graph when it isn't borrowing the meeting mic"
        )
    }
}
