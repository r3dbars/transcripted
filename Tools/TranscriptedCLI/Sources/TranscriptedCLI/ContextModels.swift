import ArgumentParser
import Foundation
import TranscriptedCaptureKit

enum CLIContextKind: String, ExpressibleByArgument, Codable {
    case all
    case meeting
    case dictation
    case timeline
}

struct CLIAgentTranscript: Codable {
    let version: String
    let recording: CLIAgentRecording
    let speakers: [CLIActorSpeaker]
    let utterances: [CLIUtterance]
}

struct CLIAgentRecording: Codable {
    let date: String
    let durationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case date
        case durationSeconds = "duration_seconds"
    }
}

struct CLIActorSpeaker: Codable {
    let id: String
    let name: String
    let persistentSpeakerId: String?
    let wordCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case persistentSpeakerId = "persistent_speaker_id"
        case wordCount = "word_count"
    }
}

struct CLIUtterance: Codable {
    let start: Double
    let end: Double
    let speakerId: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case speakerId = "speaker_id"
    }
}

struct CLIAgentDictationDay: Codable {
    let version: String
    let captureType: String
    let date: String
    let markdownFilename: String
    let entryCount: Int
    let wordCount: Int
    let entries: [CLIClientDictationEntry]

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

struct CLIClientDictationEntry: Codable {
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
        case title, text, delivery
        case sourceAppName = "source_app_name"
        case sourceAppBundleId = "source_app_bundle_id"
        case wordCount = "word_count"
        case characterCount = "character_count"
    }
}

struct CLIContextItem: Codable {
    let kind: CLIContextKind
    let title: String
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

struct CLIDictationDaySummary: Codable {
    let filename: String
    let date: String
    let datetime: String
    let entryCount: Int
    let wordCount: Int
    let titles: [String]
    let sourceApps: [String]

    enum CodingKeys: String, CodingKey {
        case filename, date, datetime, titles
        case entryCount = "entry_count"
        case wordCount = "word_count"
        case sourceApps = "source_apps"
    }
}

struct CLITimelineDaySummary: Codable {
    let filename: String
    let date: String
    let cardCount: Int
    let activeMinutes: Int
    let categories: [String]

    enum CodingKeys: String, CodingKey {
        case filename, date, categories
        case cardCount = "card_count"
        case activeMinutes = "active_minutes"
    }
}

struct CLIAgentTimelineDay: Codable {
    let version: String
    let captureType: String
    let date: String
    let markdownFilename: String
    let cardCount: Int
    let activeMinutes: Int
    let categories: [String]
    let cards: [CLIAgentTimelineCard]

    init(_ parsed: ParsedTimelineDayCapture) {
        self.version = "\(parsed.formatVersion)"
        self.captureType = parsed.captureType
        self.date = parsed.date
        self.markdownFilename = parsed.markdownFilename
        self.cardCount = parsed.cardCount
        self.activeMinutes = parsed.activeMinutes
        self.categories = parsed.categories
        self.cards = parsed.cards.map(CLIAgentTimelineCard.init)
    }

    enum CodingKeys: String, CodingKey {
        case version, date, categories, cards
        case captureType = "capture_type"
        case markdownFilename = "markdown_filename"
        case cardCount = "card_count"
        case activeMinutes = "active_minutes"
    }
}

struct CLIAgentTimelineCard: Codable {
    let position: Int
    let timeRange: String
    let title: String
    let category: String
    let kind: String
    let summary: String
    let details: String?
    let transcriptPath: String?

    init(_ parsed: ParsedTimelineCard) {
        self.position = parsed.position
        self.timeRange = parsed.timeRange
        self.title = parsed.title
        self.category = parsed.category
        self.kind = parsed.kind
        self.summary = parsed.summary
        self.details = parsed.details
        self.transcriptPath = parsed.transcriptPath
    }

    enum CodingKeys: String, CodingKey {
        case position, title, category, kind, summary, details
        case timeRange = "time_range"
        case transcriptPath = "transcript_path"
    }
}

struct CLIReadMarkdownDocument: Codable {
    let kind: CLIContextKind
    let filename: String
    let entryId: String?
    let markdown: String
    let recording: CLIAgentRecording?
    let speakers: [CLIActorSpeaker]?
    let utterances: [CLIUtterance]?
    let date: String?
    let entries: [CLIClientDictationEntry]?
    let timeline: CLIAgentTimelineDay?

    init(
        kind: CLIContextKind,
        filename: String,
        entryId: String?,
        markdown: String,
        recording: CLIAgentRecording? = nil,
        speakers: [CLIActorSpeaker]? = nil,
        utterances: [CLIUtterance]? = nil,
        date: String? = nil,
        entries: [CLIClientDictationEntry]? = nil,
        timeline: CLIAgentTimelineDay? = nil
    ) {
        self.kind = kind
        self.filename = filename
        self.entryId = entryId
        self.markdown = markdown
        self.recording = recording
        self.speakers = speakers
        self.utterances = utterances
        self.date = date
        self.entries = entries
        self.timeline = timeline
    }

    enum CodingKeys: String, CodingKey {
        case kind, filename, markdown, recording, speakers, utterances, date, entries, timeline
        case entryId = "entry_id"
    }
}

struct CLIContextResultsDocument: Codable {
    let results: [CLIContextItem]
    let searchedDirectories: [String]?
    let hint: String?
    let notes: [String]?

    enum CodingKeys: String, CodingKey {
        case results, hint, notes
        case searchedDirectories = "searched_directories"
    }
}

extension JSONEncoder {
    static let contextPretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
