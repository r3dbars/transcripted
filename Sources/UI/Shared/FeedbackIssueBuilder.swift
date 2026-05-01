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
    static let issueURLString = "https://github.com/r3dbars/transcripted/issues/new"
    static let maxIssueURLCharacterCount = 6_000

    private static let title = "Transcripted Feedback"
    private static let maxLogLines = 80
    private static let maxUserNotesCharacters = 1_500
    private static let omittedLogsNotice = "[Older logs omitted because GitHub rejects very long feedback URLs.]"
    private static let noLogsMessage = "No in-app logs attached."

    static func issueURL(rawLogLines: [String]?) -> URL? {
        let rawLogs = rawLogLines?.suffix(maxLogLines).joined(separator: "\n") ?? noLogsMessage
        let sanitizedLogs = AnalyticsPayloadSanitizer.redact(rawLogs)
        return issueURL(sanitizedLogs: sanitizedLogs.isEmpty ? noLogsMessage : sanitizedLogs)
    }

    static func issueURL(report: FeedbackReport, rawLogLines: [String]?) -> URL? {
        let rawLogs = report.includeDiagnostics
            ? rawLogLines?.suffix(maxLogLines).joined(separator: "\n") ?? noLogsMessage
            : "User chose not to attach diagnostics."
        let sanitizedLogs = AnalyticsPayloadSanitizer.redact(rawLogs)
        return issueURL(report: report, sanitizedLogs: sanitizedLogs.isEmpty ? noLogsMessage : sanitizedLogs)
    }

    static func issueURL(sanitizedLogs: String) -> URL? {
        if let url = uncappedIssueURL(sanitizedLogs: sanitizedLogs),
           url.absoluteString.count <= maxIssueURLCharacterCount {
            return url
        }

        return uncappedIssueURL(sanitizedLogs: fittingTrimmedLogs(from: sanitizedLogs))
    }

    private static func issueURL(report: FeedbackReport, sanitizedLogs: String) -> URL? {
        let reportTitle = "Transcripted \(report.sourceKind.capitalized) Feedback"
        let notes = sanitizedNotes(report.userNotes)
        let body = contextualBody(report: report, notes: notes, logs: sanitizedLogs)
        if let url = uncappedIssueURL(title: reportTitle, body: body),
           url.absoluteString.count <= maxIssueURLCharacterCount {
            return url
        }

        let trimmedLogs = fittingTrimmedLogs(from: sanitizedLogs, title: reportTitle, body: body)
        return uncappedIssueURL(
            title: reportTitle,
            body: contextualBody(report: report, notes: notes, logs: trimmedLogs)
        )
    }

    private static func fittingTrimmedLogs(from sanitizedLogs: String) -> String {
        fittingTrimmedLogs(from: sanitizedLogs, title: title, body: body(logs: sanitizedLogs))
    }

    private static func fittingTrimmedLogs(from sanitizedLogs: String, title: String, body: String) -> String {
        var lowerBound = 0
        var upperBound = sanitizedLogs.count
        var best = omittedLogsNotice

        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let candidate = trimmedLogs(from: sanitizedLogs, maxTailCharacters: middle)

            let candidateBody = body.replacingOccurrences(of: sanitizedLogs, with: candidate)
            guard let url = uncappedIssueURL(title: title, body: candidateBody) else {
                upperBound = middle - 1
                continue
            }

            if url.absoluteString.count <= maxIssueURLCharacterCount {
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

    private static func uncappedIssueURL(sanitizedLogs: String) -> URL? {
        uncappedIssueURL(title: title, body: body(logs: sanitizedLogs))
    }

    private static func uncappedIssueURL(title: String, body: String) -> URL? {
        var components = URLComponents(string: issueURLString)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        return components?.url
    }

    private static func sanitizedNotes(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "[No notes provided.]" }
        let sanitized = AnalyticsPayloadSanitizer.redact(trimmed)
        guard sanitized.count > maxUserNotesCharacters else { return sanitized }
        return "\(sanitized.prefix(maxUserNotesCharacters))\n[Feedback text truncated for URL length.]"
    }

    private static func body(logs: String) -> String {
        """
        What happened:
        [describe the issue here]

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
