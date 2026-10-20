import CryptoKit
import Foundation

/// Metadata stored next to a persisted speaker clip (`<uuid>.wav` + `<uuid>.json`).
/// The clip is one voice sample; this is the text and exact times that sample
/// was cut from, so later review can show the words that play.
public struct SpeakerClipSidecar: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var transcriptId: UUID?
    public var channel: String
    public var diarizerSpeakerId: String
    public var segments: [Segment]
    public var sampleText: String
    public var formatVersion: Int
    public var wavByteCount: Int
    public var wavSHA256: String

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
        sampleText: String,
        formatVersion: Int = SpeakerClipSidecar.currentFormatVersion,
        wavByteCount: Int = 0,
        wavSHA256: String = ""
    ) {
        self.transcriptId = transcriptId
        self.channel = channel
        self.diarizerSpeakerId = diarizerSpeakerId
        self.segments = segments
        self.sampleText = sampleText
        self.formatVersion = formatVersion
        self.wavByteCount = wavByteCount
        self.wavSHA256 = wavSHA256
    }

    public static func url(nextTo clipURL: URL) -> URL {
        clipURL.deletingPathExtension().appendingPathExtension("json")
    }

    public static func load(nextTo clipURL: URL) -> SpeakerClipSidecar? {
        let url = url(nextTo: clipURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerClipSidecar.self, from: data)
    }

    /// The sidecar quote only when it describes this exact wav. A missing
    /// identity, a version we don't read, or bytes that don't match means
    /// there is no quote — never a guessed line.
    public static func loadMatchingWav(nextTo clipURL: URL) -> SpeakerClipSidecar? {
        guard let sidecar = load(nextTo: clipURL), sidecar.matchesWav(at: clipURL) else {
            return nil
        }
        return sidecar
    }

    public func matchesWav(at clipURL: URL) -> Bool {
        guard formatVersion == Self.currentFormatVersion,
              wavByteCount > 0,
              !wavSHA256.isEmpty,
              let identity = Self.wavIdentity(of: clipURL) else {
            return false
        }
        return identity.byteCount == wavByteCount && identity.sha256 == wavSHA256
    }

    public func stamped(withWavAt clipURL: URL) -> SpeakerClipSidecar? {
        guard let identity = Self.wavIdentity(of: clipURL) else { return nil }
        var copy = self
        copy.formatVersion = Self.currentFormatVersion
        copy.wavByteCount = identity.byteCount
        copy.wavSHA256 = identity.sha256
        return copy
    }

    public static func wavIdentity(of clipURL: URL) -> (byteCount: Int, sha256: String)? {
        guard let data = try? Data(contentsOf: clipURL), !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data.count, digest)
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
/// belongs to the bytes actually written. Prefer a turn that fits the 8s cap
/// so the whole quote can play; glued shorts join every written turn's text.
public enum SpeakerClipSamplePolicy {
    public static let maxClipDuration: Double = 8
    public static let minPreferredDuration: Double = 3

    public struct WrittenSegment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        public var wasCropped: Bool
    }

    public static func selectClipSegments(utterances: [TranscriptionUtterance]) -> [TranscriptionUtterance] {
        let valid = utterances.filter { utterance in
            let duration = utterance.end - utterance.start
            return utterance.start.isFinite && utterance.end.isFinite && duration.isFinite && duration > 0
        }
        let fitting = valid.filter { ($0.end - $0.start) <= maxClipDuration }
        if let longestFitting = fitting.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            if longestFitting.end - longestFitting.start >= minPreferredDuration {
                return [longestFitting]
            }
            return glueShortTurns(fitting)
        }
        guard let longest = valid.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else {
            return []
        }
        return [longest]
    }

    public static func writtenSegments(
        from segments: [TranscriptionUtterance],
        sourceDuration: Double? = nil
    ) -> [WrittenSegment] {
        var remaining = maxClipDuration
        var written: [WrittenSegment] = []
        for utterance in segments {
            guard remaining > 0 else { break }
            guard utterance.start.isFinite, utterance.end.isFinite else { continue }
            let rawDuration = utterance.end - utterance.start
            guard rawDuration.isFinite, rawDuration > 0, utterance.start >= 0 else { continue }
            if let sourceDuration {
                guard sourceDuration.isFinite, sourceDuration > 0, utterance.start < sourceDuration else {
                    continue
                }
            }

            var end = min(utterance.end, utterance.start + remaining, utterance.start + maxClipDuration)
            if let sourceDuration {
                end = min(end, sourceDuration)
            }
            guard end > utterance.start else { continue }
            let wasCropped = end + .ulpOfOne < utterance.end
            written.append(
                WrittenSegment(
                    start: utterance.start,
                    end: end,
                    text: utterance.transcript,
                    wasCropped: wasCropped
                )
            )
            remaining -= end - utterance.start
        }
        return written
    }

    public static func sampleText(from written: [WrittenSegment]) -> String {
        written
            .filter { !$0.wasCropped }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func sidecar(
        channel: String,
        diarizerSpeakerId: String,
        segments: [TranscriptionUtterance],
        transcriptId: UUID? = nil,
        sourceDuration: Double? = nil
    ) -> SpeakerClipSidecar {
        let written = writtenSegments(from: segments, sourceDuration: sourceDuration)
        return SpeakerClipSidecar(
            transcriptId: transcriptId,
            channel: channel,
            diarizerSpeakerId: diarizerSpeakerId,
            segments: written.map {
                SpeakerClipSidecar.Segment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.wasCropped ? "" : $0.text
                )
            },
            sampleText: sampleText(from: written)
        )
    }

    private static func glueShortTurns(_ utterances: [TranscriptionUtterance]) -> [TranscriptionUtterance] {
        let longestFirst = utterances.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        var selected: [TranscriptionUtterance] = []
        var totalDuration: Double = 0
        for utterance in longestFirst {
            let duration = utterance.end - utterance.start
            if totalDuration + duration > maxClipDuration { continue }
            selected.append(utterance)
            totalDuration += duration
        }
        return selected.sorted { $0.start < $1.start }
    }
}
