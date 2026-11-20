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
        let id = UUID()
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingPrompt(.primary, .autoRecord(id)), noteVisible: true, recordingID: id
            ),
            .stop
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingStop(id), noteVisible: true, recordingID: id
            ),
            .inherit
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingPrompt(.secondary, .autoRecord(id)), noteVisible: true, recordingID: id
            ),
            .discard
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingPrompt(.primary, .autoRecord(id)), noteVisible: true, recordingID: UUID()
            ),
            .inherit,
            "A new recording never inherits an auto-record action"
        )
        assertEqual(
            MeetingAutoRecordIslandActionPolicy.route(
                action: .meetingPrompt(.secondary, .autoRecord(id)), noteVisible: false, recordingID: id
            ),
            .inherit
        )
    }

    runSuite("the auto-record note clears after a short time and yields to the call-audio ask") {
        assertTrue(
            MeetingAutoRecordNoteCopy.isVisible(
                duration: 1, asksAboutCallAudio: false, noteEnabled: true
            ),
            "the consent note should show right after auto-start"
        )
        assertFalse(
            MeetingAutoRecordNoteCopy.isVisible(
                duration: MeetingAutoRecordNoteCopy.visibleDuration,
                asksAboutCallAudio: false,
                noteEnabled: true
            ),
            "the consent note must not stay up for the whole recording"
        )
        assertFalse(
            MeetingAutoRecordNoteCopy.isVisible(
                duration: 1, asksAboutCallAudio: true, noteEnabled: true
            ),
            "the call-audio ask must not be hidden behind the consent note"
        )
    }
}
