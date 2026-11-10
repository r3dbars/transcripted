import Foundation

enum FeedbackIssueBuilder {
    static let supportEmailAddress = "help@transcripted.app"
    static let emailURLString = "mailto:\(supportEmailAddress)"
    static let maxEmailURLCharacterCount = 6_000

    private static let title = "Transcripted Feedback"
    private static let maxDiagnosticsCharacters = 2_500
    private static let omittedDiagnosticsNotice = "[Older diagnostics omitted because the feedback email got too long.]"
    private static let noLogsMessage = "No in-app logs attached."

    /// Includes the privacy-safe summary and, when valid, the event ID from
    /// Send Diagnostics. No in-app log buffer is attached.
    static func emailURL(
        diagnostics: String? = nil,
        diagnosticReportID: String? = nil
    ) -> URL? {
        let diagnostics = diagnostics.map { AnalyticsPayloadSanitizer.redact($0) }
        let reportID = safeDiagnosticReportID(diagnosticReportID)
        func makeURL(_ text: String?) -> URL? {
            uncappedEmailURL(body: body(diagnostics: text, diagnosticReportID: reportID))
        }
        let initial = diagnostics.map { diagnosticTail($0, maxCharacters: maxDiagnosticsCharacters) }
        if let url = makeURL(initial), url.absoluteString.count <= maxEmailURLCharacterCount {
            return url
        }

        // URL encoding can expand Unicode far beyond its character count.
        // Fit the diagnostics themselves; the report ID and fixed copy stay intact.
        guard let diagnostics, !diagnostics.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = min(maxDiagnosticsCharacters, diagnostics.count - 1)
        var best: URL?
        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let candidate = makeURL(diagnosticTail(diagnostics, maxCharacters: middle))
            if let candidate, candidate.absoluteString.count <= maxEmailURLCharacterCount {
                best = candidate
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }
        return best
    }

    static func safeDiagnosticReportID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) })
        else { return nil }
        return trimmed
    }

    private static func diagnosticTail(_ diagnostics: String, maxCharacters: Int) -> String {
        guard diagnostics.count > maxCharacters else { return diagnostics }
        guard maxCharacters > 0 else { return omittedDiagnosticsNotice }
        var tail = String(diagnostics.suffix(maxCharacters))
        if let firstNewline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: firstNewline)...])
        }
        return tail.isEmpty ? omittedDiagnosticsNotice : "\(omittedDiagnosticsNotice)\n\(tail)"
    }

    private static func uncappedEmailURL(body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    private static func body(diagnostics: String?, diagnosticReportID: String?) -> String {
        let diagnosticsText = diagnostics.flatMap { $0.isEmpty ? nil : $0 } ?? "No diagnostics attached."
        let reportIDLine = diagnosticReportID.map { "\nDiagnostic report ID: \($0)\n" } ?? ""
        return """
        What happened:
        [describe the issue here]
        \(reportIDLine)
        ---
        Diagnostics:
        \(diagnosticsText)

        ---
        Logs:
        \(noLogsMessage)
        """
    }
}

/// What Settings says after Send Diagnostics.
enum SupportDiagnosticsStatusCopy {
    static func sent(eventID: String) -> String {
        "Sent. Next, click Email Support and tell us what happened. Your report ID (\(eventID.prefix(8))) goes along with the email so we can find it."
    }
}
