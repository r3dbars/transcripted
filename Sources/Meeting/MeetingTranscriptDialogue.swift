import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// One transcript turn as the styler reads it from any saved grammar: raw
/// `[00:00] [Mic/You] text`, v1 styled `**00:00**  [Mic/You]` blocks, or v2
/// `[00:00] **You:** text` lines.
struct MeetingTranscriptTurn: Equatable {
    let timestamp: String
    /// Nil only when an old label had no `Mic/` / `System/` prefix.
    let channel: TranscriptFrontmatterDialogue.Channel?
    /// The display name as written, including a legacy `[[wiki link]]`.
    let name: String
    let text: String

    /// `Mic/<name>` / `System/<name>`, the v1 label.
    var qualifiedLabel: String {
        channel.map { "\($0.labelPrefix)/\(name)" } ?? name
    }

    var seconds: Int? { MeetingTranscriptDialogue.seconds(fromTimestamp: timestamp) }
}

/// The v2 styled body: merged turns as `[MM:SS] **Speaker:** text`.
enum MeetingTranscriptDialogue {
    /// Consecutive turns by one speaker merge while the next one starts at
    /// most this many seconds after the previous one started...
    static let mergeMaximumGapSeconds = 8
    /// ...the merged turn spans at most this many seconds, start to start...
    static let mergeMaximumSpanSeconds = 25
    /// ...and its text stays at most this many characters. Timestamps stay
    /// frequent enough that clicking one still plays close to the words.
    static let mergeMaximumCharacters = 320

    /// Merges short same-speaker runs ("Oh" / "my god" / "so that the top")
    /// into readable turns. Starting from v2 output again changes nothing: a
    /// pair that failed a limit fails it again from the merged turn's start.
    static func merged(_ turns: [MeetingTranscriptTurn]) -> [MeetingTranscriptTurn] {
        var result: [MeetingTranscriptTurn] = []
        var lastMergedStart: Int?

        for turn in turns {
            guard let previous = result.last,
                  previous.channel == turn.channel,
                  previous.name == turn.name,
                  let firstStart = previous.seconds,
                  let lastStart = lastMergedStart,
                  let start = turn.seconds,
                  start >= lastStart,
                  start - lastStart <= mergeMaximumGapSeconds,
                  start - firstStart <= mergeMaximumSpanSeconds else {
                result.append(turn)
                lastMergedStart = turn.seconds
                continue
            }
            let text = previous.text + " " + turn.text
            guard text.count <= mergeMaximumCharacters else {
                result.append(turn)
                lastMergedStart = turn.seconds
                continue
            }
            result[result.count - 1] = MeetingTranscriptTurn(
                timestamp: previous.timestamp,
                channel: previous.channel,
                name: previous.name,
                text: text
            )
            lastMergedStart = start
        }
        return result
    }

    /// One line per turn, blank-line separated. A label is the bare name
    /// unless the frontmatter rule would read it as the other channel.
    static func render(
        _ turns: [MeetingTranscriptTurn],
        channels: TranscriptFrontmatterDialogue.SpeakerChannels
    ) -> String {
        turns.map { turn in
            let label = turn.channel.map {
                TranscriptFrontmatterDialogue.label(name: turn.name, channel: $0, channels: channels)
            } ?? turn.name
            return TranscriptFrontmatterDialogue.render(timestamp: turn.timestamp, label: label, text: turn.text)
        }.joined(separator: "\n\n")
    }

    /// A v2 line as a turn, its channel read from the frontmatter.
    static func turn(
        fromDialogueLine line: String,
        continuation: [String],
        channels: TranscriptFrontmatterDialogue.SpeakerChannels
    ) -> MeetingTranscriptTurn? {
        guard let parsed = TranscriptFrontmatterDialogue.parseLine(line) else { return nil }
        let text = ([parsed.text] + continuation)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return MeetingTranscriptTurn(
            timestamp: parsed.timestamp,
            channel: TranscriptFrontmatterDialogue.channel(of: parsed, in: channels),
            name: parsed.name,
            text: text
        )
    }

    /// A v1 `Mic/You` label split into channel and name.
    static func turn(timestamp: String, qualifiedLabel label: String, text: String) -> MeetingTranscriptTurn {
        if let slash = label.firstIndex(of: "/"),
           let channel = TranscriptFrontmatterDialogue.Channel(labelPrefix: String(label[..<slash])) {
            return MeetingTranscriptTurn(
                timestamp: timestamp,
                channel: channel,
                name: String(label[label.index(after: slash)...]),
                text: text
            )
        }
        return MeetingTranscriptTurn(timestamp: timestamp, channel: nil, name: label, text: text)
    }

    static func seconds(fromTimestamp stamp: String) -> Int? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 6, let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
