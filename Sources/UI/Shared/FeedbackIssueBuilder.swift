import Foundation

enum FeedbackIssueBuilder {
    static let issueURLString = "https://github.com/r3dbars/transcripted/issues/new"
    static let maxIssueURLCharacterCount = 6_000

    private static let title = "Transcripted Feedback"
    private static let maxLogLines = 80
    private static let omittedLogsNotice = "[Older logs omitted because GitHub rejects very long feedback URLs.]"
    private static let noLogsMessage = "No in-app logs attached."

    static func issueURL(rawLogLines: [String]?) -> URL? {
        let rawLogs = rawLogLines?.suffix(maxLogLines).joined(separator: "\n") ?? noLogsMessage
        let sanitizedLogs = AnalyticsPayloadSanitizer.redact(rawLogs)
        return issueURL(sanitizedLogs: sanitizedLogs.isEmpty ? noLogsMessage : sanitizedLogs)
    }

    static func issueURL(sanitizedLogs: String) -> URL? {
        if let url = uncappedIssueURL(sanitizedLogs: sanitizedLogs),
           url.absoluteString.count <= maxIssueURLCharacterCount {
            return url
        }

        return uncappedIssueURL(sanitizedLogs: fittingTrimmedLogs(from: sanitizedLogs))
    }

    private static func fittingTrimmedLogs(from sanitizedLogs: String) -> String {
        var lowerBound = 0
        var upperBound = sanitizedLogs.count
        var best = omittedLogsNotice

        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let candidate = trimmedLogs(from: sanitizedLogs, maxTailCharacters: middle)

            guard let url = uncappedIssueURL(sanitizedLogs: candidate) else {
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
        var components = URLComponents(string: issueURLString)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body(logs: sanitizedLogs))
        ]
        return components?.url
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
}
