import Foundation

/// Metadata stored next to a persisted speaker clip (`<uuid>.wav` + `<uuid>.json`).
/// The clip is one voice sample; this is the text and exact times that sample
/// was cut from, so later review can show the words that play.
public struct SpeakerClipSidecar: Codable, Equatable, Sendable {
    public var transcriptId: UUID?
    public var channel: String
    public var diarizerSpeakerId: String
    public var segments: [Segment]
    public var sampleText: String

    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public init(
        transcriptId: UUID? = nil,
        channel: String,
        diarizerSpeakerId: String,
        segments: [Segment],
        sampleText: String
    ) {
        self.transcriptId = transcriptId
        self.channel = channel
        self.diarizerSpeakerId = diarizerSpeakerId
        self.segments = segments
        self.sampleText = sampleText
    }

    public static func url(nextTo clipURL: URL) -> URL {
        clipURL.deletingPathExtension().appendingPathExtension("json")
    }

    public static func load(nextTo clipURL: URL) -> SpeakerClipSidecar? {
        let url = url(nextTo: clipURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerClipSidecar.self, from: data)
    }

    public func write(nextTo clipURL: URL) throws {
        let dest = Self.url(nextTo: clipURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: dest, options: .atomic)
        FileManager.default.restrictToOwnerOnly(atPath: dest.path)
    }
}

/// Picks the audio segments that become one speaker clip, and the quote that
/// belongs to those same segments. Duration wins for the cut; the quote is
/// the longest text among the chosen segments — the island already uses this.
public enum SpeakerClipSamplePolicy {
    public static let maxClipDuration: Double = 8
    public static let minPreferredDuration: Double = 3

    public static func selectClipSegments(utterances: [TranscriptionUtterance]) -> [TranscriptionUtterance] {
        let sorted = utterances.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        guard let longest = sorted.first else { return [] }
        let longestDuration = longest.end - longest.start

        if longestDuration >= minPreferredDuration {
            return [longest]
        }

        var selected: [TranscriptionUtterance] = []
        var totalDuration: Double = 0
        for utterance in sorted {
            let duration = utterance.end - utterance.start
            if totalDuration + duration > maxClipDuration { break }
            selected.append(utterance)
            totalDuration += duration
        }
        return selected.sorted { $0.start < $1.start }
    }

    public static func sampleText(from segments: [TranscriptionUtterance]) -> String {
        segments.max(by: { $0.transcript.count < $1.transcript.count })?.transcript ?? ""
    }

    public static func sidecar(
        channel: String,
        diarizerSpeakerId: String,
        segments: [TranscriptionUtterance],
        transcriptId: UUID? = nil
    ) -> SpeakerClipSidecar {
        var remaining = maxClipDuration
        var recorded: [SpeakerClipSidecar.Segment] = []
        for utterance in segments {
            guard remaining > 0 else { break }
            let rawDuration = utterance.end - utterance.start
            guard rawDuration.isFinite, rawDuration > 0 else { continue }
            let duration = min(rawDuration, remaining, maxClipDuration)
            recorded.append(
                SpeakerClipSidecar.Segment(
                    start: utterance.start,
                    end: utterance.start + duration,
                    text: utterance.transcript
                )
            )
            remaining -= duration
        }
        return SpeakerClipSidecar(
            transcriptId: transcriptId,
            channel: channel,
            diarizerSpeakerId: diarizerSpeakerId,
            segments: recorded,
            sampleText: sampleText(from: segments)
        )
    }
}
