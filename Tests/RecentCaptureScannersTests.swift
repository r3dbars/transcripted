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

    runSuite("RecentMeetingRetranscriptionActionPolicy shows saved-audio speaker ID fallback") {
        assertTrue(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .needsReview(1),
                hasRetainedAudio: true,
                hasSpeakerReviewWork: false
            ),
            "A saved meeting with generic labels and retained audio should offer a new speaker-ID pass when no review queue exists"
        )
        assertFalse(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .needsReview(1),
                hasRetainedAudio: false,
                hasSpeakerReviewWork: false
            ),
            "Re-transcription needs retained audio"
        )
        assertFalse(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .needsReview(1),
                hasRetainedAudio: true,
                hasSpeakerReviewWork: true
            ),
            "Existing speaker review work should keep the normal Review speakers action"
        )
        assertFalse(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .ready,
                hasRetainedAudio: true,
                hasSpeakerReviewWork: false
            ),
            "Ready meetings should keep re-transcription in the row menu instead of showing an inline warning action"
        )
    }

    runSuite("SavedMeetingRetranscriptionAvailabilityPolicy blocks while models prepare") {
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: true,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Preparing models...",
            "saved-meeting re-transcription should not accept duplicate clicks while model prep is in flight"
        )
    }

    runSuite("SavedMeetingRetranscriptionAvailabilityPolicy blocks during live work") {
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: true,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Wait for the current dictation to finish before re-transcribing saved audio.",
            "saved-meeting re-transcription should not race an active dictation"
        )
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: true,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Stop the current recording before re-transcribing saved audio.",
            "saved-meeting re-transcription should not start while a meeting is recording"
        )
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: true,
                isSpeakerReviewPending: false
            ),
            "Wait for the current meeting to finish saving or transcribing before re-transcribing saved audio.",
            "saved-meeting re-transcription should stay single-flight with background meeting work"
        )
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: true
            ),
            "Finish the speaker review window before re-transcribing saved audio.",
            "saved-meeting re-transcription should wait until speaker review is resolved"
        )
    }

    runSuite("SavedMeetingRetranscriptionAvailabilityPolicy allows idle saved meetings") {
        assertNil(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "idle saved meetings with retained audio should stay re-transcribable"
        )
    }
}
