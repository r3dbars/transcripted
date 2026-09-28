import Foundation

struct FeedbackReport {
    let sourceKind: String
    let referenceID: String
    let occurredAt: Date
    let issueKind: String
    let userNotes: String
    let appVersion: String
    let includeDiagnostics: Bool
}

enum FeedbackIssueBuilder {
    static let supportEmailAddress = "help@transcripted.app"
    static let emailURLString = "mailto:\(supportEmailAddress)"
    static let maxEmailURLCharacterCount = 6_000

    private static let title = "Transcripted Feedback"
    private static let maxLogLines = 80
    private static let maxUserNotesCharacters = 1_500
    private static let maxDiagnosticsCharacters = 2_500
    private static let omittedLogsNotice = "[Older logs omitted because the feedback email got too long.]"
    private static let omittedDiagnosticsNotice = "[Older diagnostics omitted because the feedback email got too long.]"
    private static let noLogsMessage = "No in-app logs attached."

    /// `diagnosticReportID` is the ID of a diagnostic event the user sent
    /// with Send Diagnostics, so support can match the email to it. It is
    /// added only when it looks like an event ID (hex and dashes).
    static func emailURL(
        rawLogLines: [String]?,
        diagnostics: String? = nil,
        diagnosticReportID: String? = nil
    ) -> URL? {
        let rawLogs = rawLogLines?.suffix(maxLogLines).joined(separator: "\n") ?? noLogsMessage
        let sanitizedLogs = AnalyticsPayloadSanitizer.redact(rawLogs)
        let sanitizedDiagnostics = diagnostics.map { fittingDiagnostics(from: AnalyticsPayloadSanitizer.redact($0)) }
        return emailURL(
            sanitizedLogs: sanitizedLogs.isEmpty ? noLogsMessage : sanitizedLogs,
            diagnostics: sanitizedDiagnostics,
            diagnosticReportID: diagnosticReportID
        )
    }

    static func safeDiagnosticReportID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) })
        else { return nil }
        return trimmed
    }

    static func emailURL(report: FeedbackReport, rawLogLines: [String]?) -> URL? {
        let rawLogs = report.includeDiagnostics
            ? rawLogLines?.suffix(maxLogLines).joined(separator: "\n") ?? noLogsMessage
            : "User chose not to attach diagnostics."
        let sanitizedLogs = AnalyticsPayloadSanitizer.redact(rawLogs)
        return emailURL(
            report: report,
            sanitizedLogs: sanitizedLogs.isEmpty ? noLogsMessage : sanitizedLogs
        )
    }

    static func emailURL(
        sanitizedLogs: String,
        diagnostics: String? = nil,
        diagnosticReportID: String? = nil
    ) -> URL? {
        let reportID = safeDiagnosticReportID(diagnosticReportID)
        return cappedEmailURL(subject: title, sanitizedLogs: sanitizedLogs) { logs in
            body(logs: logs, diagnostics: diagnostics, diagnosticReportID: reportID)
        }
    }

    private static func emailURL(report: FeedbackReport, sanitizedLogs: String) -> URL? {
        let reportTitle = "Transcripted \(report.sourceKind.capitalized) Feedback"
        let notes = sanitizedNotes(report.userNotes)
        return cappedEmailURL(subject: reportTitle, sanitizedLogs: sanitizedLogs) { logs in
            contextualBody(report: report, notes: notes, logs: logs)
        }
    }

    private static func cappedEmailURL(
        subject: String,
        sanitizedLogs: String,
        bodyForLogs: (String) -> String
    ) -> URL? {
        let uncappedBody = bodyForLogs(sanitizedLogs)
        if let url = uncappedEmailURL(subject: subject, body: uncappedBody),
           url.absoluteString.count <= maxEmailURLCharacterCount {
            return url
        }

        let trimmedLogs = fittingTrimmedLogs(
            from: sanitizedLogs,
            subject: subject,
            bodyForLogs: bodyForLogs
        )
        return uncappedEmailURL(subject: subject, body: bodyForLogs(trimmedLogs))
    }

    private static func fittingTrimmedLogs(
        from sanitizedLogs: String,
        subject: String,
        bodyForLogs: (String) -> String
    ) -> String {
        var lowerBound = 0
        var upperBound = sanitizedLogs.count
        var best = omittedLogsNotice

        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let candidate = trimmedLogs(from: sanitizedLogs, maxTailCharacters: middle)

            guard let url = uncappedEmailURL(subject: subject, body: bodyForLogs(candidate)) else {
                upperBound = middle - 1
                continue
            }

            if url.absoluteString.count <= maxEmailURLCharacterCount {
                best = candidate
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }

        return best
    }

    private static func trimmedLogs(from sanitizedLogs: String, maxTailCharacters: Int) -> String {
        guard maxTailCharacters > 0 else { return omittedLogsNotice }

        var tail = String(sanitizedLogs.suffix(maxTailCharacters))
        if tail.count < sanitizedLogs.count,
           let firstNewline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: firstNewline)...])
        }

        guard !tail.isEmpty else { return omittedLogsNotice }
        return "\(omittedLogsNotice)\n\(tail)"
    }

    private static func fittingDiagnostics(from diagnostics: String) -> String {
        guard diagnostics.count > maxDiagnosticsCharacters else { return diagnostics }
        var tail = String(diagnostics.suffix(maxDiagnosticsCharacters))
        if let firstNewline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: firstNewline)...])
        }
        return "\(omittedDiagnosticsNotice)\n\(tail)"
    }

    private static func uncappedEmailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    private static func sanitizedNotes(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "[No notes provided.]" }
        let sanitized = AnalyticsPayloadSanitizer.redact(trimmed)
        guard sanitized.count > maxUserNotesCharacters else { return sanitized }
        return "\(sanitized.prefix(maxUserNotesCharacters))\n[Feedback text truncated for URL length.]"
    }

    private static func body(logs: String, diagnostics: String?, diagnosticReportID: String?) -> String {
        let diagnosticsText: String
        if let diagnostics, !diagnostics.isEmpty {
            diagnosticsText = diagnostics
        } else {
            diagnosticsText = "No diagnostics attached."
        }
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
        \(logs)
        """
    }

    private static func contextualBody(report: FeedbackReport, notes: String, logs: String) -> String {
        """
        What went wrong:
        \(notes)

        ---
        Capture:
        Type: \(report.sourceKind)
        Issue: \(report.issueKind)
        Reference: \(report.referenceID)
        Created: \(feedbackDateFormatter.string(from: report.occurredAt))
        App: \(report.appVersion)

        ---
        Diagnostics:
        \(logs)
        """
    }

    private static let feedbackDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// What Settings says after Send Diagnostics.
enum SupportDiagnosticsStatusCopy {
    static func sent(eventID: String) -> String {
        "Sent. Next, click Email Support and tell us what happened. Your report ID (\(eventID.prefix(8))) goes along with the email so we can find it."
    }
}
