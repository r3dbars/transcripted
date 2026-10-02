import Foundation

/// One turn in the live transcript: consecutive utterances from the same
/// capture track join into one line, so the island reads like a conversation.
struct LiveMeetingCaptionLine: Equatable, Sendable {
    let track: LiveMeetingTrack
    var text: String
}

/// The whole live transcript of the recording meeting, for the island's
/// hover. Committed lines only ever grow at the end (a new line, or more
/// words on the last one), so a view can append instead of redrawing an
/// hour of text. `tentative` is what each track's decoder is still hearing
/// and may rewrite. Provisional: the saved meeting is transcribed again,
/// with speaker names, after Stop.
struct LiveMeetingCaptionLog: Equatable, Sendable {
    private(set) var lines: [LiveMeetingCaptionLine] = []
    private(set) var tentative: [LiveMeetingTrack: String] = [:]
    /// Bumped when lines are dropped from the front, so a view knows its
    /// append-only copy is stale and redraws once.
    private(set) var trimGeneration = 0
    let maximumCharacters: Int
    private var committedCharacters = 0

    /// About eight hours of two-sided talk. Past that the oldest lines go.
    init(maximumCharacters: Int = 1_000_000) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    var isEmpty: Bool { lines.isEmpty && tentative.values.allSatisfy(\.isEmpty) }

    mutating func setTentative(_ text: String, track: LiveMeetingTrack) {
        let trimmed = Self.clean(text)
        tentative[track] = trimmed.isEmpty ? nil : trimmed
    }

    mutating func commit(_ text: String, track: LiveMeetingTrack) {
        tentative[track] = nil
        let trimmed = Self.clean(text)
        guard !trimmed.isEmpty else { return }
        if let last = lines.indices.last, lines[last].track == track {
            lines[last].text += " " + trimmed
            committedCharacters += trimmed.count + 1
        } else {
            lines.append(LiveMeetingCaptionLine(track: track, text: trimmed))
            committedCharacters += trimmed.count
        }
        guard committedCharacters > maximumCharacters else { return }
        while committedCharacters > maximumCharacters, lines.count > 1 {
            committedCharacters -= lines.removeFirst().text.count
        }
        trimGeneration += 1
    }

    /// Plain text for Copy all: one "You:" or "Them:" paragraph per turn,
    /// with words still being heard included at the end.
    func plainText() -> String {
        var turns = lines.map { "\(Self.label($0.track)): \($0.text)" }
        for track in LiveMeetingTrack.allCases {
            guard let pending = tentative[track] else { continue }
            if let last = lines.last, last.track == track, turns.count == lines.count {
                turns[turns.count - 1] += " " + pending
            } else {
                turns.append("\(Self.label(track)): \(pending)")
            }
        }
        return turns.joined(separator: "\n\n")
    }

    /// Who a capture track is. Live text only knows which track the audio
    /// came in on: the mic is the person using this Mac, call audio is
    /// everyone else.
    static func label(_ track: LiveMeetingTrack) -> String {
        switch track {
        case .microphone: return "You"
        case .system: return "Them"
        }
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
