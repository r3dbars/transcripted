import Foundation

// MARK: - Transcript Context Types

struct AgentTranscript: Codable {
    let version: String
    let recording: AgentRecording
    let speakers: [AgentSpeaker]
    let utterances: [AgentUtterance]
}

struct AgentRecording: Codable {
    let date: String
    let durationSeconds: Int
    let droppedSegments: Int
    let engines: AgentEngines

    enum CodingKeys: String, CodingKey {
        case date
        case durationSeconds = "duration_seconds"
        case droppedSegments = "dropped_segments"
        case engines
    }
}

struct AgentEngines: Codable {
    let stt: String
    let diarization: String
}

struct AgentSpeaker: Codable {
    let id: String
    let persistentSpeakerId: String?
    let name: String
    let confidence: String?
    let wordCount: Int
    let speakingSeconds: Double

    enum CodingKeys: String, CodingKey {
        case id
        case persistentSpeakerId = "persistent_speaker_id"
        case name
        case confidence
        case wordCount = "word_count"
        case speakingSeconds = "speaking_seconds"
    }
}

struct AgentUtterance: Codable {
    let start: Double
    let end: Double
    let speakerId: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case start, end
        case speakerId = "speaker_id"
        case text
    }
}

struct AgentDictationDay: Codable {
    let version: String
    let captureType: String
    let date: String
    let markdownFilename: String
    let entryCount: Int
    let wordCount: Int
    let entries: [AgentDictationEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case captureType = "capture_type"
        case date
        case markdownFilename = "markdown_filename"
        case entryCount = "entry_count"
        case wordCount = "word_count"
        case entries
    }
}

struct AgentDictationEntry: Codable {
    let id: String
    let createdAt: String
    let title: String
    let text: String
    let sourceAppName: String
    let sourceAppBundleId: String?
    let delivery: String
    let wordCount: Int
    let characterCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case title
        case text
        case sourceAppName = "source_app_name"
        case sourceAppBundleId = "source_app_bundle_id"
        case delivery
        case wordCount = "word_count"
        case characterCount = "character_count"
    }
}

// MARK: - MCP Response Types

struct GroupedSearchResult: Codable {
    var results: [MeetingSearchGroup]
    let totalMeetingsMatched: Int
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case results
        case totalMeetingsMatched = "total_meetings_matched"
        case truncated
    }
}

struct MeetingSearchGroup: Codable {
    var meetingTitle: String
    let meetingDate: String
    let meetingDateTime: String
    let filename: String
    let snippets: [SearchSnippet]

    enum CodingKeys: String, CodingKey {
        case meetingTitle = "meeting_title"
        case meetingDate = "meeting_date"
        case meetingDateTime = "meeting_datetime"
        case filename
        case snippets
    }
}

struct SearchSnippet: Codable {
    let speaker: String
    let speakerId: String?
    let timestamp: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case speaker
        case speakerId = "speaker_id"
        case timestamp
        case text
    }
}

struct SpeakerHistoryResult: Codable {
    let queriedName: String
    let matchedName: String
    let persistentSpeakerId: String?
    let meetingCount: Int
    let totalWordCount: Int
    let totalSpeakingSeconds: Double
    let meetings: [SpeakerMeeting]

    enum CodingKeys: String, CodingKey {
        case queriedName = "queried_name"
        case matchedName = "matched_name"
        case persistentSpeakerId = "persistent_speaker_id"
        case meetingCount = "meeting_count"
        case totalWordCount = "total_word_count"
        case totalSpeakingSeconds = "total_speaking_seconds"
        case meetings
    }
}

struct SpeakerMeeting: Codable {
    let filename: String
    let speakerName: String
    let persistentSpeakerId: String?
    let wordCount: Int
    let speakingSeconds: Double
    let meetingDate: String
    let meetingDurationSeconds: Int
    let meetingSpeakerCount: Int
    let previewSnippet: String

    enum CodingKeys: String, CodingKey {
        case filename
        case speakerName = "speaker_name"
        case persistentSpeakerId = "persistent_speaker_id"
        case wordCount = "word_count"
        case speakingSeconds = "speaking_seconds"
        case meetingDate = "meeting_date"
        case meetingDurationSeconds = "meeting_duration_seconds"
        case meetingSpeakerCount = "meeting_speaker_count"
        case previewSnippet = "preview_snippet"
    }
}

struct MeetingSummary: Codable {
    let filename: String
    let date: String
    let datetime: String
    let durationSeconds: Int
    let speakerCount: Int
    let wordCount: Int
    var speakers: [MeetingSpeaker]
    var title: String?

    enum CodingKeys: String, CodingKey {
        case filename, date, datetime, title
        case durationSeconds = "duration_seconds"
        case speakerCount = "speaker_count"
        case wordCount = "word_count"
        case speakers
    }
}

struct MeetingSpeaker: Codable {
    let name: String
    let persistentSpeakerId: String?
    let wordCount: Int
    let speakingSeconds: Double

    enum CodingKeys: String, CodingKey {
        case name
        case persistentSpeakerId = "persistent_speaker_id"
        case wordCount = "word_count"
        case speakingSeconds = "speaking_seconds"
    }
}

enum ContextKind: String, Codable {
    case meeting
    case dictation
    case all
}

struct DictationDaySummary: Codable {
    let filename: String
    let date: String
    let datetime: String
    let entryCount: Int
    let wordCount: Int
    let sourceApps: [String]
    let titles: [String]

