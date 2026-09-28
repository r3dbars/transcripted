import Foundation

func testMeetingPillFinishPresentation() {
    runSuite("MeetingPillFinishPresentation shows a whole percent only mid-run") {
        assertNil(MeetingPillFinishPresentation.percent(progress: nil), "no progress yet should show no number")
        assertNil(MeetingPillFinishPresentation.percent(progress: 0), "zero should not read as 0%")
        assertNil(MeetingPillFinishPresentation.percent(progress: 1), "done should not read as 100% on a still-working pill")
        assertNil(MeetingPillFinishPresentation.percent(progress: .nan), "a bad value should show no number")
        assertEqual(MeetingPillFinishPresentation.percent(progress: 0.42), 42, "progress should round down to a whole percent")
        assertEqual(MeetingPillFinishPresentation.percent(progress: 0.001), 1, "a tiny start should still show at least 1%")
        assertEqual(MeetingPillFinishPresentation.percent(progress: 0.999), 99, "almost done should cap at 99%")
    }

    runSuite("MeetingPillFinishPresentation names queued meetings") {
        assertNil(MeetingPillFinishPresentation.queuedText(queuedCount: 0), "nothing queued should say nothing")
        assertEqual(MeetingPillFinishPresentation.queuedText(queuedCount: 1), "1 more waiting")
        assertEqual(MeetingPillFinishPresentation.queuedText(queuedCount: 3), "3 more waiting")
    }

    runSuite("MeetingPillFinishPresentation builds the pill and menu bar lines") {
        assertEqual(MeetingPillFinishPresentation.pillDetail(progress: 0.42, queuedCount: 1), "42% · 1 more waiting")
        assertEqual(MeetingPillFinishPresentation.pillDetail(progress: 0.42, queuedCount: 0), "42%")
        assertEqual(MeetingPillFinishPresentation.pillDetail(progress: nil, queuedCount: 2), "2 more waiting")
        assertEqual(MeetingPillFinishPresentation.pillDetail(progress: nil, queuedCount: 0), "")

        assertEqual(MeetingPillFinishPresentation.menuStatus(progress: 0.42, queuedCount: 1), "Transcribing 42% · 1 more waiting")
        assertEqual(MeetingPillFinishPresentation.menuStatus(progress: 0.42, queuedCount: 0), "Transcribing 42%")
        assertEqual(MeetingPillFinishPresentation.menuStatus(progress: nil, queuedCount: 0), "Transcribing")
    }

    runSuite("MeetingPillFinishPresentation saved pill names the meeting and stays long enough to click") {
        assertEqual(MeetingPillFinishPresentation.savedDetail(meetingTitle: "Weekly sync"), "Weekly sync")
        assertEqual(MeetingPillFinishPresentation.savedDetail(meetingTitle: "  "), "Ready to read")
        assertEqual(MeetingPillFinishPresentation.savedDetail(meetingTitle: nil), "Ready to read")
        assertTrue(
            MeetingPillFinishPresentation.savedPillDwellSeconds >= 5,
            "the saved pill must stay up long enough to read the title and click Open"
        )
    }

    runSuite("MeetingPillFinishPresentation error pill offers Open only when there is a row to open") {
        assertTrue(
            MeetingPillFinishPresentation.errorOffersOpenMeetings(failureKind: .transcriptionInferenceFailed, hasFailedMeetingRowForError: true),
            "a failed transcript with a saved row should offer Open"
        )
        assertFalse(
            MeetingPillFinishPresentation.errorOffersOpenMeetings(failureKind: .transcriptionInferenceFailed, hasFailedMeetingRowForError: false),
            "no failed row from this failure means nothing to open"
        )
        assertTrue(
            MeetingPillFinishPresentation.errorOffersOpenMeetings(failureKind: .systemAudioPermission, hasFailedMeetingRowForError: true),
            "missing call audio from the pipeline leaves a retry-ready row, so Open should match Home"
        )
        assertTrue(
            MeetingPillFinishPresentation.errorOffersOpenMeetings(failureKind: .pipelineBusy, hasFailedMeetingRowForError: true),
            "a recording rejected while busy is saved as a retryable row, so Open should be offered"
        )
        for kind in [
            MeetingFailureKind.microphonePermission,
            .microphoneStartFailed,
            .recordingTooShort,
            .importFileMissing,
            .importUnsupportedFile
        ] {
            assertFalse(
                MeetingPillFinishPresentation.errorOffersOpenMeetings(failureKind: kind, hasFailedMeetingRowForError: true),
                "failures before any audio is saved should not offer Open (\(kind.rawValue))"
            )
        }
    }
}
