import Foundation

func testFeedbackIssueBuilder() {
    runSuite("FeedbackIssueBuilder addresses a normal support draft with a feedback prompt") {
        let url = FeedbackIssueBuilder.emailURL()
        assertNotNil(url, "a support draft URL should be created")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        assertEqual(components?.scheme, "mailto", "the draft should use mailto")
        assertEqual(components?.path, "help@transcripted.app", "the draft should target the public support address")
        assertEqual(feedbackSubject(from: url), "Transcripted Feedback", "the normal subject should remain unchanged")
        let body = feedbackBody(from: url)
        assertTrue(body.contains("What happened:"), "the draft should ask what happened")
        assertTrue(body.contains("[describe the issue here]\n\n---"), "the feedback placeholder and separator should remain unchanged")
        assertTrue(body.lowercased().contains("no in-app logs attached"), "the draft should explain that logs are not included")
        assertTrue((url?.absoluteString.count ?? Int.max) <= 6_000, "the encoded URL should fit the existing mailto limit")
    }

    runSuite("FeedbackIssueBuilder sanitizes optional diagnostics and retains coarse safe values") {
        let syntheticToken = "sk-" + "synthetic-feedback-secret-1234567890"
        let url = FeedbackIssueBuilder.emailURL(diagnostics: """
        meeting_state: idle
        route: bluetooth_input_to_built_in_output
        retries: 2
        private_path: /Users/synthetic-feedback/private.txt
        private_email: synthetic-feedback@example.com
        private_url: https://example.invalid/synthetic-feedback?secret=private
        private_token: \(syntheticToken)
        """)
        assertNotNil(url, "sanitized diagnostics should still produce a draft")
        let body = feedbackBody(from: url)
        assertTrue(body.contains("Diagnostics:"), "attached diagnostics should have a section label")
        assertTrue(body.contains("meeting_state: idle"), "coarse state should remain useful")
        assertTrue(body.contains("bluetooth_input_to_built_in_output"), "coarse route shape should remain useful")
        assertTrue(body.contains("retries: 2"), "coarse numeric values should remain useful")
        assertFalse(body.contains("/Users/synthetic-feedback/private.txt"), "private paths should be removed")
        assertFalse(body.contains("synthetic-feedback@example.com"), "private email addresses should be removed")
        assertFalse(body.contains("https://example.invalid/synthetic-feedback"), "private URLs should be removed")
        assertFalse(body.contains(syntheticToken), "private tokens should be removed")
        assertTrue(body.lowercased().contains("no in-app logs attached"), "adding diagnostics should not imply logs were attached")
    }

    runSuite("FeedbackIssueBuilder carries a report ID without changing the normal draft layout") {
        let reportID = "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6"
        let withID = feedbackBody(from: FeedbackIssueBuilder.emailURL(
            diagnostics: "meeting_state: idle",
            diagnosticReportID: " \(reportID)\n"
        ))
        assertTrue(withID.contains("Diagnostic report ID: \(reportID)"), "a valid trimmed report ID should be carried in full")
        let withoutID = feedbackBody(from: FeedbackIssueBuilder.emailURL(diagnostics: "meeting_state: idle"))
        assertFalse(withoutID.contains("Diagnostic report ID"), "a draft with no report should not invent an ID")
        assertTrue(withoutID.contains("[describe the issue here]\n\n---"), "omitting the report ID should preserve the draft layout")
    }

    runSuite("FeedbackIssueBuilder rejects unsafe report IDs and enforces the 64 character boundary") {
        let validID = String(repeating: "a1", count: 32)
        assertEqual(FeedbackIssueBuilder.safeDiagnosticReportID(validID), validID, "64 safe characters should be accepted")
        assertEqual(FeedbackIssueBuilder.safeDiagnosticReportID(" \(validID)\n"), validID, "surrounding whitespace should be trimmed")
        for invalid in ["", " \n", "person@example.com", "https://example.invalid/id", "a b", String(repeating: "a", count: 65)] {
            assertNil(FeedbackIssueBuilder.safeDiagnosticReportID(invalid), "invalid or overlong report IDs should be rejected")
            let body = feedbackBody(from: FeedbackIssueBuilder.emailURL(diagnosticReportID: invalid))
            assertFalse(body.contains("Diagnostic report ID"), "invalid report IDs should not enter the support draft")
        }
    }

    runSuite("FeedbackIssueBuilder bounds encoded ASCII diagnostics and preserves the newest line and report ID") {
        let reportID = "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6"
        let oldMarker = "oldest_ascii_diagnostic_marker"
        let newestMarker = "newest_ascii_diagnostic_marker"
        let diagnostics = oldMarker + "\n" + String(repeating: "coarse_state: idle count: 2\n", count: 600) + newestMarker
        let url = FeedbackIssueBuilder.emailURL(diagnostics: diagnostics, diagnosticReportID: reportID)
        assertNotNil(url, "oversized ASCII diagnostics should still produce a draft")
        assertTrue((url?.absoluteString.count ?? Int.max) <= 6_000, "the actual percent-encoded URL should fit the mailto cap")
        let body = feedbackBody(from: url)
        assertTrue(body.contains(newestMarker), "the newest diagnostic line should survive truncation")
        assertFalse(body.contains(oldMarker), "the oldest diagnostic line should be omitted first")
        assertTrue(body.lowercased().contains("diagnostics omitted"), "the draft should disclose omitted diagnostics")
        assertTrue(body.contains("Diagnostic report ID: \(reportID)"), "truncation must not discard the report ID")
    }

    runSuite("FeedbackIssueBuilder budgets percent encoding for multibyte and emoji diagnostics") {
        let reportID = String(repeating: "b2", count: 32)
        let oldMarker = "oldest_unicode_diagnostic_marker"
        let newestMarker = "newest_unicode_diagnostic_marker"
        let diagnostics = oldMarker + "\n" + String(repeating: "coarse_state: 待機 🎙️🙂 count: 2\n", count: 600) + newestMarker
        let url = FeedbackIssueBuilder.emailURL(diagnostics: diagnostics, diagnosticReportID: reportID)
        assertNotNil(url, "oversized Unicode diagnostics should still produce a draft")
        assertTrue((url?.absoluteString.count ?? Int.max) <= 6_000, "Unicode must be budgeted after URL percent encoding")
        let body = feedbackBody(from: url)
        assertTrue(body.contains(newestMarker), "the newest Unicode diagnostic line should survive truncation")
        assertTrue(body.contains("待機 🎙️🙂"), "safe multibyte and emoji diagnostics should remain readable")
        assertFalse(body.contains(oldMarker), "the oldest Unicode diagnostic line should be omitted first")
        assertTrue(body.lowercased().contains("diagnostics omitted"), "Unicode truncation should be disclosed")
        assertTrue(body.contains("Diagnostic report ID: \(reportID)"), "the full report ID should survive Unicode truncation")
        assertFalse(body.contains("�"), "truncation should not introduce replacement characters")
    }

    runSuite("Send Diagnostics status gives a plain next step") {
        let status = SupportDiagnosticsStatusCopy.sent(eventID: "1a2b3c4d5e6f47a8")
        assertTrue(status.contains("Email Support"), "the status should point at the next step")
        assertTrue(status.contains("1a2b3c4d"), "the status should show the short report ID")
        assertFalse(status.contains("5e6f47a8"), "the status should only show the short form of the ID")
    }
}

private func feedbackBody(from url: URL?) -> String {
    guard let url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let body = components.queryItems?.first(where: { $0.name == "body" })?.value else {
        return ""
    }

    return body
}

private func feedbackSubject(from url: URL?) -> String {
    guard let url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let subject = components.queryItems?.first(where: { $0.name == "subject" })?.value else {
        return ""
    }

    return subject
}
