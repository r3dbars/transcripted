import Foundation

func testMeetingAutoRecordNoteCopy() {
    runSuite("the auto-record note names Stop and Discard") {
        let prompt = MeetingAutoRecordNoteCopy.prompt
        assertEqual(prompt.title, "Recording automatically")
        assertEqual(prompt.primaryTitle, "Stop")
        assertEqual(prompt.secondaryTitle, "Discard")
        assertTrue(prompt.countdown.isEmpty, "the consent note has no countdown")
    }

    runSuite("auto-record island actions stop or discard only while the note is up") {
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingPrimary, noteVisible: true, overlayPromptActive: false
            ),
            .stop
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingStop, noteVisible: true, overlayPromptActive: false
            ),
            .stop
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingSecondary, noteVisible: true, overlayPromptActive: false
            ),
            .discard
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingPrimary, noteVisible: true, overlayPromptActive: true
            ),
            .inherit,
            "Call ended and other warnings keep their own buttons"
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingSecondary, noteVisible: false, overlayPromptActive: false
            ),
            .inherit
        )
    }
}
