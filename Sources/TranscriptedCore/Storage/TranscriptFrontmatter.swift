import Foundation

/// Small, shared parser for Transcripted's Markdown YAML frontmatter.
///
/// This is intentionally not a general YAML parser. It handles the flat
/// `key: value` fields Transcripted writes and leaves richer blocks, like
/// `speakers:`, to callers that need the original frontmatter lines.
public struct TranscriptFrontmatterDocument: Sendable {
    public let lines: [String]
    public let values: [String: String]
    public let body: String

    public init(lines: [String], values: [String: String], body: String) {
        self.lines = lines
        self.values = values
        self.body = body
    }
}

public enum TranscriptFrontmatter {
    public static let previewByteLimit = 64 * 1024

    private static let recordedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let formatterQueue = DispatchQueue(label: "TranscriptedCore.TranscriptFrontmatter.formatters")

    public static func document(in raw: String) -> TranscriptFrontmatterDocument? {
        guard raw.hasPrefix("---\n"),
              let endRange = raw.range(
                of: "\n---\n",
                range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex
              ) else {
            return nil
        }

        let frontmatterText = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<endRange.lowerBound])
        let lines = frontmatterText.components(separatedBy: "\n")
        return TranscriptFrontmatterDocument(
            lines: lines,
            values: values(from: lines),
            body: String(raw[endRange.upperBound...])
        )
    }

    public static func body(in raw: String) -> String? {
        document(in: raw)?.body
    }

    public static func lines(in raw: String) -> [String]? {
        document(in: raw)?.lines
    }

    public static func values(in raw: String) -> [String: String]? {
        document(in: raw)?.values
    }

    public static func values(from lines: [String]) -> [String: String] {
        var values: [String: String] = [:]

        for line in lines {
            guard line.first?.isWhitespace != true else { continue }

            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            values[parts[0].trimmingCharacters(in: .whitespaces)] = normalizeValue(parts[1])
        }

        return values
    }

    public static func readDocument(
        from url: URL,
        byteLimit: Int = previewByteLimit
    ) throws -> TranscriptFrontmatterDocument? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: byteLimit) ?? Data()
        let raw = String(decoding: data, as: UTF8.self)
        return document(in: raw)
    }

    public static func readValues(
        from url: URL,
        byteLimit: Int = previewByteLimit
    ) throws -> [String: String]? {
        try readDocument(from: url, byteLimit: byteLimit)?.values
    }

    public static func durationSeconds(from value: String?) -> Int? {
        guard let value else { return nil }

        let parts = value.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 1:
            return parts[0]
        case 2:
            return parts[0] * 60 + parts[1]
        case 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default:
            return nil
        }
    }

    public static func recordedAt(values: [String: String]) -> Date? {
        guard let date = values["date"] else { return nil }
        let time = values["time"] ?? "00:00:00"

        return formatterQueue.sync {
            recordedAtFormatter.date(from: "\(date) \(time)")
        }
    }

    public static func recordedAt(in raw: String) -> Date? {
        guard let values = values(in: raw) else { return nil }
        return recordedAt(values: values)
    }

    public static func date(values: [String: String]) -> Date? {
        guard let date = values["date"] else { return nil }

        return formatterQueue.sync {
            dateFormatter.date(from: date)
        }
    }

    public static func date(in raw: String) -> Date? {
        guard let values = values(in: raw) else { return nil }
        return date(values: values)
    }

    private static func normalizeValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
