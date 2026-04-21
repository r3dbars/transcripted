import Foundation

func testFeedbackIssueBuilder() {
    runSuite("FeedbackIssueBuilder builds a normal GitHub issue URL") {
        let url = FeedbackIssueBuilder.issueURL(rawLogLines: [
            "[12:00:00.000] APP LAUNCHED | modes: dictation + meetings",
            "[12:01:00.000] ERROR | wrote /Users/redbars/private.txt for person@example.com via https://example.com/log"
        ])

        assertNotNil(url, "feedback issue URL should be created")
        assertTrue(url?.absoluteString.hasPrefix(FeedbackIssueBuilder.issueURLString) == true, "URL should target GitHub issues/new")
        assertTrue((url?.absoluteString.count ?? 0) <= FeedbackIssueBuilder.maxIssueURLCharacterCount, "normal URL should stay under the cap")

        let body = feedbackBody(from: url)
        assertTrue(body.contains("What happened:"), "issue body should include the feedback prompt")
        assertTrue(body.contains("APP LAUNCHED"), "short logs should remain in the issue body")
        assertFalse(body.contains("/Users/redbars/"), "paths should be redacted before the URL is built")
        assertFalse(body.contains("person@example.com"), "emails should be redacted before the URL is built")
        assertFalse(body.contains("https://example.com/log"), "URLs should be redacted before the URL is built")
    }

    runSuite("FeedbackIssueBuilder trims huge logs before GitHub rejects the URL") {
        let longLines = (0..<140).map { index in
            "[15:11:\(String(format: "%02d", index)).000] DIAG | capture.right_option_pressed | marker_\(index) \(String(repeating: "extra diagnostic context ", count: 8))"
        }
        let url = FeedbackIssueBuilder.issueURL(rawLogLines: longLines)

        assertNotNil(url, "feedback issue URL should still be created for huge logs")
        assertTrue((url?.absoluteString.count ?? 0) <= FeedbackIssueBuilder.maxIssueURLCharacterCount, "huge log URL should be capped")

        let body = feedbackBody(from: url)
        assertTrue(body.contains("Older logs omitted"), "trimmed issue body should explain why older logs are missing")
        assertTrue(body.contains("marker_139"), "newest useful log lines should be kept")
        assertFalse(body.contains("marker_0"), "oldest logs should be omitted")
    }

    runSuite("FeedbackIssueBuilder keeps only the latest in-app log window") {
        let lines = (0..<100).map { "[14:00:\($0)] marker_\($0)" }
        let url = FeedbackIssueBuilder.issueURL(rawLogLines: lines)
        let body = feedbackBody(from: url)

        assertFalse(body.contains("marker_0"), "logs older than the latest 80 entries should not be included")
        assertTrue(body.contains("marker_99"), "latest log entry should be included")
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
