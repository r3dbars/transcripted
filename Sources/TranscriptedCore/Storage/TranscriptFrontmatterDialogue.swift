import Foundation

/// Styled meeting dialogue lines from `format_version: 2`:
///
///     [01:43] **You:** What? Yeah, I do.
///     [01:52] **Speaker 1:** Sure.
///
/// The label is the display name alone. Its channel comes from the
/// frontmatter `speakers:` block (`channel: mic | system`); a name with no
/// row (or rows on both channels) is the mic when it is `You` and the call
/// audio otherwise. When that rule would get a line's channel wrong (the same
/// name on both channels, or a mic voice with no row), the writer qualifies
/// the label instead: `**Mic/Dana:**` / `**System/Dana:**`. See
/// docs/capture-format.md.
///
/// Rewriters that only understand channel-qualified labels call
/// `withQualifiedLabels`: every v2 label is qualified first with the
/// frontmatter as it was, the edit runs, then labels whose name alone gives
/// the right channel under the edited frontmatter are compacted again.
public enum TranscriptFrontmatterDialogue {
    public enum Channel: String, Sendable, Hashable {
        case mic
        case system

        /// `Mic` / `System`: the channel prefix used in labels.
        public var labelPrefix: String { self == .mic ? "Mic" : "System" }

        public init?(labelPrefix: String) {
            switch labelPrefix {
            case "Mic": self = .mic
            case "System": self = .system
            default: return nil
            }
        }
    }

    public struct Line: Equatable, Sendable {
        public let timestamp: String
        /// The explicit `Mic/` / `System/` qualifier, when the label has one.
        public let qualifier: Channel?
        /// The display name as written (may be a legacy `[[wiki link]]`).
        public let name: String
        public let text: String

        public init(timestamp: String, qualifier: Channel?, name: String, text: String) {
            self.timestamp = timestamp
            self.qualifier = qualifier
            self.name = name
            self.text = text
        }

        /// `Mic/Name` / `System/Name` for an explicit qualifier, else the name.
        public var label: String {
            qualifier.map { "\($0.labelPrefix)/\(name)" } ?? name
        }
    }

    /// Display name (wiki-link brackets dropped) to the channels whose
    /// `speakers:` rows carry it. A row without `channel:` is `system`.
    public typealias SpeakerChannels = [String: Set<Channel>]

    public static let recorderName = "You"

    // MARK: - Lines

    /// Parses `[<MM:SS or HH:MM:SS>] **<label>:** <text>`. Nil for anything
    /// else, including the v1 shapes.
    public static func parseLine(_ rawLine: String) -> Line? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let timestamp = String(line[line.index(after: line.startIndex)..<close])
        guard isTimestamp(timestamp) else { return nil }
        var rest = line[line.index(after: close)...]
        guard rest.hasPrefix(" **") else { return nil }
        rest = rest.dropFirst(3)
        guard let labelEnd = rest.range(of: ":**") else { return nil }
        let label = String(rest[..<labelEnd.lowerBound])
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let text = rest[labelEnd.upperBound...].trimmingCharacters(in: .whitespaces)

