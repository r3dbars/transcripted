import Foundation

// MARK: - JSON Sidecar Input Types (copied from AgentOutput.swift)

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

// MARK: - MCP Response Types

struct GroupedSearchResult: Codable {
    let results: [MeetingSearchGroup]
    let totalMeetingsMatched: Int
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case results
        case totalMeetingsMatched = "total_meetings_matched"
        case truncated
    }
}

struct MeetingSearchGroup: Codable {
    let meetingTitle: String
    let meetingDate: String
    let filename: String
    let snippets: [SearchSnippet]

    enum CodingKeys: String, CodingKey {
        case meetingTitle = "meeting_title"
        case meetingDate = "meeting_date"
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
