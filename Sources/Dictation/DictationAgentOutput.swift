import Foundation

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

enum DictationAgentOutput {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    static func sidecarURL(for date: Date, in directory: URL) -> URL {
        let slug = dayFormatter.string(from: date)
        return directory.appendingPathComponent("Dictations_\(slug).json", isDirectory: false)
    }

    @discardableResult
    static func appendEntry(
        title: String,
        text: String,
        sourceAppName: String,
        sourceAppBundleId: String?,
        delivery: DictationDelivery,
        wordCount: Int,
        characterCount: Int,
        createdAt: Date,
        markdownURL: URL,
        directory: URL
    ) throws -> URL {
        let sidecarURL = sidecarURL(for: createdAt, in: directory)
        let entry = AgentDictationEntry(
            id: "dictation-\(idFormatter.string(from: createdAt))",
            createdAt: isoFormatter.string(from: createdAt),
            title: title,
            text: text,
            sourceAppName: sourceAppName,
            sourceAppBundleId: sourceAppBundleId,
            delivery: delivery.rawValue,
            wordCount: wordCount,
            characterCount: characterCount
        )

        // Guard against silent data loss: if the sidecar exists but can't be decoded
        // (corrupted JSON), throw rather than falling back to [] and discarding all prior entries.
        let existingEntries: [AgentDictationEntry]
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            guard let existing = loadDay(from: sidecarURL) else {
                throw CocoaError(.coderInvalidValue, userInfo: [
                    NSURLErrorKey: sidecarURL,
                    NSLocalizedDescriptionKey: "Corrupted dictation sidecar: \(sidecarURL.lastPathComponent)"
                ])
            }
            existingEntries = existing.entries
        } else {
            existingEntries = []
        }
        var entries = existingEntries.filter { $0.id != entry.id }
        entries.append(entry)
        entries.sort { $0.createdAt < $1.createdAt }

        let payload = AgentDictationDay(
            version: "1.0",
            captureType: "dictation_day",
            date: dayFormatter.string(from: createdAt),
            markdownFilename: markdownURL.lastPathComponent,
            entryCount: entries.count,
            wordCount: entries.reduce(0) { $0 + $1.wordCount },
            entries: entries
        )

        let data = try encoder.encode(payload)
        try data.write(to: sidecarURL, options: .atomic)
        return sidecarURL
    }

    private static func loadDay(from url: URL) -> AgentDictationDay? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AgentDictationDay.self, from: data)
    }
}