        if let slash = label.firstIndex(of: "/"),
           let channel = Channel(labelPrefix: String(label[..<slash])) {
            let name = String(label[label.index(after: slash)...])
            guard !name.isEmpty else { return nil }
            return Line(timestamp: timestamp, qualifier: channel, name: name, text: text)
        }
        return Line(timestamp: timestamp, qualifier: nil, name: label, text: text)
    }

    public static func render(timestamp: String, label: String, text: String) -> String {
        "[\(timestamp)] **\(label):** \(text)"
    }

    public static func render(_ line: Line) -> String {
        render(timestamp: line.timestamp, label: line.label, text: line.text)
    }

    // MARK: - Channels

    public static func speakerChannels(in markdown: String) -> SpeakerChannels {
        guard let lines = TranscriptFrontmatter.lines(in: markdown) else { return [:] }
        return speakerChannels(fromFrontmatterLines: lines)
    }

    /// Reads `name:` / `channel:` from the nested `speakers:` rows. Accepts
    /// the lines with or without the `---` fences.
    public static func speakerChannels(fromFrontmatterLines lines: [String]) -> SpeakerChannels {
        var channels: SpeakerChannels = [:]
        var inSpeakers = false
        var speakersIndent = 0
        var currentName: String?
        var currentChannel: Channel?
        var inRow = false

        func finishRow() {
            if inRow, let name = currentName.map(plainName), !name.isEmpty {
                channels[name, default: []].insert(currentChannel ?? .system)
            }
            currentName = nil
            currentChannel = nil
            inRow = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inSpeakers { break }
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            if !inSpeakers {
                if trimmed == "speakers:" {
                    inSpeakers = true
                    speakersIndent = indent
                }
                continue
            }
            if !trimmed.isEmpty, indent <= speakersIndent, !trimmed.hasPrefix("-") {
                break
            }
            var entry = Substring(trimmed)
            if entry.hasPrefix("- ") {
                finishRow()
                inRow = true
                entry = entry.dropFirst(2)
            }
            guard inRow else { continue }
            if entry.hasPrefix("name:") {
                currentName = TranscriptFrontmatter.unquoteYAMLScalar(
                    String(entry.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
                )
            } else if entry.hasPrefix("channel:") {
                let raw = entry.dropFirst("channel:".count).trimmingCharacters(in: .whitespaces)
                currentChannel = Channel(rawValue: raw)
            }
        }
        finishRow()
        return channels
    }

    /// The channel a bare name stands for: the one channel its rows use, else
    /// the mic for `You` and the call audio for anyone else.
    public static func resolvedChannel(forName name: String, in channels: SpeakerChannels) -> Channel {
        let plain = plainName(name)
        if let known = channels[plain], known.count == 1, let only = known.first {
            return only
        }
        return plain == recorderName ? .mic : .system
    }

    public static func channel(of line: Line, in channels: SpeakerChannels) -> Channel {
        line.qualifier ?? resolvedChannel(forName: line.name, in: channels)
    }

    /// The label to write for `name` on `channel`: the name alone when the
    /// frontmatter rule reads it back as that channel, else qualified.
    public static func label(name: String, channel: Channel, channels: SpeakerChannels) -> String {
        resolvedChannel(forName: name, in: channels) == channel ? name : "\(channel.labelPrefix)/\(name)"
    }

    // MARK: - Whole-document passes

    /// Every v2 label qualified with its channel, read with this document's
    /// own frontmatter.
    public static func qualifyingLabels(in markdown: String) -> String {
        let channels = speakerChannels(in: markdown)
        return mapDialogueLines(in: markdown) { line in
            guard line.qualifier == nil else { return nil }
            let channel = resolvedChannel(forName: line.name, in: channels)
            return render(Line(timestamp: line.timestamp, qualifier: channel, name: line.name, text: line.text))
        }
    }

    /// Qualified v2 labels whose name alone reads back as the same channel
    /// under this document's frontmatter, with the qualifier dropped.
    public static func compactingLabels(in markdown: String) -> String {
        let channels = speakerChannels(in: markdown)
        return mapDialogueLines(in: markdown) { line in
            guard let qualifier = line.qualifier,
                  resolvedChannel(forName: line.name, in: channels) == qualifier else { return nil }
            return render(Line(timestamp: line.timestamp, qualifier: nil, name: line.name, text: line.text))
        }
    }

    /// Runs a rewrite that only understands qualified labels: qualifies,
    /// edits, then compacts with the edited frontmatter. Files without v2
    /// lines pass through byte for byte.
    @discardableResult
    public static func withQualifiedLabels<Result>(
        in markdown: inout String,
        _ edit: (inout String) throws -> Result
    ) rethrows -> Result {
        guard containsDialogueLine(markdown) else { return try edit(&markdown) }
        var qualified = qualifyingLabels(in: markdown)
        let result = try edit(&qualified)
        markdown = compactingLabels(in: qualified)
        return result
    }

    /// Every v2 line as the v1 raw row `[<ts>] [<Mic|System>/<name>] <text>`,
    /// so read-only parsers that know the raw grammar read v2 files too.
    /// Everything else is unchanged.
    public static func bracketedLines(in markdown: String) -> String {
        guard containsDialogueLine(markdown) else { return markdown }
        let channels = speakerChannels(in: markdown)
        return mapDialogueLines(in: markdown) { line in
            let channel = channel(of: line, in: channels)
            let suffix = line.text.isEmpty ? "" : " \(line.text)"
            return "[\(line.timestamp)] [\(channel.labelPrefix)/\(line.name)]\(suffix)"
        }
    }

    public static func containsDialogueLine(_ markdown: String) -> Bool {
        guard markdown.contains(":** ") || markdown.contains(":**\n") else { return false }
        return markdown.split(separator: "\n", omittingEmptySubsequences: true).contains {
            $0.hasPrefix("[") && parseLine(String($0)) != nil
        }
    }

    // MARK: - Helpers

    /// Applies `transform` to every v2 line in the transcript section (or the
    /// whole body when there is no `## Transcript` heading). Lines it returns
    /// nil for, and the frontmatter, are kept as they are.
    static func mapDialogueLines(in markdown: String, _ transform: (Line) -> String?) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let bodyStart = frontmatterEndIndex(in: lines).map { $0 + 1 } ?? 0
        guard bodyStart < lines.count else { return markdown }
        let hasTranscriptHeading = lines[bodyStart...].contains {
            $0.trimmingCharacters(in: .whitespaces) == "## Transcript"
        }
        var inTranscript = !hasTranscriptHeading
        var changed = false
        for index in bodyStart..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if hasTranscriptHeading, trimmed.hasPrefix("## ") {
                inTranscript = trimmed == "## Transcript"
                continue
            }
            guard inTranscript, trimmed.hasPrefix("["), let line = parseLine(trimmed),
                  let replacement = transform(line) else { continue }
            if replacement != lines[index] {
                lines[index] = replacement
                changed = true
            }
        }
        return changed ? lines.joined(separator: "\n") : markdown
    }

    private static func frontmatterEndIndex(in lines: [String]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        return lines.dropFirst().firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" }
    }

    static func plainName(_ name: String) -> String {
        var plain = name.trimmingCharacters(in: .whitespaces)
        if plain.hasPrefix("[["), plain.hasSuffix("]]"), plain.count >= 4 {
            plain = String(plain.dropFirst(2).dropLast(2))
        }
        return plain.trimmingCharacters(in: .whitespaces)
    }

    static func isTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
