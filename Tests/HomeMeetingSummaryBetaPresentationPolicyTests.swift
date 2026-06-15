import Foundation

func testHomeMeetingSummaryBetaPresentationPolicy() {
    runSuite("HomeMeetingSummaryBetaPresentationPolicy hides generated summary state when beta is off") {
        let item = sampleHomeMeetingSummaryBetaItem(summaryPreview: sampleHomeMeetingSummaryBetaPreview())

        assertEqual(
            HomeMeetingSummaryBetaPresentationPolicy.displayTitle(for: item, isEnabled: false),
            "Quick notes",
            "beta off should show the original transcript title"
        )
        assertEqual(
            HomeMeetingSummaryBetaPresentationPolicy.visibleSummaryPreview(for: item, isEnabled: false),
            nil,
            "beta off should hide summary previews"
        )
        assertFalse(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummarySparkle(for: item, isEnabled: false),
            "beta off should hide the local-summary sparkle"
        )
        assertFalse(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowAvailableSummaryDot(for: item, isEnabled: false),
            "beta off should hide the blue summary dot"
        )
        assertFalse(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummaryMenuActions(isEnabled: false),
            "beta off should hide run/open/regenerate summary menu actions"
        )
    }

    runSuite("HomeMeetingSummaryBetaPresentationPolicy shows generated summary state when beta is on") {
        let preview = sampleHomeMeetingSummaryBetaPreview()
        let item = sampleHomeMeetingSummaryBetaItem(summaryPreview: preview)

        assertEqual(
            HomeMeetingSummaryBetaPresentationPolicy.displayTitle(for: item, isEnabled: true),
            "Launch Pricing Review",
            "beta on should show the generated title"
        )
        assertEqual(
            HomeMeetingSummaryBetaPresentationPolicy.visibleSummaryPreview(for: item, isEnabled: true),
            preview,
            "beta on should show the summary preview"
        )
        assertTrue(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummarySparkle(for: item, isEnabled: true),
            "beta on should show the sparkle for summarized meetings"
        )
        assertFalse(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowAvailableSummaryDot(for: item, isEnabled: true),
            "summarized meetings should not show the available-summary dot"
        )
        assertTrue(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummaryMenuActions(isEnabled: true),
            "beta on should show run/open/regenerate summary menu actions"
        )
    }

    runSuite("HomeMeetingSummaryBetaPresentationPolicy shows available summary dot for unsummarized meetings") {
        let item = sampleHomeMeetingSummaryBetaItem(summaryPreview: nil)

        assertTrue(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowAvailableSummaryDot(for: item, isEnabled: true),
            "beta on should mark meetings that can run a local summary"
        )
        assertFalse(
            HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummarySparkle(for: item, isEnabled: true),
            "unsummarized meetings should not show the local-summary sparkle"
        )
    }

    runSuite("HomeLocalSummaryNoticeDismissalPolicy clears only the scheduled notice") {
        let firstNotice = HomeLocalSummaryNotice(
            transcriptURL: URL(fileURLWithPath: "/tmp/first.md"),
            meetingTitle: "First",
            chunkCount: 1
        )
        let newerNotice = HomeLocalSummaryNotice(
            transcriptURL: URL(fileURLWithPath: "/tmp/newer.md"),
            meetingTitle: "Newer",
            chunkCount: 2
        )

        assertEqual(firstNotice.status, "Saved", "completed summary notices should read as saved, not ongoing")
        assertEqual(
            firstNotice.actionTitle,
            "Open enhanced transcript",
            "saved summaries should point to the enhanced transcript"
        )
        assertTrue(firstNotice.shouldAutoDismiss, "saved summaries should clear themselves after a short scan window")
        assertTrue(
            HomeLocalSummaryNoticeDismissalPolicy.autoDismissDelayNanoseconds >= 4_000_000_000,
            "success notice should stay visible long enough to scan"
        )
        assertTrue(
            HomeLocalSummaryNoticeDismissalPolicy.autoDismissDelayNanoseconds <= 10_000_000_000,
            "success notice should not linger like a stuck activity card"
        )
        assertTrue(
            HomeLocalSummaryNoticeDismissalPolicy.shouldDismiss(
                current: firstNotice,
                scheduledNoticeID: firstNotice.id
            ),
            "the scheduled notice should be dismissible"
        )
        assertEqual(
            HomeLocalSummaryNoticeDismissalPolicy.noticeAfterAutoDismiss(
                current: firstNotice,
                scheduledNoticeID: firstNotice.id
            ),
            nil,
            "the scheduled notice should clear after its auto-dismiss delay"
        )
        assertFalse(
            HomeLocalSummaryNoticeDismissalPolicy.shouldDismiss(
                current: newerNotice,
                scheduledNoticeID: firstNotice.id
            ),
            "an old dismissal timer should not clear a newer summary notice"
        )
        assertEqual(
            HomeLocalSummaryNoticeDismissalPolicy.noticeAfterAutoDismiss(
                current: newerNotice,
                scheduledNoticeID: firstNotice.id
            ),
            newerNotice,
            "an old dismissal timer should leave a newer summary notice visible"
        )
    }

    runSuite("HomeLocalSummaryNotice keeps failed summaries visible with retry copy") {
        let notice = HomeLocalSummaryNotice(
            transcriptURL: URL(fileURLWithPath: "/tmp/failed.md"),
            meetingTitle: "Failed Setup",
            failureMessage: "model load failed:\nmissing model cache"
        )

        assertEqual(notice.title, "AI summary failed", "failure notice should be explicit")
        assertEqual(notice.status, "Needs retry", "failure notice should not look complete")
        assertEqual(notice.actionTitle, "Retry summary", "failure notice should offer retry")
        assertFalse(notice.shouldAutoDismiss, "failure notice should persist until the user acts")
        assertTrue(
            notice.detail.contains("model load failed: missing model cache"),
            "failure detail should collapse noisy line breaks into readable copy"
        )
        assertTrue(
            notice.detail.contains("Nothing was changed"),
            "failure detail should reassure the user that the transcript was not rewritten"
        )
    }
}

private func sampleHomeMeetingSummaryBetaItem(
    summaryPreview: RecentMeetingSummaryPreview?
) -> RecentMeetingItem {
    RecentMeetingItem(
        title: "Quick notes",
        date: Date(timeIntervalSinceReferenceDate: 10),
        startDate: nil,
        endDate: nil,
        transcriptURL: URL(fileURLWithPath: "/tmp/quick-notes.md"),
        audio: nil,
        speakerStatus: .ready,
        summaryPreview: summaryPreview
    )
}

private func sampleHomeMeetingSummaryBetaPreview() -> RecentMeetingSummaryPreview {
    RecentMeetingSummaryPreview(
        title: "Launch Pricing Review",
        summary: "Team discussed launch pricing.",
        sections: [
            RecentMeetingSummarySection(title: "Summary", text: "Team discussed launch pricing.")
        ],
        url: URL(fileURLWithPath: "/tmp/quick-notes.md")
    )
}
