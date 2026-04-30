import Foundation

enum FeedbackIssueBuilder {
    static let issueURLString = "https://github.com/r3dbars/transcripted/issues/new"
    static let maxIssueURLCharacterCount = 6_000

    private static let title = "Transcripted Feedback"
    private static let maxLogLines = 80
    private static let maxDiagnosticsCharacters = 2_500
    private static let omittedLogsNotice = "[Older logs omitted because GitHub rejects very long feedback URLs.]"
    private static let omittedDiagnosticsNotice = "[Older diagnostics omitted because GitHub rejects very long feedback URLs.]"
    private static let noLogsMessage = "No in-app logs attached."

    static func issueURL(rawLogLines: [String]?, diagnostics: String? = nil) -> URL? {
        let rawLogs = rawLogLines?.suffix(maxLogLines).joined(separator: "\n") ?? noLogsMessage
        let sanitizedLogs = AnalyticsPayloadSanitizer.redact(rawLogs)
        let sanitizedDiagnostics = diagnostics.map { fittingDiagnostics(from: AnalyticsPayloadSanitizer.redact($0)) }
        return issueURL(
            sanitizedLogs: sanitizedLogs.isEmpty ? noLogsMessage : sanitizedLogs,
            diagnostics: sanitizedDiagnostics
        )
    }

    static func issueURL(sanitizedLogs: String, diagnostics: String? = nil) -> URL? {
        if let url = uncappedIssueURL(sanitizedLogs: sanitizedLogs, diagnostics: diagnostics),
           url.absoluteString.count <= maxIssueURLCharacterCount {
            return url
        }

        return uncappedIssueURL(
            sanitizedLogs: fittingTrimmedLogs(from: sanitizedLogs, diagnostics: diagnostics),
            diagnostics: diagnostics
        )
    }

    private static func fittingTrimmedLogs(from sanitizedLogs: String, diagnostics: String?) -> String {
        var lowerBound = 0
        var upperBound = sanitizedLogs.count
        var best = omittedLogsNotice

        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let candidate = trimmedLogs(from: sanitizedLogs, maxTailCharacters: middle)

            guard let url = uncappedIssueURL(sanitizedLogs: candidate, diagnostics: diagnostics) else {
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

    private static func fittingDiagnostics(from diagnostics: String) -> String {
        guard diagnostics.count > maxDiagnosticsCharacters else { return diagnostics }
        var tail = String(diagnostics.suffix(maxDiagnosticsCharacters))
        if let firstNewline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: firstNewline)...])
        }
        return "\(omittedDiagnosticsNotice)\n\(tail)"
    }

    private static func uncappedIssueURL(sanitizedLogs: String, diagnostics: String?) -> URL? {
        var components = URLComponents(string: issueURLString)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body(logs: sanitizedLogs, diagnostics: diagnostics))
        ]
        return components?.url
    }

    private static func body(logs: String, diagnostics: String?) -> String {
        let diagnosticsText: String
        if let diagnostics, !diagnostics.isEmpty {
            diagnosticsText = diagnostics
        } else {
            diagnosticsText = "No diagnostics attached."
        }
        return """
        What happened:
        [describe the issue here]

        ---
        Diagnostics:
        \(diagnosticsText)

        ---
        Logs:
        \(logs)
        """
    }
}
