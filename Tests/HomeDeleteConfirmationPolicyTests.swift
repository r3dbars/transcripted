import Foundation

func testHomeDeleteConfirmationPolicy() {
    runSuite("HomeDeleteConfirmationPolicy failed meeting delete copy is explicit") {
        let presentation = HomeDeleteConfirmationPolicy.failedMeeting

        assertEqual(
            presentation.title,
            "Delete this failed meeting?",
            "failed meeting delete alert should name the destructive action"
        )
        assertTrue(
            presentation.message.contains("saved audio"),
            "failed meeting delete alert should explain it deletes retry audio"
        )
        assertEqual(
            presentation.confirmTitle,
            "Delete Failed Meeting",
            "destructive button should be specific"
        )
    }
}
