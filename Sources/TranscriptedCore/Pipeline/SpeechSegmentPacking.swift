import Foundation

/// One recognized token and when it starts, in seconds from the start of the
/// audio the engine was given. A token whose text starts with a space begins
/// a new word, the same way the engine's plain text output joins tokens.
public struct TimedTranscriptToken: Equatable, Sendable {
    public let text: String
    public let startSeconds: Double

    public init(text: String, startSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
    }
}

/// Packs several short speech segments into one speech-to-text call and
/// splits the result back into one text per segment.
///
/// Parakeet runs every call on a fixed 15 s window: a 4 s segment costs the
/// same encoder work as 15 s of audio. Laying short segments end to end with a
/// short silence between them fills that window, so a meeting needs a fraction
/// of the calls. The silence keeps every word inside its own segment, and the
/// split assigns each word by where its first token starts.
public enum SpeechSegmentPacking {
    /// Silence between packed segments: 0.5 s at 16 kHz, about six encoder
    /// frames, so no word can straddle two segments.
    public static let defaultGapSamples = 8_000

    public struct Layout: Equatable, Sendable {
        /// The packed audio: each segment in order, with `gapSamples` of
        /// silence between neighbours.
        public let samples: [Float]
        /// Where each segment sits inside `samples`, in the input order.
        public let ranges: [Range<Int>]
    }

    /// Total samples a pack holds after adding one more segment of `adding`
    /// samples to `current` samples already packed.
    public static func packedLength(current: Int, adding: Int, gapSamples: Int) -> Int {
        current == 0 ? adding : current + gapSamples + adding
    }

    public static func layout(_ segments: [[Float]], gapSamples: Int = defaultGapSamples) -> Layout {
        let gap = max(0, gapSamples)
        let total = segments.reduce(0) { packedLength(current: $0, adding: $1.count, gapSamples: gap) }
        var samples: [Float] = []
        samples.reserveCapacity(total)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                samples.append(contentsOf: repeatElement(0, count: gap))
            }
            let start = samples.count
            samples.append(contentsOf: segment)
            ranges.append(start..<samples.count)
        }
        return Layout(samples: samples, ranges: ranges)
    }

    /// One text per range. A word belongs to the segment whose span, widened
    /// to the middle of each neighbouring gap, holds its first token's start.
    public static func split(
        tokens: [TimedTranscriptToken],
        ranges: [Range<Int>],
        sampleRate: Double = 16_000
    ) -> [String] {
        guard !ranges.isEmpty else { return [] }
        let boundaries: [Double] = zip(ranges, ranges.dropFirst()).map { left, right in
            Double(left.upperBound + right.lowerBound) / 2 / sampleRate
        }
        var pieces = Array(repeating: "", count: ranges.count)
        var wordSegment = 0
        var isFirstToken = true
        for token in tokens.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            guard !token.text.isEmpty else { continue }
            if isFirstToken || token.text.first?.isWhitespace == true {
                let start = token.startSeconds.isFinite ? token.startSeconds : 0
                let index = boundaries.firstIndex(where: { start < $0 }) ?? boundaries.count
                // Tokens are in time order, so words never move backwards.
                wordSegment = max(wordSegment, index)
                isFirstToken = false
            }
            pieces[wordSegment] += token.text
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Groups segments, in order, into packs that fit one speech-to-text window.
/// A segment longer than the window, or any segment when the window is 0,
/// goes on its own, which is exactly the one-call-per-segment path.
struct SpeechSegmentBatcher<Item> {
    struct Entry {
        let item: Item
        let samples: [Float]
    }

    let windowSamples: Int
    let gapSamples: Int
    private var pending: [Entry] = []
    private var pendingSamples = 0

    init(windowSamples: Int, gapSamples: Int = SpeechSegmentPacking.defaultGapSamples) {
        self.windowSamples = max(0, windowSamples)
        self.gapSamples = max(0, gapSamples)
    }

    /// Adds a segment and returns every batch that is now complete.
    mutating func add(_ item: Item, samples: [Float]) -> [[Entry]] {
        var ready: [[Entry]] = []
        let entry = Entry(item: item, samples: samples)
        guard samples.count <= windowSamples else {
            ready += finish()
            ready.append([entry])
            return ready
        }
        let packed = SpeechSegmentPacking.packedLength(
            current: pendingSamples,
            adding: samples.count,
            gapSamples: gapSamples
        )
        if !pending.isEmpty, packed > windowSamples {
            ready += finish()
        }
        pendingSamples = SpeechSegmentPacking.packedLength(
            current: pendingSamples,
            adding: samples.count,
            gapSamples: gapSamples
        )
        pending.append(entry)
        return ready
    }

    /// Returns the last partial batch, if any, and empties the batcher.
    mutating func finish() -> [[Entry]] {
        guard !pending.isEmpty else { return [] }
        let batch = pending
        pending = []
        pendingSamples = 0
        return [batch]
    }
}
