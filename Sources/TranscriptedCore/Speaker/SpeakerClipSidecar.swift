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
        guard let identity = Self.wavIdentity(of: clipURL) else { return false }
        return matches(byteCount: identity.byteCount, sha256: identity.sha256)
    }

    public func matches(wavData: Data) -> Bool {
        guard !wavData.isEmpty else { return false }
        return matches(byteCount: wavData.count, sha256: Self.sha256Hex(wavData))
    }

    /// Accept a sidecar only when it is unbound (this write's own quote) or
    /// already describes `sourceURL`. A crash-window json stamped for a wav
    /// that never landed must not be restamped onto a different file.
    public static func acceptedIncoming(
        _ sidecar: SpeakerClipSidecar?,
        matchingSourceAt sourceURL: URL
    ) -> SpeakerClipSidecar? {
        guard let sidecar, sidecar.formatVersion == currentFormatVersion else { return nil }
        if sidecar.wavByteCount == 0, sidecar.wavSHA256.isEmpty {
            return sidecar
        }
        return sidecar.matchesWav(at: sourceURL) ? sidecar : nil
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
        let path = clipURL.standardizedFileURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970

        if let size, let mtime, let cached = WavIdentityCache.entry(path: path, size: size, mtime: mtime) {
            return (cached.byteCount, cached.sha256)
        }

        guard let data = try? Data(contentsOf: clipURL), !data.isEmpty else { return nil }
        let digest = sha256Hex(data)
        if let size, let mtime {
            WavIdentityCache.store(path: path, size: size, mtime: mtime, byteCount: data.count, sha256: digest)
        }
        return (data.count, digest)
    }

    private func matches(byteCount: Int, sha256: String) -> Bool {
        formatVersion == Self.currentFormatVersion
            && wavByteCount > 0
            && !wavSHA256.isEmpty
            && wavByteCount == byteCount
            && wavSHA256 == sha256
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// Crop the planned segment to the frames the writer actually kept.
    /// About 1.5 frames of slack so rounding a complete turn does not empty
    /// the quote.
    public static func recordedSegment(
        from planned: WrittenSegment,
        framesWritten: Int,
        sampleRate: Double
    ) -> WrittenSegment? {
        guard framesWritten > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              planned.start.isFinite,
              planned.end.isFinite,
              planned.end > planned.start else {
            return nil
        }
        let recordedDuration = Double(framesWritten) / sampleRate
        let plannedDuration = planned.end - planned.start
        let epsilon = 1.5 / sampleRate
        let wasCropped = planned.wasCropped || recordedDuration + epsilon < plannedDuration
        return WrittenSegment(
            start: planned.start,
            end: planned.start + min(recordedDuration, plannedDuration),
            text: planned.text,
            wasCropped: wasCropped
        )
    }

    public static func sidecar(
        channel: String,
        diarizerSpeakerId: String,
        written: [WrittenSegment],
        transcriptId: UUID? = nil
    ) -> SpeakerClipSidecar {
        SpeakerClipSidecar(
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

    public static func sidecar(
        channel: String,
        diarizerSpeakerId: String,
        segments: [TranscriptionUtterance],
        transcriptId: UUID? = nil,
        sourceDuration: Double? = nil
    ) -> SpeakerClipSidecar {
        sidecar(
            channel: channel,
            diarizerSpeakerId: diarizerSpeakerId,
            written: writtenSegments(from: segments, sourceDuration: sourceDuration),
            transcriptId: transcriptId
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

private enum WavIdentityCache {
    struct Entry {
        let size: Int
        let mtime: TimeInterval
        let byteCount: Int
        let sha256: String
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    static func entry(path: String, size: Int, mtime: TimeInterval) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = entries[path], cached.size == size, cached.mtime == mtime else {
            return nil
        }
        return cached
    }

    static func store(path: String, size: Int, mtime: TimeInterval, byteCount: Int, sha256: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = Entry(size: size, mtime: mtime, byteCount: byteCount, sha256: sha256)
    }
}
