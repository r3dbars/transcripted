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

    runSuite("RecentMeetingSpeakerStatus.detect ignores generic words in transcript text") {
        let markdown = """
        # Product sync

        ## Transcript

        **00:01**  [System/Maya]
        The customer said Speaker 1 and Unknown speaker during the demo.

        **00:12**  [Mic/Justin]
        I wrote Review later in the notes, but this speaker label is named.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .ready,
            "Only actual speaker labels should create review work"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.detect flags legacy inline generic labels") {
        let markdown = """
        # Legacy recording

        ## Full Transcript

        [00:01] [Mic/Speaker 1] Hello there.

        [00:05] [System/Review later] Nice to meet you.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .needsReview(2),
            "Legacy inline transcript labels should still surface review work"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.detect deduplicates repeated generic labels") {
        let markdown = """
        # Repeated generic labels

        ## Transcript

        **00:01** [Mic/Speaker 1]
        First line.

        **00:02** [System/Speaker 1]
        Same generic label again.

        **00:03** [System/Unknown speaker]
        Another generic label.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .needsReview(2),
            "speaker review badges should count unique generic labels, not every line"
        )
        assertEqual(
            RecentMeetingSpeakerStatus.needsReview(1).summary,
            "1 speaker needs review",
            "singular speaker summary should read naturally"
        )
        assertEqual(
            RecentMeetingSpeakerStatus.ready.summary,
            "Speakers ready",
            "ready speaker status should stay terse"
        )
    }

    runSuite("RecentMeetingSpeakerReviewActionPolicy hides stale meeting review buttons when people queue is clean") {
        assertFalse(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .needsReview(1),
                hasSpeakerReviewWork: false
            ),
            "A generic old transcript should not keep showing a review button after the Speakers queue is clean"
        )
    }

    runSuite("RecentMeetingSpeakerReviewActionPolicy shows actionable meeting review buttons") {
        assertTrue(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .needsReview(1),
                hasSpeakerReviewWork: true
            ),
            "Generic speaker labels should still show a review button while Speakers has review work"
        )
        assertFalse(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .ready,
                hasSpeakerReviewWork: true
            ),
            "Ready meetings should not show a speaker review button"
        )
    }
}
