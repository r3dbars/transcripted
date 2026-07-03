import Foundation

enum TimelineChatToolError: Error, Equatable, CustomStringConvertible {
    case missingRange(String)
    case missingCaptureID
    case missingSQL
    case rejectedSQL(String)

    var description: String {
        switch self {
        case .missingRange(let tool):
            return "\(tool) needs a time range."
        case .missingCaptureID:
            return "fetch_meeting needs a capture id."
        case .missingSQL:
            return "read_only_sql needs a SQL statement."
        case .rejectedSQL(let reason):
            return "SQL rejected: \(reason)"
        }
    }
}

struct ChatToolExecutor {
    private let query: TimelineChatQuerying

    init(query: TimelineChatQuerying) {
        self.query = query
    }

    func execute(_ request: TimelineChatToolRequest) throws -> TimelineChatToolResult {
        switch request.name {
        case .fetchTimeline:
            guard let range = request.range else {
                throw TimelineChatToolError.missingRange(request.name.rawValue)
            }
            return .timeline(try query.fetchTimeline(range: range))
        case .fetchObservations:
            guard let range = request.range else {
                throw TimelineChatToolError.missingRange(request.name.rawValue)
            }
            return .observations(try query.fetchObservations(range: range))
        case .fetchMeeting:
            guard let captureID = request.captureID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !captureID.isEmpty
            else {
                throw TimelineChatToolError.missingCaptureID
            }
            return .meetingMarkdown(try query.fetchMeeting(captureID: captureID))
        case .readOnlySQL:
            guard let sql = request.sql else {
                throw TimelineChatToolError.missingSQL
            }
            try Self.validateReadOnlySQL(sql)
            return .sql(try query.runReadOnlySQL(sql))
        }
    }

    static func validateReadOnlySQL(_ sql: String) throws {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TimelineChatToolError.rejectedSQL("empty statement")
        }

        guard trimmed.count <= 8_000 else {
            throw TimelineChatToolError.rejectedSQL("statement is too long")
        }

        let lower = trimmed.lowercased()
        guard lower.hasPrefix("select ") || lower == "select" || lower.hasPrefix("select\n") else {
            throw TimelineChatToolError.rejectedSQL("only SELECT statements are allowed")
        }

        if lower.contains("--") || lower.contains("/*") || lower.contains("*/") {
            throw TimelineChatToolError.rejectedSQL("comments are not allowed")
        }

        let semicolonCount = trimmed.filter { $0 == ";" }.count
        if semicolonCount > 1 || (semicolonCount == 1 && !trimmed.hasSuffix(";")) {
            throw TimelineChatToolError.rejectedSQL("multiple statements are not allowed")
        }

        let bannedWords = [
            "alter", "attach", "begin", "commit", "create", "delete", "detach", "drop",
            "insert", "pragma", "reindex", "replace", "rollback", "truncate", "update",
            "vacuum"
        ]
        let tokens = lower.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        for word in bannedWords where tokens.contains(Substring(word)) {
            throw TimelineChatToolError.rejectedSQL("\(word.uppercased()) is not allowed")
        }
    }
}

