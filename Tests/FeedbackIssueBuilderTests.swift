import Foundation

func testFeedbackIssueBuilder() {
    runSuite("FeedbackIssueBuilder builds a normal support email URL") {
        let url = FeedbackIssueBuilder.emailURL(rawLogLines: [
            "[12:00:00.000] APP LAUNCHED | modes: dictation + meetings",
            "[12:01:00.000] ERROR | wrote /Users/redbars/private.txt for person@example.com via https://example.com/log"
        ])

        assertNotNil(url, "feedback email URL should be created")
        assertTrue(url?.absoluteString.hasPrefix(FeedbackIssueBuilder.emailURLString) == true, "URL should target the support email address")
        assertTrue((url?.absoluteString.count ?? 0) <= FeedbackIssueBuilder.maxEmailURLCharacterCount, "normal URL should stay under the cap")

        let body = feedbackBody(from: url)
        let subject = feedbackSubject(from: url)
        assertEqual(subject, "Transcripted Feedback", "email subject should be set")
        assertTrue(body.contains("What happened:"), "email body should include the feedback prompt")
        assertTrue(body.contains("Diagnostics:"), "email body should include a diagnostics section")
        assertTrue(body.contains("APP LAUNCHED"), "short logs should remain in the email body")
        assertFalse(body.contains("/Users/redbars/"), "paths should be redacted before the URL is built")
        assertFalse(body.contains("person@example.com"), "emails should be redacted before the URL is built")
        assertFalse(body.contains("https://example.com/log"), "URLs should be redacted before the URL is built")
    }

    runSuite("FeedbackIssueBuilder trims huge logs before the feedback email gets too long") {
        let longLines = (0..<140).map { index in
            "[15:11:\(String(format: "%02d", index)).000] DIAG | capture.right_option_pressed | marker_\(index) \(String(repeating: "extra diagnostic context ", count: 8))"
        }
        let url = FeedbackIssueBuilder.emailURL(rawLogLines: longLines)

        assertNotNil(url, "feedback email URL should still be created for huge logs")
        assertTrue((url?.absoluteString.count ?? 0) <= FeedbackIssueBuilder.maxEmailURLCharacterCount, "huge log URL should be capped")

        let body = feedbackBody(from: url)
        assertTrue(body.contains("Older logs omitted"), "trimmed email body should explain why older logs are missing")
        assertTrue(body.contains("marker_139"), "newest useful log lines should be kept")
        assertFalse(body.contains("marker_0"), "oldest logs should be omitted")
    }

    runSuite("FeedbackIssueBuilder keeps only the latest in-app log window") {
        let lines = (0..<100).map { "[14:00:\($0)] marker_\($0)" }
        let url = FeedbackIssueBuilder.emailURL(rawLogLines: lines)
        let body = feedbackBody(from: url)

        assertFalse(body.contains("marker_0"), "logs older than the latest 80 entries should not be included")
        assertTrue(body.contains("marker_99"), "latest log entry should be included")
    }

    runSuite("FeedbackIssueBuilder attaches sanitized diagnostics") {
        let url = FeedbackIssueBuilder.emailURL(
            rawLogLines: ["[14:00:00.000] APP LAUNCHED"],
            diagnostics: "Route bluetooth_input_to_built_in_output from /Users/redbars/private.txt for person@example.com"
        )
        let body = feedbackBody(from: url)

        assertTrue(body.contains("bluetooth_input_to_built_in_output"), "safe diagnostic route shape should be included")
        assertFalse(body.contains("/Users/redbars"), "diagnostic paths should be redacted")
        assertFalse(body.contains("person@example.com"), "diagnostic emails should be redacted")
    }

    runSuite("FeedbackIssueBuilder builds contextual capture feedback email") {
        let report = FeedbackReport(
            sourceKind: "dictation",
            referenceID: "abc123",
            occurredAt: Date(timeIntervalSince1970: 1_714_000_000),
            issueKind: "Wrong words",
            userNotes: "It included /Users/redbars/private.txt and person@example.com",
            appVersion: "Version 1.2.3",
            includeDiagnostics: true
        )
        let url = FeedbackIssueBuilder.emailURL(report: report, rawLogLines: [
            "[12:00:00.000] APP LAUNCHED",
            "[12:01:00.000] ERROR | https://example.com/log"
        ])
        let body = feedbackBody(from: url)
        let subject = feedbackSubject(from: url)

        assertEqual(subject, "Transcripted Dictation Feedback", "contextual email subject should include the capture type")
        assertTrue(body.contains("Capture:"), "contextual email should include capture metadata")
        assertTrue(body.contains("Type: dictation"), "source kind should be included")
        assertTrue(body.contains("Issue: Wrong words"), "issue kind should be included")
        assertTrue(body.contains("Reference: abc123"), "safe reference should be included")
        assertFalse(body.contains("/Users/redbars/"), "user notes should be scrubbed")
        assertFalse(body.contains("person@example.com"), "emails in user notes should be scrubbed")
        assertFalse(body.contains("https://example.com/log"), "diagnostic URLs should be scrubbed")
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
