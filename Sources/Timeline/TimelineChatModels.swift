import Foundation

struct TimelineChatRange: Equatable {
    var start: Date
    var end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

struct TimelineChatCard: Equatable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var kind: String
    var title: String
    var summary: String
    var detailedSummary: String?
    var category: String
    var captureID: String?

    init(
        id: String,
        start: Date,
        end: Date,
        kind: String,
        title: String,
        summary: String,
        detailedSummary: String? = nil,
        category: String,
        captureID: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.title = title
        self.summary = summary
        self.detailedSummary = detailedSummary
        self.category = category
        self.captureID = captureID
    }
}

struct TimelineChatObservation: Equatable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var text: String

    init(id: String, start: Date, end: Date, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

struct TimelineChatSQLResult: Equatable {
    var columns: [String]
    var rows: [[String]]

    init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

protocol TimelineChatQuerying {
    func fetchTimeline(range: TimelineChatRange) throws -> [TimelineChatCard]
    func fetchObservations(range: TimelineChatRange) throws -> [TimelineChatObservation]
    func fetchMeeting(captureID: String) throws -> String
    func runReadOnlySQL(_ sql: String) throws -> TimelineChatSQLResult
}

enum TimelineChatToolName: String, Equatable {
    case fetchTimeline = "fetch_timeline"
    case fetchObservations = "fetch_observations"
    case fetchMeeting = "fetch_meeting"
    case readOnlySQL = "read_only_sql"
}

struct TimelineChatToolRequest: Equatable {
    var name: TimelineChatToolName
    var range: TimelineChatRange?
    var captureID: String?
    var sql: String?

    init(
        name: TimelineChatToolName,
        range: TimelineChatRange? = nil,
        captureID: String? = nil,
        sql: String? = nil
    ) {
        self.name = name
        self.range = range
        self.captureID = captureID
        self.sql = sql
    }
}

enum TimelineChatToolResult: Equatable {
    case timeline([TimelineChatCard])
    case observations([TimelineChatObservation])
    case meetingMarkdown(String)
    case sql(TimelineChatSQLResult)
}

enum TimelineChatPrivacyMode: Equatable {
    case localOnly
    case cloudProvider(name: String, noticeAccepted: Bool)
}

struct TimelineChatPromptContext: Equatable {
    var question: String
    var range: TimelineChatRange
    var cards: [TimelineChatCard]
    var observations: [TimelineChatObservation]
    var meetingMarkdownByCaptureID: [String: String]
    var privacyMode: TimelineChatPrivacyMode

    init(
        question: String,
        range: TimelineChatRange,
        cards: [TimelineChatCard],
        observations: [TimelineChatObservation] = [],
        meetingMarkdownByCaptureID: [String: String] = [:],
        privacyMode: TimelineChatPrivacyMode = .localOnly
    ) {
        self.question = question
        self.range = range
        self.cards = cards
        self.observations = observations
        self.meetingMarkdownByCaptureID = meetingMarkdownByCaptureID
        self.privacyMode = privacyMode
    }
}

struct TimelineChatMessage: Equatable, Identifiable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    var id: UUID
    var role: Role
    var content: String
    var createdAt: Date

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

