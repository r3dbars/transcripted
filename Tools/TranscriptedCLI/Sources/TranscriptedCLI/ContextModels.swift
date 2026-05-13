import ArgumentParser
import Foundation

enum CLIContextKind: String, ExpressibleByArgument, Codable {
    case all
    case meeting
    case dictation
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

struct CLIReadMarkdownDocument: Codable {
    let kind: CLIContextKind
    let filename: String
    let entryId: String?
    let markdown: String

    enum CodingKeys: String, CodingKey {
        case kind, filename, markdown
        case entryId = "entry_id"
    }
}

extension JSONEncoder {
    static let contextPretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
