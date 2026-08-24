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
    public static let maximumFrontmatterByteLimit = 512 * 1024

    private static let recordedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
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

        let readLimit = maximumFrontmatterByteLimit
        let chunkSize = max(1, min(byteLimit, previewByteLimit))
        let openingDelimiter = Data("---\n".utf8)
        let closingDelimiter = Data("\n---\n".utf8)
        var data = Data()
        var didValidateOpeningDelimiter = false
        var nextClosingDelimiterSearchOffset = openingDelimiter.count

        while data.count < readLimit {
            let remaining = readLimit - data.count
            guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)

            if !didValidateOpeningDelimiter, data.count >= openingDelimiter.count {
                guard data.starts(with: openingDelimiter) else { return nil }
                didValidateOpeningDelimiter = true
            }
            guard didValidateOpeningDelimiter else { continue }

            let searchStart = min(nextClosingDelimiterSearchOffset, data.count)
            if data.range(
                of: closingDelimiter,
                in: searchStart..<data.endIndex
            ) != nil {
                // Decode once, after the complete delimiter is present. Besides
                // preserving UTF-8 split across chunks, this avoids repeatedly
                // decoding and parsing the whole growing prefix.
                let raw = String(decoding: data, as: UTF8.self)
                return document(in: raw)
            }

            nextClosingDelimiterSearchOffset = max(
                openingDelimiter.count,
                data.count - (closingDelimiter.count - 1)
            )
        }

        return nil
    }

    public static func readValues(
        from url: URL,
        byteLimit: Int = previewByteLimit
    ) throws -> [String: String]? {
        try readDocument(from: url, byteLimit: byteLimit)?.values
    }

    /// Resolve the capture identity from parsed frontmatter values, preferring
    /// `transcript_id` and falling back to the legacy `capture_id` key. Shared
    /// so callers cannot drift on the fallback order.
    public static func captureID(in values: [String: String]) -> UUID? {
        (values["transcript_id"] ?? values["capture_id"])
            .flatMap(UUID.init(uuidString:))
    }

    /// Upper bound for a single `duration:` component, chosen so the largest
    /// possible `h*3600 + m*60 + s` stays trivially inside `Int`. Mirrors the
    /// same ceiling in CaptureMarkdownParser's copy of this parse.
    private static let maxDurationComponent = 1_000_000

    public static func durationSeconds(from value: String?) -> Int? {
        guard let value else { return nil }

        let rawParts = value.split(separator: ":", omittingEmptySubsequences: false)
        let parts = rawParts.compactMap { Int($0) }
        guard parts.count == rawParts.count else { return nil }
        // Bounded above as well as below: parts are only implicitly limited by
        // `Int()` parsing, so a corrupted `duration:` like
        // "200000000000000000:00" would overflow the *60 / *3600 multiply
        // below and trap. This runs over every capture file during the Home
        // scan, so one bad file would take down the app. A day is 86,400s.
        guard parts.allSatisfy({ $0 >= 0 && $0 <= maxDurationComponent }) else { return nil }

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
            DateFormattingHelper.parseDayStamp(date)
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
