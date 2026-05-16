import Foundation

func testHomeDeleteConfirmationPolicy() {
    runSuite("HomeDeleteConfirmationPolicy meeting delete copy is explicit") {
        let presentation = HomeDeleteConfirmationPolicy.meeting

        assertEqual(
            presentation.title,
            "Delete this meeting?",
            "meeting delete alert should name the destructive action"
        )
        assertEqual(
            presentation.message,
            "Do you want to delete all of the audio and the transcript that has to do with this meeting? This cannot be undone.",
            "meeting delete alert should explicitly mention audio and transcript"
        )
        assertEqual(
            presentation.confirmTitle,
            "Delete Meeting",
            "destructive button should be specific"
        )
    }

    runSuite("HomeDeleteConfirmationPolicy failed meeting delete copy is explicit") {
        let presentation = HomeDeleteConfirmationPolicy.failedMeeting

        assertEqual(
            presentation.title,
            "Delete this failed meeting?",
            "failed meeting delete alert should name the destructive action"
        )
        assertTrue(
            presentation.message.contains("saved retry audio"),
            "failed meeting delete alert should explain it deletes retry audio"
        )
        assertEqual(
            presentation.confirmTitle,
            "Delete Failed Meeting",
            "destructive button should be specific"
        )
    }
}
