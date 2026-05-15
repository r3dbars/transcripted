import Foundation

func testRecentCaptureScanners() {
    runSuite("RecentMeetingSpeakerStatus.detect flags generic speaker labels") {
        let markdown = """
        # Design review

        ## Transcript

        **00:01**  [System/Speaker 1]
        We should review this later.

        **00:12**  [Mic/Unknown speaker]
        I can follow up.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .needsReview(2),
            "Generic speaker labels should surface as needing review"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.detect treats named speakers as ready") {
        let markdown = """
        # Product sync

        ## Transcript

        **00:01**  [System/Maya]
        The plan looks good.

        **00:12**  [Mic/Justin]
        I will ship the follow-up.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .ready,
            "Named speakers should not create a review badge"
        )
    }
}
