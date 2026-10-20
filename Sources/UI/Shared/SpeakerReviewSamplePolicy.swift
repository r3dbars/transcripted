import Foundation

/// One transcript turn for a voice, plus the retained-audio range that
/// belongs to that same turn. Speakers review, Home "Who is this?" quotes,
/// and retained-audio fallback all read this so the words on screen are the
/// words that play. The island popup already pairs clip audio with that
/// clip's own quote; this is the main-app equivalent from saved markdown.
enum SpeakerReviewSamplePolicy {
    static let maxPreviewDuration: TimeInterval = 8

    struct Window: Equatable, Sendable {
        let startTime: TimeInterval
        let duration: TimeInterval
        let text: String
    }

    struct Sample: Equatable, Sendable {
        let line: HomeMeetingTranscriptLine
        let mixedWindow: Window?
        let channelWindow: Window?
    }

    static func sample(
        matching identity: HomeMeetingSpeakerIdentity,
        in lines: [HomeMeetingTranscriptLine],
        meetingDuration: TimeInterval?
    ) -> Sample? {
        sample(
            persistentSpeakerID: identity.persistentSpeakerID,
            diarizerSpeakerID: identity.diarizerSpeakerID,
            channel: identity.channel,
            in: lines,
            meetingDuration: meetingDuration
        )
    }

    static func sample(
        persistentSpeakerID: UUID?,
        diarizerSpeakerID: String?,
        channel: HomeMeetingSpeakerChannel?,
        in lines: [HomeMeetingTranscriptLine],
        meetingDuration: TimeInterval?
    ) -> Sample? {
        guard let line = representativeLine(
            persistentSpeakerID: persistentSpeakerID,
            diarizerSpeakerID: diarizerSpeakerID,
            channel: channel,
            in: lines
        ) else { return nil }
        return Sample(
            line: line,
            mixedWindow: playbackWindow(
                for: line, in: lines, fromMixedAudio: true, meetingDuration: meetingDuration
            ),
            channelWindow: playbackWindow(
                for: line, in: lines, fromMixedAudio: false, meetingDuration: meetingDuration
            )
        )
    }

    /// The turn whose quote should be shown: longest text, then longest
    /// mixed-timeline gap to the next line, then the earlier start. Gaps are
    /// not utterance durations (markdown only has start clocks), so text
    /// length is the primary key — a one-word greeting with a long pause
    /// must not beat a real sentence.
    static func representativeLine(
        matching identity: HomeMeetingSpeakerIdentity,
        in lines: [HomeMeetingTranscriptLine]
    ) -> HomeMeetingTranscriptLine? {
        representativeLine(
            persistentSpeakerID: identity.persistentSpeakerID,
            diarizerSpeakerID: identity.diarizerSpeakerID,
            channel: identity.channel,
            in: lines
        )
    }

    static func representativeLine(
        persistentSpeakerID: UUID?,
        diarizerSpeakerID: String?,
        channel: HomeMeetingSpeakerChannel?,
        in lines: [HomeMeetingTranscriptLine]
    ) -> HomeMeetingTranscriptLine? {
        let matches = lines.enumerated().filter { _, line in
            line.identity.persistentSpeakerID == persistentSpeakerID
                && line.identity.diarizerSpeakerID == diarizerSpeakerID
                && (line.identity.channel == nil || channel == nil || line.identity.channel == channel)
                && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && line.startSeconds != nil
        }
        return matches.max { lhs, rhs in
            let leftText = lhs.element.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            let rightText = rhs.element.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            if leftText != rightText { return leftText < rightText }
            let leftTurn = mixedTurnLength(of: lhs.element, at: lhs.offset, in: lines)
            let rightTurn = mixedTurnLength(of: rhs.element, at: rhs.offset, in: lines)
            if leftTurn != rightTurn { return leftTurn < rightTurn }
            return (lhs.element.startSeconds ?? 0) > (rhs.element.startSeconds ?? 0)
        }?.element
    }

    /// Playback range for an already-chosen line. Start is that line's Home
    /// clock (`startSeconds`). Duration is min(8s, next turn on this source,
    /// meeting end). Nil when the next clock is equal or reversed — the
    /// range would not isolate this voice.
    static func playbackWindow(
        for line: HomeMeetingTranscriptLine,
        in lines: [HomeMeetingTranscriptLine],
        fromMixedAudio: Bool,
        meetingDuration: TimeInterval?
    ) -> Window? {
        guard let start = line.startSeconds,
              let index = lines.firstIndex(of: line) else { return nil }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var end = start + maxPreviewDuration
        if let next = lines.dropFirst(index + 1).first(where: {
            $0.startSeconds != nil && (
                fromMixedAudio
                    || $0.identity.channel == nil
                    || line.identity.channel == nil
                    || $0.identity.channel == line.identity.channel
            )
        }) {
            guard let nextStart = next.startSeconds, nextStart > start else { return nil }
            end = min(end, nextStart)
        }
        if let meetingDuration { end = min(end, meetingDuration) }
        guard end > start else { return nil }
        return Window(startTime: start, duration: end - start, text: text)
    }

    private static func mixedTurnLength(
        of line: HomeMeetingTranscriptLine,
        at index: Int,
        in lines: [HomeMeetingTranscriptLine]
    ) -> TimeInterval {
        guard let start = line.startSeconds else { return 0 }
        let nextStart = lines.dropFirst(index + 1).compactMap(\.startSeconds).first
        guard let nextStart, nextStart > start else { return 0 }
        return nextStart - start
    }
}