    enum CodingKeys: String, CodingKey {
        case filename, date, datetime, titles
        case entryCount = "entry_count"
        case wordCount = "word_count"
        case sourceApps = "source_apps"
    }
}

struct ContextSearchResult: Codable {
    var results: [ContextSearchGroup]
    let totalItemsMatched: Int
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case results
        case totalItemsMatched = "total_items_matched"
        case truncated
    }
}

struct ContextSearchGroup: Codable {
    let kind: ContextKind
    var title: String
    let filename: String
    let entryId: String?
    let date: String
    let datetime: String
    let snippets: [ContextSearchSnippet]

    enum CodingKeys: String, CodingKey {
        case kind, title, filename, date, datetime, snippets
        case entryId = "entry_id"
    }
}

struct ContextSearchSnippet: Codable {
    let text: String
    let speaker: String?
    let speakerId: String?
    let timestamp: String?
    let sourceAppName: String?
    let delivery: String?

    enum CodingKeys: String, CodingKey {
        case text, speaker, timestamp, delivery
        case speakerId = "speaker_id"
        case sourceAppName = "source_app_name"
    }
}

struct RecentContextResult: Codable {
    var items: [RecentContextItem]
}

struct RecentContextItem: Codable {
    let kind: ContextKind
    var title: String
    let filename: String
    let entryId: String?
    let date: String
    let datetime: String
    let preview: String
    let wordCount: Int
    let speakers: [String]?
    let sourceAppName: String?
    let delivery: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, filename, date, datetime, preview, speakers, delivery
        case entryId = "entry_id"
        case wordCount = "word_count"
        case sourceAppName = "source_app_name"
    }
}

// MARK: - Person Profile

struct PersonProfile: Codable {
    let name: String
    let persistentSpeakerId: String?
    let meetingCount: Int
    let totalWordCount: Int
    let totalSpeakingMinutes: Double
    let firstSeen: String
    let lastSeen: String
    let frequentCoSpeakers: [String]
    let recentMeetings: [PersonMeetingEntry]
    let representativeQuotes: [String]
}

struct PersonMeetingEntry: Codable {
    let filename: String
    let date: String
    let wordCount: Int
    let speakingMinutes: Double
    let otherSpeakers: [String]
}

// MARK: - Summary-Fact Rollups (cross-meeting tools)

/// Open/done/all filter for `list_action_items`.
/// Current saved meeting summaries do not carry done/due metadata; done is
/// accepted as a forward-compatible filter but returns no derived rows today.
enum ActionItemStatusFilter: String {
    case open
    case done
    case all

    init(raw: String?) {
        switch raw?.lowercased() {
        case "done", "closed", "completed": self = .done
        case "all", "any": self = .all
        default: self = .open
        }
    }
}

struct ActionItemRecord: Codable {
    let filename: String
    var meetingTitle: String
    let date: String
    let datetime: String
    let text: String
    let owner: String?
    let status: String?
    let due: String?

    enum CodingKeys: String, CodingKey {
        case filename, date, datetime, text, owner, status, due
        case meetingTitle = "meeting_title"
    }
}

struct ActionItemsResult: Codable {
    let owner: String?
    let status: String
    let count: Int
    let truncated: Bool
    var items: [ActionItemRecord]
}

struct DecisionRecord: Codable {
    let filename: String
    var meetingTitle: String
    let date: String
    let datetime: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case filename, date, datetime, text
        case meetingTitle = "meeting_title"
    }
}

struct DecisionsResult: Codable {
    let count: Int
    let truncated: Bool
    var decisions: [DecisionRecord]
}

struct DigestActionItem: Codable {
    let text: String
    let owner: String?
    let status: String?
    let due: String?
}

struct DigestMeeting: Codable {
    let filename: String
    var title: String
    let date: String
    let datetime: String
    let decisions: [String]
    let actionItems: [DigestActionItem]
    let openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case filename, title, date, datetime, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }
}

struct DigestResult: Codable {
    let dateRange: String
    let meetingCount: Int
    let actionItemCount: Int
    let openActionItemCount: Int
    let decisionCount: Int
    let openQuestionCount: Int
    var meetings: [DigestMeeting]

    enum CodingKeys: String, CodingKey {
        case dateRange = "date_range"
        case meetingCount = "meeting_count"
        case actionItemCount = "action_item_count"
        case openActionItemCount = "open_action_item_count"
        case decisionCount = "decision_count"
        case openQuestionCount = "open_question_count"
        case meetings
    }
}

// MARK: - WS2.3 Cross-Meeting Retrieval

struct CrossMeetingReceipt: Codable {
    let meetingId: String
    var meetingTitle: String
    let timestamp: String?
    let quote: String
    let date: String
    let datetime: String
    let kind: String?
    let person: String?
}

struct CrossMeetingToolResult: Codable {
    let query: String?
    let range: String?
    let count: Int
    let truncated: Bool
    var results: [CrossMeetingReceipt]
}

// MARK: - Errors

enum MCPIndexError: Error, LocalizedError {
    case databaseOpenFailed(String)
    case databaseCorrupt
    case queryFailed(String)
    case fileNotReadable(String)

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let msg): return "Failed to open index database: \(msg)"
        case .databaseCorrupt: return "Index database is corrupt and will be rebuilt"
        case .queryFailed(let msg): return "Query failed: \(msg)"
        case .fileNotReadable(let path): return "Cannot read file: \(path)"
        }
    }
}
